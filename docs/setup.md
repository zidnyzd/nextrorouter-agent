# Setup Guide for nextrorouter-agent

This guide walks through creating NextDNS accounts and configuring the agent.

## 1. Create NextDNS Accounts

You need at least **two** free NextDNS accounts. Each free account has a 300,000 queries/month quota (shared across all profiles in that account).

1. Go to https://my.nextdns.io/signup
2. Create Account 1, note the **API Key** (bottom of account page)
3. Create Account 2, note its **API Key**
4. In each account, create a **profile** (or use the default one). Note the **Config ID** (e.g. `4dc793`).

> The Config ID is the same as the Profile ID. It appears in the URL when you open a profile: `https://my.nextdns.io/<config_id>`

## 2. Prepare OpenWrt Router

The router must already run the `nextdns` client (OpenWrt package `nextdns`), listening on `127.0.0.1:5353`.

Verify:
```sh
nextdns -version
uci show nextdns
ps | grep nextdns
```

The UCI config should have a `nextdns.main` section with at least `config` and `profile` options.

## 3. Deploy the Agent

On your workstation:
```sh
cd ~/Projects/nextrorouter-agent
./agent/install.sh root@192.168.1.2
```

This copies files to the router and installs the cron job.

## 4. Configure on the Router

SSH into the router:
```sh
ssh root@192.168.1.2
```

Edit accounts:
```sh
vi /etc/nexrouter/accounts.conf
```

Example:
```sh
ACCOUNTS='home|4dc793|https://api.nextdns.io
mobile|abc123|https://api.nextdns.io'
CURRENT='home'
```

Edit secrets (keep permissions tight):
```sh
vi /etc/nexrouter/secrets.conf
chmod 600 /etc/nexrouter/secrets.conf
```

Example:
```sh
API_KEY_home='a8f4e42e896ff37f181e3e8a42a9737e1423d8e7'
API_KEY_mobile='b9e5f53f9a7gg48g192f4f9b53b0848f2534e9f8'
```

## 5. Test

```sh
nexrouter.sh list
# Should show both accounts, CURRENT marked ACTIVE

nexrouter.sh quota
# Force-fetches quota from NextDNS API, shows used/remaining per account

nexrouter.sh auto
# Switches to the account with the most remaining quota
```

## 6. Verify Cron

```sh
crontab -l
# Should contain: */30 * * * * /usr/bin/nexrouter.sh auto

/etc/init.d/cron status
# Should be running
```

## 7. Ongoing

- `status` uses a 10-minute cache; `quota` bypasses it.
- After 300k queries, NextDNS becomes a plain resolver (no filtering, no logging). The agent will automatically rotate accounts.
- If all accounts are near zero, the agent still picks the one with the most remaining; NextDNS continues to resolve, just without blocking.

## Troubleshooting

| Issue | Check |
|-------|-------|
| `nexrouter.sh` not found | `ls -l /usr/bin/nexrouter.sh` |
| Config not loaded | `cat /etc/nexrouter/accounts.conf` |
| API key wrong | `nexrouter.sh quota` shows `err` or `no-api-key` |
| nextdns not restarting | `/etc/init.d/nextdns restart` manually |
| Cron not running | `logread | grep cron` |

## Security

- `secrets.conf` is `chmod 600`. Only `root` can read it.
- API keys never leave the router.
- No external services, no telemetry.