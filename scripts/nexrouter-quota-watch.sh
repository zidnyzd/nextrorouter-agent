#!/bin/bash
# nexrouter-quota-watch.sh - alert ambang kuota NextDNS (cron Hermes, mode no_agent).
#
# Menjalankan `nexrouter.sh quota` di router OpenWrt, lalu mencetak pesan HANYA bila
# ada akun AKTIF dengan pemakaian >= ambang. Keluaran kosong = tidak ada pesan (sunyi).
#
# Desain anti-spam:
#   - Hanya akun dengan sisa > 0 yang boleh memicu. Akun yang sudah habis adalah
#     kondisi normal yang ditangani auto-switch, jadi tidak diulang tiap run.
#   - State per akun di /tmp/nexrouter-watch.state: satu akun memberi notifikasi
#     SEKALI sampai pemakaiannya turun di bawah ambang lagi.
#
# Env:
#   NEXROUTER_HOST      default root@192.168.1.2
#   NEXROUTER_KEY       default /home/zdna/.ssh/id_openwrt
#   NEXROUTER_SSH_OPTS  tambahan opsi ssh
#   QUOTA_WARN_PCT      default 85 (persen terpakai)
#   WATCH_STATE         default /tmp/nexrouter-watch.state

set -u

HOST="${NEXROUTER_HOST:-root@192.168.1.2}"
SSH_KEY="${NEXROUTER_KEY:-/home/zdna/.ssh/id_openwrt}"
SSH_OPTS="${NEXROUTER_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"
WARN_PCT="${QUOTA_WARN_PCT:-85}"
STATE="${WATCH_STATE:-/tmp/nexrouter-watch.state}"

if [ ! -f "$SSH_KEY" ]; then
    echo "nexrouter watch: kunci ssh tidak ditemukan: $SSH_KEY"
    exit 1
fi

# shellcheck disable=SC2086
OUT=$(ssh -i "$SSH_KEY" $SSH_OPTS "$HOST" \
    'NEXROUTER_CACHE=/tmp/nexrouter_quota.json /usr/bin/nexrouter.sh quota 2>/dev/null' 2>/dev/null)

if [ -z "$OUT" ]; then
    echo "nexrouter watch: tidak bisa menghubungi router $HOST (DNS/SSH gagal)."
    exit 1
fi

TODAY=$(date '+%Y-%m-%d %H:%M %Z')
ALERT=""
NEW_STATE=$(mktemp "${TMPDIR:-/tmp}/nexrouter-watch.XXXXXX")

while read -r id used rem pct src; do
    [ -n "${id:-}" ] || continue
    pct_n="${pct%\%}"
    rem_n="${rem:-0}"
    case "$pct_n" in ''|*[!0-9]*) continue ;; esac
    case "$rem_n" in ''|*[!0-9]*) continue ;; esac

    # akun sudah habis: catat selesai, jangan alert
    if [ "$rem_n" -le 0 ]; then
        printf '%s=done\n' "$id" >> "$NEW_STATE"
        continue
    fi

    state_val=$(grep -E "^${id}=" "$STATE" 2>/dev/null | tail -1)
    state_val="${state_val#*=}"

    printf '%s=%s\n' "$id" "$([ "$pct_n" -ge "$WARN_PCT" ] && echo alerted || echo ok)" >> "$NEW_STATE"

    if [ "$pct_n" -ge "$WARN_PCT" ] && [ "$state_val" != "alerted" ]; then
        ALERT="${ALERT}  - ${id}: ${used} query, ${pct} terpakai, sisa ${rem}
"
    fi
done <<EOF
$(printf '%s\n' "$OUT" | awk '/^[a-z0-9_-]+[[:space:]]+[a-z0-9]+[[:space:]]+[0-9]/ {print $1, $3, $4, $5, $6}')
EOF

mv "$NEW_STATE" "$STATE" 2>/dev/null || true

if [ -n "$ALERT" ]; then
    printf 'Kuota NextDNS melewati %s%% (pada %s):\n%s' "$WARN_PCT" "$TODAY" "$ALERT"
    printf 'Auto-switch cron */30 tetap jalan; ini peringatan dini, bukan kegagalan.\n'
fi

exit 0