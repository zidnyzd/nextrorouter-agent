#!/bin/sh
# install.sh - Deploy nexrouter to OpenWrt via scp/ssh
#
# Usage: ./agent/install.sh [target]
#   target defaults to root@192.168.1.2
#
# This script:
#   1. Creates /etc/nexrouter and /usr/bin on the target
#   2. Copies nexrouter.sh to /usr/bin/
#   3. Copies config.example -> /etc/nexrouter/accounts.conf.example
#   4. Copies secrets.example -> /etc/nexrouter/secrets.conf.example (chmod 600)
#   5. Installs the */30 cron entry in /etc/crontabs/root
#   6. Enables and starts crond
#
# It does NOT overwrite an existing /etc/nexrouter/accounts.conf or
# /etc/nexrouter/secrets.conf, and it does NOT switch the active account.

set -u

TARGET="${1:-root@192.168.1.2}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/agent"

# ---- preflight ----------------------------------------------------------
for f in nexrouter.sh config.example secrets.example; do
    [ -f "$BIN_DIR/$f" ] || { echo "missing: $BIN_DIR/$f" >&2; exit 1; }
done

command -v scp >/dev/null 2>&1 || { echo "scp not found" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }

# ---- remote directories -------------------------------------------------
ssh "$TARGET" 'mkdir -p /etc/nexrouter /usr/bin' || exit 1

# ---- copy files ---------------------------------------------------------
scp "$BIN_DIR/nexrouter.sh"  "$TARGET:/usr/bin/nexrouter.sh"             || exit 1
scp "$BIN_DIR/config.example" "$TARGET:/etc/nexrouter/accounts.conf.example" || exit 1
scp "$BIN_DIR/secrets.example" "$TARGET:/etc/nexrouter/secrets.conf.example" || exit 1

# ---- remote setup: permissions + cron + crond ---------------------------
ssh "$TARGET" 'sh -s' <<'REMOTE'
set -u

chmod 755 /usr/bin/nexrouter.sh
chmod 600 /etc/nexrouter/secrets.conf.example

CRON_FILE="/etc/crontabs/root"
CRON_LINE='*/30 * * * * /usr/bin/nexrouter.sh auto'

mkdir -p /etc/crontabs
if [ -f "$CRON_FILE" ]; then
    grep -v 'nexrouter' "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
    printf '%s\n' "$CRON_LINE" >> "$CRON_FILE.tmp"
    mv "$CRON_FILE.tmp" "$CRON_FILE"
else
    printf '%s\n' "$CRON_LINE" > "$CRON_FILE"
fi
chmod 600 "$CRON_FILE"

if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron start  2>/dev/null || true
fi

echo "deploy OK"
REMOTE

cat <<'POST'

Done. On the router, finish with:

  1. vi /etc/nexrouter/accounts.conf      # fill in account config IDs
  2. vi /etc/nexrouter/secrets.conf       # fill in API keys
  3. chmod 600 /etc/nexrouter/secrets.conf
  4. /usr/bin/nexrouter.sh list
  5. /usr/bin/nexrouter.sh quota
  6. /usr/bin/nexrouter.sh auto

Do not run switch/auto until you have verified the config.
POST