#!/bin/sh
# nexrouter.sh - NextDNS multi-account quota-aware router for OpenWrt
#
# POSIX sh / ash compatible. No bash arrays, no declare -A.
#
# Commands:
#   list               show accounts and active selection
#   status             show quota per account (uses 10-minute cache)
#   quota              force quota refresh, then show
#   switch <acc_id>    switch the active NextDNS profile
#   auto               switch to the account with the most remaining quota
#   health             check the nextdns client and DNS resolution
#
# Exit codes: 0 success, 1 failure.

set -u

CONF_DIR="${NEXROUTER_CONF_DIR:-/etc/nexrouter}"
ACCOUNTS_CONF="$CONF_DIR/accounts.conf"
SECRETS_CONF="$CONF_DIR/secrets.conf"
CACHE_FILE="${NEXROUTER_CACHE:-/tmp/nexrouter_quota.json}"
NEXTDNS_INIT="${NEXROUTER_NEXTDNS_INIT:-/etc/init.d/nextdns}"

CACHE_TTL=600
QUOTA=300000
TMP="${TMPDIR:-/tmp}"
LOG_TAG="nexrouter"

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
log() {
    _lvl="$1"
    shift
    _msg="$*"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_lvl" "$_msg" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$_msg" 2>/dev/null || true
    fi
}

die() {
    log ERROR "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
valid_id() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

load_config() {
    [ -r "$ACCOUNTS_CONF" ] || die "accounts config not found: $ACCOUNTS_CONF"
    # shellcheck disable=SC1090
    . "$ACCOUNTS_CONF"
    : "${ACCOUNTS:=}"
    : "${CURRENT:=}"
    if [ -r "$SECRETS_CONF" ]; then
        # shellcheck disable=SC1090
        . "$SECRETS_CONF"
    fi
}

get_api_key() {
    eval "printf '%s' \"\${API_KEY_$1-}\""
}

# Emit one "id|config_id|api_base" line per configured account.
# Comments, blank lines and malformed ids are dropped.
account_lines() {
    printf '%s\n' "$ACCOUNTS" \
        | grep -v '^[[:space:]]*#' \
        | grep -v '^[[:space:]]*$' \
        | while IFS='|' read -r _id _cfg _base; do
            valid_id "$_id" || continue
            [ -n "$_cfg" ] || continue
            [ -n "$_base" ] || _base="https://api.nextdns.io"
            printf '%s|%s|%s\n' "$_id" "$_cfg" "$_base"
        done
}

account_line_by_id() {
    _want="$1"
    account_lines | while IFS='|' read -r _id _cfg _base; do
        if [ "$_id" = "$_want" ]; then
            printf '%s|%s|%s' "$_id" "$_cfg" "$_base"
            break
        fi
    done
}

account_config() {
    _want="$1"
    account_lines | while IFS='|' read -r _id _cfg _base; do
        if [ "$_id" = "$_want" ]; then
            printf '%s' "$_cfg"
            break
        fi
    done
}

update_current() {
    _id="$1"
    _tmp="${ACCOUNTS_CONF}.tmp.$$"
    if grep -q '^CURRENT=' "$ACCOUNTS_CONF" 2>/dev/null; then
        sed "s/^CURRENT=.*/CURRENT='$_id'/" "$ACCOUNTS_CONF" > "$_tmp"
    else
        {
            cat "$ACCOUNTS_CONF"
            printf "CURRENT='%s'\n" "$_id"
        } > "$_tmp"
    fi
    chmod --reference="$ACCOUNTS_CONF" "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$ACCOUNTS_CONF"
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
# fetch_status_json <url> <api_key> <out_file>
# Returns 0 only for a 2xx body that contains a "data" object.
fetch_status_json() {
    _url="$1"
    _key="$2"
    _out="$3"
    : > "$_out"

    if command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -O "$_out" --header="X-Api-Key: $_key" "$_url" >/dev/null 2>&1
        _rc=$?
    elif command -v uclient-fetch >/dev/null 2>&1; then
        # uclient-fetch (BusyBox) has no -H/--header; cannot send X-Api-Key.
        # Use it only when the key can go in the URL (not supported here), so
        # treat as unavailable for authenticated calls.
        return 127
    else
        return 127
    fi

    [ "$_rc" -eq 0 ] || return 1
    [ -s "$_out" ] || return 1
    grep -q '"data"' "$_out" || return 1
    grep -q '"errors"' "$_out" && return 1
    return 0
}

# Sum every "queries" integer in a status JSON payload.
parse_queries() {
    printf '%s' "$1" \
        | tr ',' '\n' \
        | sed -n 's/.*"queries"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        | awk '{ s += $1 } END { print s + 0 }'
}

# ---------------------------------------------------------------------------
# quota cache (valid JSON, one account per line)
# ---------------------------------------------------------------------------
cache_ts() {
    [ -s "$CACHE_FILE" ] || return 1
    sed -n 's/.*"ts":\([0-9][0-9]*\).*/\1/p' "$CACHE_FILE" | head -n 1
}

# cache_get <id> <used|remaining|ok>
cache_get() {
    [ -s "$CACHE_FILE" ] || return 1
    sed -n "s/.*\"$1\":{\"used\":\([0-9-]*\),\"remaining\":\([0-9-]*\),\"ok\":\([a-z]*\).*/\1 \2 \3/p" "$CACHE_FILE" \
        | awk -v f="$2" '{
            if (f == "used") print $1
            else if (f == "remaining") print $2
            else print $3
        }'
}

# write_cache <rows_file> <timestamp>
write_cache() {
    _rows="$1"
    _ts="${2:-0}"
    _tmp="${CACHE_FILE}.tmp.$$"
    {
        printf '{"ts":%s,"accounts":{\n' "$_ts"
        _first=1
        while IFS='|' read -r _id _used _rem _ok _note; do
            case "$_note" in
                fetched|stale-cache|cached) ;;
                *) continue ;;
            esac
            [ "$_first" -eq 0 ] && printf ',\n'
            _first=0
            _okjson=false
            [ "$_ok" = "ok" ] && _okjson=true
            printf '"%s":{"used":%s,"remaining":%s,"ok":%s}' "$_id" "$_used" "$_rem" "$_okjson"
        done < "$_rows"
        printf '\n}}\n'
    } > "$_tmp"
    mv "$_tmp" "$CACHE_FILE"
}

# ---------------------------------------------------------------------------
# quota collection
# Sets globals: _ROWS_FILE, _QUOTA_FRESH
# ---------------------------------------------------------------------------
collect_quota() {
    _force="$1"
    _acct="$TMP/nexrouter_acct.$$"
    _ROWS_FILE="$TMP/nexrouter_rows.$$"
    _body="$TMP/nexrouter_body.$$"

    account_lines > "$_acct"
    : > "$_ROWS_FILE"

    _now=$(date +%s)
    _QUOTA_FRESH=0
    _use_cache=0

    if [ "$_force" -eq 0 ] && [ -s "$CACHE_FILE" ]; then
        _cts=$(cache_ts)
        if [ -n "${_cts:-}" ] && [ $((_now - _cts)) -lt "$CACHE_TTL" ]; then
            _use_cache=1
        fi
    fi

    if [ "$_use_cache" -eq 1 ]; then
        while IFS='|' read -r _id _cfg _base; do
            _used=$(cache_get "$_id" used)
            _rem=$(cache_get "$_id" remaining)
            _ok=$(cache_get "$_id" ok)
            [ -n "${_used:-}" ] || _used=0
            [ -n "${_rem:-}" ] || _rem=$(( QUOTA - _used ))
            _okrow=err
            [ "${_ok:-}" = "true" ] && _okrow=ok
            printf '%s|%s|%s|%s|cached\n' "$_id" "$_used" "$_rem" "$_okrow" >> "$_ROWS_FILE"
        done < "$_acct"
        _QUOTA_FRESH=1
    else
        _fetched_any=0
        while IFS='|' read -r _id _cfg _base; do
            _key=$(get_api_key "$_id")
            # NextDNS resets the free quota on the 1st of each month, so the
            # window MUST be the current calendar month. Using -30d straddles
            # two quota periods and overstates usage (measured: 914k vs 468k).
            _from=$(date '+%Y-%m-01')
            _url="$_base/profiles/$_cfg/analytics/status?from=$_from&limit=500"

            if [ -z "${_key:-}" ]; then
                _used=$(cache_get "$_id" used)
                _rem=$(cache_get "$_id" remaining)
                if [ -n "${_used:-}" ]; then
                    printf '%s|%s|%s|ok|stale-cache\n' "$_id" "$_used" "${_rem:-0}" >> "$_ROWS_FILE"
                else
                    printf '%s|0|%s|err|no-api-key\n' "$_id" "$QUOTA" >> "$_ROWS_FILE"
                fi
                continue
            fi

            if fetch_status_json "$_url" "$_key" "$_body"; then
                _used=$(parse_queries "$(cat "$_body")")
                [ -n "${_used:-}" ] || _used=0
                _rem=$(( QUOTA - _used ))
                [ "$_rem" -lt 0 ] && _rem=0
                printf '%s|%s|%s|ok|fetched\n' "$_id" "$_used" "$_rem" >> "$_ROWS_FILE"
                _fetched_any=1
            else
                _used=$(cache_get "$_id" used)
                _rem=$(cache_get "$_id" remaining)
                if [ -n "${_used:-}" ]; then
                    printf '%s|%s|%s|ok|stale-cache\n' "$_id" "$_used" "${_rem:-0}" >> "$_ROWS_FILE"
                else
                    printf '%s|0|%s|err|fetch-failed\n' "$_id" "$QUOTA" >> "$_ROWS_FILE"
                fi
            fi
            rm -f "$_body"
        done < "$_acct"

        if [ "$_fetched_any" -eq 1 ]; then
            write_cache "$_ROWS_FILE" "$_now"
            _QUOTA_FRESH=1
        fi
    fi

    rm -f "$_acct"
}

# ---------------------------------------------------------------------------
# presentation
# ---------------------------------------------------------------------------
pct_of() {
    _u="$1"
    if [ "$QUOTA" -gt 0 ]; then
        printf '%s%%' $(( _u * 100 / QUOTA ))
    else
        printf '0%%'
    fi
}

print_quota() {
    _rows="$1"
    _fresh="$2"

    printf '\n%-10s %-12s %14s %14s %7s  %s\n' "ID" "CONFIG" "USED" "REMAINING" "PCT" "SOURCE"
    printf '%s\n' "-----------------------------------------------------------------------------------------"
    while IFS='|' read -r _id _used _rem _ok _note; do
        _cfg=$(account_config "$_id")
        printf '%-10s %-12s %14s %14s %7s  %s\n' "$_id" "$_cfg" "$_used" "$_rem" "$(pct_of "$_used")" "$_note"
    done < "$_rows"

    _tu=0
    _tr=0
    while IFS='|' read -r _id _used _rem _ok _note; do
        _tu=$(( _tu + _used ))
        _tr=$(( _tr + _rem ))
    done < "$_rows"

    printf '%s\n' "-----------------------------------------------------------------------------------------"
    printf 'TOTAL used=%s remaining=%s (quota %s per account)\n' "$_tu" "$_tr" "$QUOTA"
    if [ "$_fresh" -ne 1 ]; then
        printf 'WARNING: quota data is stale, network fetch failed.\n'
    fi
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
do_list() {
    printf '%-10s %-12s %-28s %s\n' "ID" "CONFIG" "API" "STATUS"
    printf '%-10s %-12s %-28s %s\n' "----" "------" "---" "------"
    account_lines | while IFS='|' read -r _id _cfg _base; do
        _status="-"
        [ "$_id" = "$CURRENT" ] && _status="ACTIVE"
        printf '%-10s %-12s %-28s %s\n' "$_id" "$_cfg" "$_base" "$_status"
    done
}

do_status() {
    collect_quota 0
    print_quota "$_ROWS_FILE" "$_QUOTA_FRESH"
    rm -f "$_ROWS_FILE"
}

do_quota() {
    collect_quota 1
    print_quota "$_ROWS_FILE" "$_QUOTA_FRESH"
    rm -f "$_ROWS_FILE"
}

do_switch() {
    _id="$1"
    valid_id "$_id" || die "invalid account id: $_id"
    _line=$(account_line_by_id "$_id")
    [ -n "$_line" ] || die "unknown account: $_id"

    _cfg=$(printf '%s' "$_line" | cut -d'|' -f2)
    case "$_cfg" in
        ''|*[!A-Za-z0-9_-]*) die "invalid config id for $_id: $_cfg" ;;
    esac

    log INFO "switching to $_id (config $_cfg)"
    uci set "nextdns.main.config=$_cfg" || die "uci set config failed"
    uci set "nextdns.main.profile=$_cfg" || die "uci set profile failed"
    uci commit nextdns || die "uci commit failed"

    if [ -x "$NEXTDNS_INIT" ]; then
        "$NEXTDNS_INIT" restart || log WARN "nextdns restart returned non-zero"
    else
        log WARN "nextdns init script not executable: $NEXTDNS_INIT"
    fi

    update_current "$_id"
    log INFO "switched to $_id"
}

do_auto() {
    collect_quota 0
    _rows="$_ROWS_FILE"
    _fresh="$_QUOTA_FRESH"

    _best=""
    _best_rem=-1
    _best_used=0
    while IFS='|' read -r _id _used _rem _ok _note; do
        [ "$_ok" = "ok" ] || continue
        if [ "$_rem" -gt "$_best_rem" ]; then
            _best_rem="$_rem"
            _best="$_id"
            _best_used="$_used"
        fi
    done < "$_rows"
    rm -f "$_rows"

    if [ -z "$_best" ]; then
        log WARN "auto: no account with valid quota, keeping current config"
        return 1
    fi

    if [ "$_fresh" -ne 1 ]; then
        log WARN "auto: quota data stale (fetch failed), not switching"
        return 0
    fi

    if [ "$_best" = "$CURRENT" ]; then
        log INFO "auto: already on best account $_best (used $_best_used, remaining $_best_rem)"
        return 0
    fi

    log INFO "auto: switching to $_best (used $_best_used, remaining $_best_rem)"
    do_switch "$_best"
}

nextdns_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x nextdns >/dev/null 2>&1
        return $?
    fi
    ps 2>/dev/null | grep -v grep | grep -q '[n]extdns'
}

do_health() {
    _ok=1

    if [ -x "$NEXTDNS_INIT" ]; then
        if "$NEXTDNS_INIT" running >/dev/null 2>&1; then
            log INFO "nextdns service: running"
        elif nextdns_running; then
            log INFO "nextdns process: running"
        else
            log ERROR "nextdns is not running"
            _ok=0
        fi
    elif nextdns_running; then
        log INFO "nextdns process: running"
    else
        log ERROR "nextdns init script or process not found"
        _ok=0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        if nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
            log INFO "resolve example.com via 127.0.0.1: OK"
        else
            log ERROR "resolve example.com via 127.0.0.1: FAILED"
            _ok=0
        fi
    else
        log WARN "nslookup not available, skipping resolve test"
    fi

    [ "$_ok" -eq 1 ]
}

usage() {
    cat <<'EOF'
nexrouter.sh - NextDNS multi-account quota-aware router

Usage:
  nexrouter.sh list               list accounts and the active selection
  nexrouter.sh status             show quota per account (10-minute cache)
  nexrouter.sh quota              force a quota refresh, then show
  nexrouter.sh switch <acc_id>    switch the active NextDNS profile
  nexrouter.sh auto               switch to the account with the most remaining quota
  nexrouter.sh health             check the nextdns client and DNS resolution

Environment:
  NEXROUTER_CONF_DIR      default /etc/nexrouter
  NEXROUTER_CACHE         default /tmp/nexrouter_quota.json
  NEXROUTER_NEXTDNS_INIT  default /etc/init.d/nextdns
EOF
}

main() {
    _cmd="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$_cmd" in
        help|-h|--help)
            usage
            return 0
            ;;
    esac

    load_config

    case "$_cmd" in
        list)   do_list ;;
        status) do_status ;;
        quota)  do_quota ;;
        switch) [ $# -ge 1 ] || die "usage: nexrouter.sh switch <acc_id>"
                do_switch "$1" ;;
        auto)   do_auto ;;
        health) do_health ;;
        *)      die "unknown command: $_cmd (try: help)" ;;
    esac
}

main "$@"