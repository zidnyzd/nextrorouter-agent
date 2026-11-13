#!/bin/sh
# test_agent.sh - Offline tests for nexrouter.sh (no router contact)
# Runs against mocked uci/nextdns/fetch. Safe to run anywhere.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
AGENT="$REPO/agent/nexrouter.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$FAIL" "$1"; }

assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      fail "$1 (missing: $3)" ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1 (unexpected: $3)" ;;
        *)      ok "$1" ;;
    esac
}

assert_eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        fail "$1 (expected [$3], got [$2])"
    fi
}

# ---- workspace --------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nexrouter-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/conf"

export UCI_LOG="$WORK/uci.log"
export NEXTDNS_LOG="$WORK/nextdns.log"
export HDR_LOG="$WORK/hdr.log"
: > "$UCI_LOG"
: > "$NEXTDNS_LOG"
: > "$HDR_LOG"

# ---- mocks ------------------------------------------------------------
# uci
cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$UCI_LOG"
exit 0
EOF
chmod +x "$WORK/bin/uci"

# /etc/init.d/nextdns (mock)
cat > "$WORK/bin/nextdns-init" <<'EOF'
#!/bin/sh
printf 'nextdns-init %s\n' "$*" >> "$NEXTDNS_LOG"
exit 0
EOF
chmod +x "$WORK/bin/nextdns-init"

# wget (mock)
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    --header=*) shift ;;
    -T) shift 2 ;;
    -q) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/profiles/a1b2c3/"*)
    body='{"data":[{"status":"default","queries":250000},{"status":"blocked","queries":50000}]}'
    ;;
  *"/profiles/abc123/"*)
    body='{"data":[{"status":"default","queries":10000},{"status":"blocked","queries":2000}]}'
    ;;
  *)
    body='{"errors":[{"code":"unauthorized","detail":"Bad key"}]}'
    ;;
esac
if [ -n "$out" ]; then
  printf '%s' "$body" > "$out"
else
  printf '%s' "$body"
fi
exit 0
EOF
chmod +x "$WORK/bin/wget"

# nslookup
cat > "$WORK/bin/nslookup" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/nslookup"

# logger (silence)
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/logger"

# ---- sample config ------------------------------------------------------
cat > "$WORK/conf/accounts.conf" <<'EOF'
ACCOUNTS='acc1|a1b2c3|https://api.nextdns.io
acc2|abc123|https://api.nextdns.io'
CURRENT='acc1'
EOF
cat > "$WORK/conf/secrets.conf" <<'EOF'
API_KEY_acc1='key1'
API_KEY_acc2='key2'
EOF
chmod 600 "$WORK/conf/secrets.conf"

# ---- run helper ----------------------------------------------------------
run_agent() {
    NEXROUTER_CONF_DIR="$WORK/conf" \
    NEXROUTER_CACHE="$WORK/cache.json" \
    NEXROUTER_NEXTDNS_INIT="$WORK/bin/nextdns-init" \
    PATH="$WORK/bin:$PATH" \
    "$AGENT" "$@" 2>/dev/null
}

# ---- tests ----------------------------------------------------------------
# 1. sh -n
if sh -n "$AGENT" 2>"$WORK/synerr"; then
    ok "sh -n passes"
else
    fail "sh -n failed: $(cat "$WORK/synerr")"
fi

# 2. list
out=$(run_agent list)
assert_contains "list shows acc1" "$out" "acc1"
assert_contains "list shows acc2" "$out" "acc2"
assert_contains "list marks acc1 ACTIVE" "$out" "ACTIVE"

# 3. quota (force fetch)
: > "$WORK/cache.json"
rm -f "$WORK/cache.json"
out=$(run_agent quota)
assert_contains "quota shows acc1 used 300000" "$out" "300000"
assert_contains "quota shows acc2 used 12000" "$out" "12000"
assert_contains "quota shows TOTAL" "$out" "TOTAL"

# 4. cache created
if [ -s "$WORK/cache.json" ]; then
    ok "cache file created"
else
    fail "cache file missing"
fi
assert_contains "cache contains ts" "$(cat "$WORK/cache.json")" '"ts":'
assert_contains "cache contains acc1" "$(cat "$WORK/cache.json")" '"acc1"'

# 5. switch
: > "$UCI_LOG"
: > "$NEXTDNS_LOG"
run_agent switch acc2
assert_contains "switch sets config" "$(cat "$UCI_LOG")" "nextdns.main.config=abc123"
assert_contains "switch sets profile" "$(cat "$UCI_LOG")" "nextdns.main.profile=abc123"
assert_contains "switch commits" "$(cat "$UCI_LOG")" "commit nextdns"
assert_contains "switch restarts service" "$(cat "$NEXTDNS_LOG")" "restart"
assert_contains "switch updates CURRENT" "$(cat "$WORK/conf/accounts.conf")" "CURRENT='acc2'"

# 6. auto (should switch back to acc1? no, acc2 has more remaining)
cat > "$WORK/conf/accounts.conf" <<'EOF'
ACCOUNTS='acc1|a1b2c3|https://api.nextdns.io
acc2|abc123|https://api.nextdns.io'
CURRENT='acc1'
EOF
rm -f "$WORK/cache.json"
: > "$UCI_LOG"
: > "$NEXTDNS_LOG"
run_agent auto
assert_contains "auto switches to acc2" "$(cat "$UCI_LOG")" "nextdns.main.config=abc123"
assert_contains "auto updates CURRENT" "$(cat "$WORK/conf/accounts.conf")" "CURRENT='acc2'"

# 7. auto with network failure + stale cache (should NOT switch)
# Fields: used 100k/0, remaining 200k/300k, acc2 has more, but cache is stale
cat > "$WORK/cache.json" <<'EOF'
{"ts":1000,"accounts":{
"acc1":{"used":100000,"remaining":200000,"ok":true},
"acc2":{"used":0,"remaining":300000,"ok":true}
}}
EOF
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$WORK/bin/wget"
cat > "$WORK/conf/accounts.conf" <<'EOF'
ACCOUNTS='acc1|a1b2c3|https://api.nextdns.io
acc2|abc123|https://api.nextdns.io'
CURRENT='acc1'
EOF
: > "$UCI_LOG"
out=$(run_agent auto)
rc=$?
assert_eq "auto does not fail on stale data" "$rc" "0"
assert_eq "auto does not switch on stale network" "$(cat "$UCI_LOG")" ""
assert_contains "CURRENT remains acc1" "$(cat "$WORK/conf/accounts.conf")" "CURRENT='acc1'"

# 8. auto with network failure and no cache
rm -f "$WORK/cache.json"
: > "$UCI_LOG"
out=$(run_agent auto)
rc=$?
assert_eq "auto returns non-zero with no data" "$rc" "1"
assert_eq "auto does not switch with no data" "$(cat "$UCI_LOG")" ""

# 9. health
# restore working mocks
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    --header=*) shift ;;
    -T) shift 2 ;;
    -q) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/profiles/a1b2c3/"*)
    body='{"data":[{"status":"default","queries":250000},{"status":"blocked","queries":50000}]}' ;;
  *"/profiles/abc123/"*)
    body='{"data":[{"status":"default","queries":10000},{"status":"blocked","queries":2000}]}' ;;
  *) body='{"errors":[{"code":"unauthorized"}]}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
exit 0
EOF
chmod +x "$WORK/bin/wget"
run_agent health
rc=$?
assert_eq "health passes" "$rc" "0"

# 10. switch to unknown account
out=$(run_agent switch nonexistent)
rc=$?
assert_eq "switch unknown returns non-zero" "$rc" "1"

# 11. 401 handling (acc1 fails, acc2 succeeds; auto picks acc2)
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    --header=*) shift ;;
    -T) shift 2 ;;
    -q) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/profiles/a1b2c3/"*)
    body='{"errors":[{"code":"unauthorized","detail":"Bad API key"}]}'
    ;;
  *"/profiles/abc123/"*)
    body='{"data":[{"status":"default","queries":5000}]}'
    ;;
  *)
    body='{"errors":[{"code":"unauthorized"}]}'
    ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
exit 0
EOF
chmod +x "$WORK/bin/wget"
cat > "$WORK/conf/accounts.conf" <<'EOF'
ACCOUNTS='acc1|a1b2c3|https://api.nextdns.io
acc2|abc123|https://api.nextdns.io'
CURRENT='acc1'
EOF
rm -f "$WORK/cache.json"
: > "$UCI_LOG"
out=$(run_agent auto)
assert_contains "auto picks acc2 when acc1 returns 401" "$(cat "$UCI_LOG")" "nextdns.main.config=abc123"

# 12. header X-Api-Key is actually sent with the account key (regression for '***' bug)
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
out=""
url=""
hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    --header=*) hdr="${1#--header=}"; shift ;;
    -T) shift 2 ;;
    -q) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$hdr" >> "$HDR_LOG"
body='{"data":[{"status":"default","queries":1000}]}'
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
exit 0
EOF
chmod +x "$WORK/bin/wget"
: > "$HDR_LOG"
run_agent quota >/dev/null 2>&1
assert_contains "header carries key1" "$(cat "$HDR_LOG")" "key1"
assert_contains "header carries key2" "$(cat "$HDR_LOG")" "key2"
assert_not_contains "header not literal stars" "$(cat "$HDR_LOG")" "***"

# ---- summary -------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
