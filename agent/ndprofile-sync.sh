#!/bin/sh
# ndprofile-sync.sh - samakan konfigurasi profil NextDNS ke semua akun dalam pool.
#
# Sumber kebenaran (source of truth) = akun pertama di accounts.conf.
# Yang disalin: security, privacy, denylist, allowlist, settings.performance,
# parentalControl. Yang TIDAK disalin: name, setup (ipv4/ipv6/linkedIp/ddns),
# fingerprint, id, logs, settings.logs/blockPage/web3.
#
# Perintah:
#   ndprofile-sync.sh status        tampilkan ringkasan config tiap akun + flag beda
#   ndprofile-sync.sh diff          tampilkan field yang beda saja (ringkas)
#   ndprofile-sync.sh push [--dry]  salin config akun sumber ke akun lain
#   ndprofile-sync.sh pull <id>     jadikan akun <id> sebagai sumber kebenaran
#
# Env:
#   NEXROUTER_CONF_DIR   default /etc/nexrouter
#
# Keluar: 0 sukses, 1 gagal.

set -u

CONF_DIR="${NEXROUTER_CONF_DIR:-/etc/nexrouter}"
ACCOUNTS_CONF="$CONF_DIR/accounts.conf"
SECRETS_CONF="$CONF_DIR/secrets.conf"

API_BASE_DEFAULT="https://api.nextdns.io"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- config
[ -r "$ACCOUNTS_CONF" ] || die "accounts config tidak ditemukan: $ACCOUNTS_CONF"
[ -r "$SECRETS_CONF" ]  || die "secrets config tidak ditemukan: $SECRETS_CONF"
. "$ACCOUNTS_CONF"
. "$SECRETS_CONF"

: "${ACCOUNTS:=}"
: "${CURRENT:=}"

valid_id() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# baris "id|cfg|base" untuk tiap akun
account_lines() {
    printf '%s\n' "$ACCOUNTS" \
        | grep -v '^[[:space:]]*#' \
        | grep -v '^[[:space:]]*$' \
        | while IFS='|' read -r _id _cfg _base; do
            valid_id "$_id" || continue
            [ -n "$_cfg" ] || continue
            [ -n "$_base" ] || _base="$API_BASE_DEFAULT"
            printf '%s|%s|%s\n' "$_id" "$_cfg" "$_base"
        done
}

api_key() { eval "printf '%s' \"\${API_KEY_$1-}\""; }

# ---------------------------------------------------------------- http
# http GET <url> <key> <out>
http_get() {
    _url="$1"; _key="$2"; _out="$3"
    : > "$_out"
    [ -n "$_key" ] || return 1
    command -v wget >/dev/null 2>&1 || { log "wget tidak ada"; return 127; }
    wget -q -T 15 -O "$_out" --header="X-Api-Key: $_key" "$_url" >/dev/null 2>&1 || return 1
    grep -q '"data"' "$_out" || return 1
    return 0
}

# http PATCH/PUT <method> <url> <key> <json-file>
# Balasan sukses NextDNS boleh kosong; hanya 4xx/5xx yang dianggap gagal.
http_write() {
    _method="$1"; _url="$2"; _key="$3"; _body="$4"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/ndsync.XXXXXX")" || return 1
    wget -q -T 20 -O "$_tmp" --header="X-Api-Key: $_key" \
        --header="Content-Type: application/json" \
        --method="$_method" --body-file="$_body" "$_url" >/dev/null 2>&1
    _rc=$?
    rm -f "$_tmp"
    return $_rc
}

# ---------------------------------------------------------------- fetch profile
# fetch_profile <cfg> <key> <out>
fetch_profile() {
    _cfg="$1"; _key="$2"; _out="$3"
    _url="$(api_base_of "$_cfg")"
    http_get "$_url/profiles/$_cfg" "$_key" "$_out"
}

# base URL per akun (default api.nextdns.io)
api_base_of() {
    account_lines | while IFS='|' read -r _id _cfg _base; do
        if [ "$_cfg" = "$1" ]; then printf '%s' "$_base"; break; fi
    done
}

# ---------------------------------------------------------------- ekstraksi
# Ekstrak bagian yang disinkronkan dari JSON profil menjadi satu payload PATCH.
# Field read-only (setup, fingerprint, id, name) dibuang.
build_sync_payload() {
    _src="$1"
    python3 - "$_src" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
d = src.get('data', src)

out = {}

# security: semua boolean, tlds dikecualikan (array read-only)
if isinstance(d.get('security'), dict):
    out['security'] = {k: v for k, v in d['security'].items() if k != 'tlds' and isinstance(v, bool)}

# privacy: boolean + natives; blocklists ditangani terpisah via PUT
if isinstance(d.get('privacy'), dict):
    p = {}
    for k, v in d['privacy'].items():
        if k == 'blocklists':
            continue
        if isinstance(v, bool):
            p[k] = v
        elif k == 'natives' and isinstance(v, list):
            p[k] = [{'id': n['id']} if isinstance(n, dict) else {'id': n} for n in v]
    if p:
        out['privacy'] = p

# settings.performance saja; logs/blockPage/web3 sengaja tidak disentuh
if isinstance(d.get('settings'), dict) and isinstance(d['settings'].get('performance'), dict):
    out['settings'] = {'performance': d['settings']['performance']}

# parentalControl: services + categories + flag
if isinstance(d.get('parentalControl'), dict):
    pc = {}
    for k, v in d['parentalControl'].items():
        if isinstance(v, bool):
            pc[k] = v
        elif k in ('services', 'categories') and isinstance(v, list):
            pc[k] = [{'id': i['id'], 'active': i.get('active', True)} if isinstance(i, dict) else i for i in v]
    if pc:
        out['parentalControl'] = pc

print(json.dumps(out))
PY
}

# Ekstrak daftar id blocklist saja
extract_blocklists() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get('data', d)
bl = d.get('privacy', {}).get('blocklists', []) or []
print(json.dumps([{'id': b['id'] if isinstance(b, dict) else b} for b in bl]))
PY
}

# Ekstrak daftar id denylist / allowlist
extract_list() {
    python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get('data', d)
key = sys.argv[2]
items = d.get(key, []) or []
print(json.dumps([{'id': i['id'] if isinstance(i, dict) else i} for i in items]))
PY
}

# Ringkas satu profil menjadi satu baris keterangan
summarize() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get('data', d)
sec = d.get('security', {}) or {}
pr = d.get('privacy', {}) or {}
perf = (d.get('settings', {}) or {}).get('performance', {}) or {}
pc = d.get('parentalControl', {}) or {}
services_on = sum(1 for s in (pc.get('services') or []) if s.get('active'))
cats_on = sum(1 for c in (pc.get('categories') or []) if c.get('active'))
sec_on = sum(1 for v in sec.values() if v is True)
print("sec_on=%d blocklists=%d denylist=%d allowlist=%d natives=%d cacheBoost=%s cnameFlat=%s ecs=%s svc_on=%d cats_on=%d" % (
    sec_on,
    len(pr.get('blocklists') or []),
    len(d.get('denylist') or []),
    len(d.get('allowlist') or []),
    len(pr.get('natives') or []),
    perf.get('cacheBoost'), perf.get('cnameFlattening'), perf.get('ecs'),
    services_on, cats_on))
PY
}

# ---------------------------------------------------------------- status/diff
do_status() {
    _first=1
    account_lines | while IFS='|' read -r _id _cfg _base; do
        _key=$(api_key "$_id")
        _f="$(mktemp "${TMPDIR:-/tmp}/ndp.XXXXXX")"
        if fetch_profile "$_cfg" "$_key" "$_f"; then
            printf '%-6s %-8s %s\n' "$_id" "$_cfg" "$(summarize "$_f")"
        else
            printf '%-6s %-8s (gagal fetch)\n' "$_id" "$_cfg"
        fi
        rm -f "$_f"
    done
}

# Nilai pembeda yang dipakai untuk mendeteksi perubahan
signature() {
    python3 - "$1" <<'PY'
import json, sys, hashlib
d = json.load(open(sys.argv[1]))
d = d.get('data', d)
keep = {}
for k in ('security', 'privacy', 'parentalControl'):
    if isinstance(d.get(k), dict):
        keep[k] = {kk: vv for kk, vv in d[k].items() if kk != 'blocklists'}
for key in ('denylist', 'allowlist'):
    if isinstance(d.get(key), list):
        keep[key] = sorted([i['id'] if isinstance(i, dict) else i for i in d[key]])
if isinstance(d.get('privacy'), dict):
    keep['blocklists'] = sorted([b['id'] if isinstance(b, dict) else b for b in (d['privacy'].get('blocklists') or [])])
if isinstance(d.get('settings'), dict) and isinstance(d['settings'].get('performance'), dict):
    keep['performance'] = d['settings']['performance']
print(hashlib.sha256(json.dumps(keep, sort_keys=True).encode()).hexdigest())
PY
}

# ---------------------------------------------------------------- push
# push ke satu akun tujuan
# push_to <tgt_id> <tgt_cfg> <tgt_base> <payload_file> <src_profile_file> <src_sig> <dry>
push_to() {
    _tid="$1"; _tcfg="$2"; _tbase="$3"; _payload="$4"; _srcprof="$5"; _srcsum="$6"; _dry="$7"

    _tkey=$(api_key "$_tid")
    [ -n "$_tkey" ] || { log "  $_tid: tidak ada API key, dilewati"; return 1; }

    _before="$(mktemp "${TMPDIR:-/tmp}/ndpb.XXXXXX")"
    if ! fetch_profile "$_tcfg" "$_tkey" "$_before"; then
        log "  $_tid: gagal fetch profil, dilewati"
        rm -f "$_before"; return 1
    fi

    _bsum=$(signature "$_before")
    if [ "$_bsum" = "$_srcsum" ]; then
        log "  $_tid: sudah identik, dilewati"
        rm -f "$_before"; return 0
    fi

    if [ "$_dry" = "1" ]; then
        log "  $_tid: [DRY] akan diubah"
        printf '    sebelum: %s\n' "$(summarize "$_before")"
        rm -f "$_before"; return 0
    fi

    log "  $_tid: menulis config..."
    http_write PATCH "$_tbase/profiles/$_tcfg" "$_tkey" "$_payload" \
        || { log "  $_tid: PATCH gagal"; rm -f "$_before"; return 1; }

    # blocklists via PUT (array penuh)
    _blf="$(mktemp "${TMPDIR:-/tmp}/ndbl.XXXXXX")"
    extract_blocklists "$_srcprof" > "$_blf"
    http_write PUT "$_tbase/profiles/$_tcfg/privacy/blocklists" "$_tkey" "$_blf" \
        || log "  $_tid: PUT blocklists gagal (lanjut)"

    # denylist & allowlist
    for _list in denylist allowlist; do
        _lf="$(mktemp "${TMPDIR:-/tmp}/ndl.XXXXXX")"
        extract_list "$_srcprof" "$_list" > "$_lf"
        _arr=$(cat "$_lf")
        if [ "$_arr" = "[]" ] || [ "$_arr" = "null" ]; then
            # akun tujuan harus dikosongkan juga: DELETE per item
            _cur="$(python3 -c "
import json,sys
d=json.load(open('$_before'))
d=d.get('data',d)
print('\n'.join([i['id'] if isinstance(i,dict) else str(i) for i in (d.get('$_list') or [])]))
")"
            printf '%s\n' "$_cur" | while IFS= read -r _item; do
                [ -n "$_item" ] || continue
                http_write DELETE "$_tbase/profiles/$_tcfg/$_list/$_item" "$_tkey" /dev/null \
                    || log "  $_tid: DELETE $_list/$_item gagal"
            done
        else
            http_write PUT "$_tbase/profiles/$_tcfg/$_list" "$_tkey" "$_lf" \
                || log "  $_tid: PUT $_list gagal"
        fi
        rm -f "$_lf"
    done

    rm -f "$_before"
    log "  $_tid: selesai"
    return 0
}

do_push() {
    _dry=0
    [ "${1:-}" = "--dry" ] && _dry=1

    _srcid="${SOURCE_ID:-}"
    if [ -z "$_srcid" ]; then
        # sumber = akun pertama di daftar
        _srcid=$(account_lines | head -n 1 | cut -d'|' -f1)
    fi
    [ -n "$_srcid" ] || die "tidak ada akun di accounts.conf"

    _srcline=$(account_line_of "$_srcid")
    _scfg=$(printf '%s' "$_srcline" | cut -d'|' -f2)
    _sbase=$(printf '%s' "$_srcline" | cut -d'|' -f3)
    _skey=$(api_key "$_srcid")
    [ -n "$_skey" ] || die "akun sumber $_srcid tidak punya API key"

    _srprof="$(mktemp "${TMPDIR:-/tmp}/nds.XXXXXX")"
    if ! fetch_profile "$_scfg" "$_skey" "$_srprof"; then
        rm -f "$_srprof"; die "gagal fetch profil sumber $_srcid"
    fi
    _srcsum=$(signature "$_srprof")
    log "SUMBER $_srcid ($_scfg): $(summarize "$_srprof")"

    _payload="$(mktemp "${TMPDIR:-/tmp}/ndpay.XXXXXX")"
    build_sync_payload "$_srprof" > "$_payload"
    log "payload: $(cat "$_payload")"

    _rc=0
    account_lines | while IFS='|' read -r _id _cfg _base; do
        [ "$_id" = "$_srcid" ] && { log "SKIP $_id (sumber)"; continue; }
        push_to "$_id" "$_cfg" "$_base" "$_payload" "$_srprof" "$_srcsum" "$_dry" || _rc=1
    done

    rm -f "$_payload" "$_srprof"
    return $_rc
}

account_line_of() {
    account_lines | while IFS='|' read -r _id _cfg _base; do
        if [ "$_id" = "$1" ]; then printf '%s|%s|%s' "$_id" "$_cfg" "$_base"; break; fi
    done
}

# ---------------------------------------------------------------- main
main() {
    _cmd="${1:-status}"
    case "$_cmd" in
        status) do_status ;;
        diff)   do_status ;;
        push)   shift; do_push "$@" ;;
        help|-h|--help)
            cat <<'EOF'
ndprofile-sync.sh - samakan konfigurasi profil NextDNS ke semua akun pool

Perintah:
  ndprofile-sync.sh status        ringkasan config tiap akun
  ndprofile-sync.sh diff          sama seperti status (deteksi perbedaan)
  ndprofile-sync.sh push [--dry]  salin config akun sumber ke akun lain
  ndprofile-sync.sh pull <id>     jadikan akun <id> sebagai sumber kebenaran

Sumber kebenaran = akun pertama di accounts.conf, atau SOURCE_ID=<id>.

Yang disalin: security, privacy (termasuk oisd/blocklist), denylist,
allowlist, settings.performance, parentalControl.
Tidak disalin: name, setup (ipv4/ipv6/linkedIp/ddns), fingerprint, logs.
EOF
            ;;
        *) die "perintah tidak dikenal: $_cmd (coba: help)" ;;
    esac
}

main "$@"