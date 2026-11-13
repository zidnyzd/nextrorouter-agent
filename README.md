# nextrorouter-agent

Lightweight NextDNS multi-account quota manager for OpenWrt.

## Why

NextDNS free tier = 300,000 queries/month **per account**. A single household easily exceeds this.  
This agent runs on OpenWrt, maintains a list of NextDNS accounts, monitors their quota via the NextDNS API, and automatically switches the active account to the one with the most remaining queries.

No Cloudflare Workers, no external dependencies, just shell scripts and cron.

## Requirements

- OpenWrt 23.05+ (tested on aarch64, 192.168.1.2)
- `nextdns` client already installed and running (listens on 127.0.0.1:5353)
- `uci`, `crond`, `wget` (GNU wget, required for `--header`), `jsonfilter` (optional)
- 2+ NextDNS free accounts (each 300k quota)

> `uclient-fetch` (BusyBox) cannot send custom headers, so `wget` is the
> required HTTP client. Verify with `wget --version` (GNU Wget 1.21+).

## Quick Start

```sh
# On your workstation
cd ~/Projects/nextrorouter-agent
# Edit agent/config.example and agent/secrets.example with your accounts
# Then deploy:
./agent/install.sh root@192.168.1.2

# On the router
vi /etc/nexrouter/accounts.conf
vi /etc/nexrouter/secrets.conf
chmod 600 /etc/nexrouter/secrets.conf

nexrouter.sh list
nexrouter.sh auto
```

## Commands

| Command | Description |
|---------|-------------|
| `nexrouter.sh list` | Show all accounts and which one is active |
| `nexrouter.sh status` | Show quota per account (cached for 10 minutes) |
| `nexrouter.sh quota` | Force a quota refresh and show |
| `nexrouter.sh switch <id>` | Switch the active NextDNS profile |
| `nexrouter.sh auto` | Switch to the account with the most remaining quota |
| `nexrouter.sh health` | Check nextdns client and DNS resolution |

Cron runs `auto` every 30 minutes: `*/30 * * * * /usr/bin/nexrouter.sh auto`

## Configuration

### `/etc/nexrouter/accounts.conf`
```sh
ACCOUNTS='acc1|a1b2c3|https://api.nextdns.io
acc2|abc123|https://api.nextdns.io'
CURRENT='acc1'
```

- `id`: short unique name, `[A-Za-z0-9_-]` only
- `config_id`: NextDNS profile ID (also called config ID)
- `api_base`: usually `https://api.nextdns.io`

> Note: this implementation uses a POSIX-compatible pipe-delimited format instead
> of the bash arrays shown in the task template, so it runs under OpenWrt's
> `ash` without requiring bash.

### `/etc/nexrouter/secrets.conf` (chmod 600)
```sh
API_KEY_acc1='your_api_key_1'
API_KEY_acc2='your_api_key_2'
```

## How It Works

1. `auto` fetches `/profiles/{id}/analytics/status?from=<YYYY-MM-01>&limit=500` for each account (with 10-min cache).
2. Sums all `queries` values → used. Remaining = 300000 - used.
3. Picks the account with the largest `remaining`.
4. If different from `CURRENT` and data is fresh (network OK), runs:
   ```sh
   uci set nextdns.main.config=<config_id>
   uci set nextdns.main.profile=<config_id>
   uci commit nextdns
   /etc/init.d/nextdns restart
   ```
5. Updates `CURRENT` in accounts.conf.

### Why the quota window is the calendar month, not `-30d`

NextDNS resets the free quota on the 1st of each month. A rolling `-30d` window
straddles two quota periods and overstates usage. Measured on one account:
`-30d` reported 914,535 queries while the current calendar month (from the 1st)
was 468,008, a 446k difference from October traffic. Use `from=%Y-%m-01`.

## Edge Cases

- **All accounts exhausted (< 5% remaining)**: still picks the largest, NextDNS continues as a plain resolver (no filtering).
- **API 401**: skips that account, logs, continues with others.
- **Network down**: uses stale cache, does **not** switch.
- **No cache + network down**: keeps current config, logs warning.

## License

MIT. See [LICENSE](LICENSE).

## Quota Alert (anti-spam)

`scripts/nexrouter-quota-watch.sh` dijalankan cron Hermes tiap 6 jam (mode no_agent):

```sh
hermes cron create '6h' --name 'Kuota NextDNS (ambang 85%)' \
  --script nexrouter-quota-watch.sh --no-agent --deliver origin
```

Perilaku:
- Sunyi total bila tidak ada akun >= 85% terpakai.
- Akun yang sudah habis (sisa 0) TIDAK diulang tiap run; itu kondisi normal yang
  sudah ditangani auto-switch.
- State per akun di `/tmp/nexrouter-watch.state`: satu akun memberi notifikasi
  SEKALI sampai pemakaiannya turun di bawah ambang, lalu boleh alert lagi bila naik.
- Ambang diatur via env `QUOTA_WARN_PCT` (default 85).
