# AGENTS.md — guide for AI coding/ops agents (Claude, Codex, etc.)

This file is for an AI agent asked to deploy **XKeen SmartRoute** on someone's
OpenWrt router. It is deliberately terse and imperative — for the human-facing
explanation of what this project is, read [README.md](README.md) /
[README.EN.md](README.EN.md) first; this file only covers *how to operate it*.

## Before doing anything

Collect these from the user — do not guess or invent them:

1. **Router LAN IP** (default `192.168.1.1`).
2. **SSH credentials** — user `root`; a fresh OpenWrt has an *empty* password
   on first boot (LuCI/SSH will demand it be set on first login). If a
   password is already set and you don't have it, ask the user — do not try
   default/common passwords.
3. **A VLESS or Trojan subscription URL** (the same link used in V2rayNG /
   V2Box). Without this, `install.sh` still runs fine but there's nothing to
   route yet.
4. Confirm with the user before: enabling/renaming Wi-Fi, changing the root
   password, or any firewall change beyond what `install.sh`/kill-switch do
   automatically. These touch a live production router — treat them like any
   other hard-to-reverse, shared-system change (see the "risky actions"
   guidance most agent harnesses already apply) and get explicit sign-off
   first, even if a prior message in the conversation authorized "the router"
   in general.

## Connecting

Plain `ssh root@<ip>` needs an interactive TTY for the first-login password
prompt, which most agent shells don't have. If your tool sandbox has no
`sshpass`/`expect`, use `paramiko` (Python) instead — it does password auth
without a pty:

```python
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.1.1", username="root", password=PASSWORD,
          look_for_keys=False, allow_agent=False, timeout=10)
stdin, stdout, stderr = c.exec_command("some command")
print(stdout.read().decode(), stderr.read().decode())
```

If the router truly has no password yet (`password=""` works), setting one
requires an interactive `passwd` (reads from a real tty) — use
`c.invoke_shell()` and feed lines with a short `time.sleep()` between them,
not `exec_command`.

## Install

One command, idempotent (safe to re-run):

```sh
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/install.sh)
```

What it needs to succeed, in order: OpenWrt (`/etc/openwrt_release` present),
~25MB+ free on `/overlay` (if not, tell the user to attach a USB drive —
don't try to free space by deleting things yourself), internet access to
`bin.entware.net` / `github.com` / `raw.githubusercontent.com`.

`install.sh` prints its architecture mapping for Entware; if it dies with
"Архитектура ... не сопоставлена" the router's `DISTRIB_ARCH` (from
`/etc/openwrt_release`) isn't in the map in `install.sh` — add the right
Entware arch string there (see https://bin.entware.net/ for the list) rather
than improvising an install by hand.

## Verify

```sh
sh check.sh
```

Every line is `[OK]`/`[FAIL]`/`[--]`. Don't declare the deploy done until this
comes back clean (or the only `[FAIL]`s are expected pre-subscription states
like "no profiles configured yet").

## Import a subscription + create a profile (no browser needed)

The LuCI UI is for humans; an agent can drive the same backend directly via
the shell libraries it calls:

```sh
sh /opt/share/xkeen-smartroute/lib/subscription.sh import "<SUBSCRIPTION_URL>" "main"
sh /opt/share/xkeen-smartroute/lib/subscription.sh list   # -> servers.json, grab a few "tag" values

cat > /tmp/profile.json <<'EOF'
{
  "name": "youtube",
  "domain_source": {"type": "geosite", "value": "youtube"},
  "mode": "balancer",
  "servers": ["sr_main_001_xxx", "sr_main_002_yyy"]
}
EOF
sh /opt/share/xkeen-smartroute/lib/genroute.sh save /tmp/profile.json
```

`mode: "fixed"` uses `"fixed_server": "<tag>"` instead of `"servers": [...]`.
`domain_source.type: "custom"` points at a file under
`/etc/xkeen-smartroute/lists/` (relative path, e.g. `"custom/grok.lst"`)
instead of a geosite category name.

**Never print the subscription URL or the contents of `servers.json`/profile
files into a public place (issues, PRs, shared logs)** — subscription links
are bearer credentials for someone's VPN account.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| `install.sh` dies on Entware download | Router has no internet yet, or DNS is broken — check `ping 1.1.1.1` and `nslookup bin.entware.net` before retrying |
| Router has no internet at all (ping fails) but LAN itself works | Check for an LAN/WAN subnet collision: `ip route` and `uci show network.lan.ipaddr` vs the WAN interface's DHCP-assigned gateway (`ubus call network.interface.wan status`) — if both sides are the identical `/24` (very common when a test OpenWrt box's default `192.168.1.1` sits behind a home gateway that also defaults to `192.168.1.1`), `dnsmasq` will refuse to use the upstream nameserver ("ignoring nameserver X.X.X.X - local interface" in `logread`) even though raw IP/ICMP traffic works. Fix: change `network.lan.ipaddr` to a non-colliding subnet (e.g. `192.168.2.1`), `uci commit network`, `ifdown lan && ifup lan` — **but this changes the router's admin URL**, so confirm with the user first, and expect your own SSH session (and DHCP lease) to need reconnecting afterward |
| `xkeen -i` prints an empty "Архитектура процессора:" and aborts with "не поддерживается" | Some busybox builds ship a `tr` that doesn't implement `[:upper:]`/`[:lower:]` POSIX classes and silently mis-maps characters instead of erroring (observed: `tr '[:upper:]' '[:lower:]'` turning `"mips"` into `"miws"`) — `xkeen`'s own architecture-detection code relies on that class syntax, so it silently breaks. Fix: `opkg install coreutils-tr` and make sure `/opt/bin` is ahead of `/bin` on `$PATH` before invoking `xkeen -i` (`install.sh` does both as of the fix that added `coreutils-tr` to its base package list — if you're looking at an older checkout, that's why this bites) |
| `xkeen -status` says core not running after install | `xkeen -restart`; if that fails, check `/opt/etc/xray/configs/*.json` are valid JSON (`jq empty <file>`) — a malformed subscription line can produce broken outbounds |
| LuCI menu entry missing | `/etc/init.d/rpcd restart`, hard-refresh the browser (LuCI caches the menu client-side) |
| ubus calls return `{"error":"not_installed"}` | `/opt/share/xkeen-smartroute/lib/common.sh` isn't executable or missing — re-run `install.sh` |
| Kill-switch toggle does nothing | Only implemented for `domain_source.type: "custom"` profiles (dnsmasq needs literal domains); geosite-based profiles rely on the "soft" fail-closed behavior described in the README, not the firewall rule |

## Extending domain lists

To add a list for a service not in geosite: append candidate domains to
`scripts/seeds.json` under a new key, then either run
`bash scripts/update-lists.sh` locally (needs `jq`, `openssl` or bash's
`/dev/tcp`) or let the `update-domain-lists` GitHub Actions workflow do it on
its weekly schedule / manual dispatch. Don't hand-write `lists/custom/*.lst`
directly — it gets overwritten by the next pipeline run; edit the seeds
instead so the file stays reproducible.

## Publishing / pushing changes

If asked to push changes to the public repo: this project's convention is
small, topical commits (one concern per commit — engine, UI, docs, etc.),
not one giant dump. Match that style. Never commit `.env` or any file
containing a subscription URL, router password, or API token — `.gitignore`
already excludes `.env`; keep it that way.
