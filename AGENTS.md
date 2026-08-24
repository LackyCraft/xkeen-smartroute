# AGENTS.md — guide for AI coding/ops agents (Claude, Codex, etc.)

This file is for an AI agent asked to deploy **XKeen SmartRoute** on someone's
OpenWrt router. It is deliberately terse and imperative — for the human-facing
explanation of what this project is, read [README.md](README.md) /
[README.EN.md](README.EN.md) first; this file only covers *how to operate it*.

Before changing any of the mechanisms below (balancer, subscription import,
kill-switch, leak protection, the gateway panel, logging, auth), read the
matching document in [docs/functionality_doc/](docs/functionality_doc/) --
it explains *why* the code is shaped the way it is, with direct links to the
lines involved, and cites the real bug each design choice closes. The
"Common failure modes" table below is a fast index into things already found
broken; the functionality_doc/ files are the fuller story behind each one.

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
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/install.sh)
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

`check.sh` doesn't currently check `smartroute-gateway` (the standalone panel,
port 1001, `gateway/` in this repo) -- verify it by hand:
`pgrep -f smartroute-gateway`, `curl -s http://127.0.0.1:1001/version`, and if
either comes back empty, `/opt/etc/init.d/S98smartroute-gateway restart` then
check `/etc/xkeen-smartroute/state/gateway.log`. It depends on Xray's gRPC API
being enabled (`00_api.smartroute.json`, `127.0.0.1:10085`) -- if the gateway
log shows a connection error there, that fragment is missing or Xray hasn't
picked it up yet (needs a restart via `lib/common.sh`'s `sr_restart_xray`, not
`xkeen -restart`).

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
| `xray run` / `xkeen -restart` prints `Illegal instruction` and exits (code 132) | xkeen's own Xray-core download is a hardfloat build; on a softfloat-only mipsel target (Entware arch ending in `sf`, e.g. `mipselsf-k3.4`) it crashes on the first FP instruction instead of erroring cleanly. Fix: `opkg install xray-core` (Entware's own package, built correctly for the target) — it installs to the same `/opt/sbin/xray` and transparently replaces the broken binary. `install.sh` does this automatically now |
| Xray fails to start: `"Global transport config has been removed and migrated to streamSettings"` | Version skew: Entware's xray-core is often much newer than xkeen's config templates expect. xkeen's `02_transport.json` uses the old top-level `transport` block, which recent Xray-core rejects outright. We don't need it (every outbound we generate has its own `streamSettings`) — `install.sh` overwrites it with `{}` |
| Xray fails to start: `infra/conf: empty "password"` / similar on a "vless-reality" outbound | xkeen's default `04_outbounds.json` ships a placeholder outbound with blank address/id/publicKey fields, meant for manual editing — and Xray refuses to start with it present even if our own `04_outbounds.smartroute.json` has valid servers, since all confdir files get merged. `install.sh` replaces it with just a `direct` (freedom) outbound |
| `S24xray` fails: `su: not found`, or later `adduser: not found` / `No passwd entry for user 'xkeen'` | xkeen runs xray as an unprivileged `xkeen` user via `su`. Needs (a) `shadow-su` from opkg for `su` itself, (b) a real `xkeen` passwd/group entry — some OpenWrt builds lack the busybox `adduser` applet entirely, and (c) a valid shell in that passwd entry (shadow's `su` defaults to `/bin/bash` if the shell field is empty, which doesn't exist on a busybox-only system — use `/bin/sh`). Note `su` reads Entware's `/opt/etc/passwd`, while plain `id`/busybox tools read the system `/etc/passwd` — on a from-scratch fix you need the account in **both** files. `install.sh` handles all of this now; if you're troubleshooting an existing install by hand, check both passwd files |
| `xkeen -status` says core not running after install | `xkeen -restart`; if that fails, check `/opt/etc/xray/configs/*.json` are valid JSON (`jq empty <file>`) — a malformed subscription line can produce broken outbounds. Also check the three rows above — a missing/incompatible Xray binary or config is the far more common cause than a bad SmartRoute-generated file |
| LuCI menu entry missing | `/etc/init.d/rpcd restart`, hard-refresh the browser (LuCI caches the menu client-side) |
| ubus calls return `{"error":"not_installed"}` | `/opt/share/xkeen-smartroute/lib/common.sh` isn't executable or missing — re-run `install.sh` |
| ubus call succeeds on one router but errors `invalid JSON text passed to --argjson` after you edit a `lib/*.sh` script and `wget` it again | `raw.githubusercontent.com` sits behind a CDN that caches for a few minutes per edge node — a `wget` right after pushing can silently fetch the pre-edit version. Compare byte size/`wc -c` against what you expect, or bust the cache with a throwaway query string (`?cb=<anything>`) |
| Kill-switch toggle does nothing | Only implemented for `domain_source.type: "custom"` profiles (dnsmasq needs literal domains); geosite-based profiles rely on the "soft" fail-closed behavior described in the README, not the firewall rule |
| A LuCI page hangs forever loading, or the browser console shows something like `X.map is not a function` | **rpcd/ubus rejects a bare top-level JSON array from a script's stdout** with "Invalid argument" — confirmed on real hardware, and only visible through the actual HTTP `/ubus/` JSON-RPC path LuCI's JS uses, *not* by invoking the rpcd script directly (`echo '{}' \| /usr/libexec/rpcd/luci.xkeen-smartroute call X`), which looks fine and hides the bug. Any new rpcd method must wrap array results in a named object field (`{"servers":[...]}`, not `[...]`) — see `wrap_array()` in the rpcd script — and unwrap it in the shared `xkeen-smartroute.js` rpc wrapper, not in each view. If you add a method that returns a list, follow this pattern or it will silently break in the browser while every other test passes |
| Status page shows Xray as stopped while it's clearly running (or the kill-switch never arms) | Don't use `pgrep -f '/opt/.*/xray'` to check whether xray is alive — it runs as bare `xray run` (no resolved path in argv), so that pattern doesn't match the real process, and instead false-matches *unrelated* commands that merely mention `/opt/etc/xray/configs/...` (e.g. our own `genroute.sh`). Use `pgrep -x xray` (match by process name) |
| Subscription import succeeds (exit 0) but reports 0 servers | Some subscription panels serve a human-facing HTML "how to connect" page by default and only return the actual base64 subscription body to requests that look like a known VPN app's User-Agent/device headers. `subscription.sh import <url> [label] [client]` — try `client` values `happ-ios`, `v2rayng`, `clash-meta`, `shadowrocket` instead of the default `smartroute`. If it still fails with a JSON `{"status":"failed",...}` body, that's a server-side error on the subscription provider's end, not something fixable client-side — fetch the URL with `curl -sSL -H 'User-Agent: ...' <url>` yourself to see the raw response before assuming it's our bug |
| `xkeen -restart` / `-start` hangs indefinitely (SSH session times out, process never returns) on real OpenWRT | xkeen's restart path writes a KeeneticOS NDM netfilter hook file (`/opt/etc/ndm/netfilter.d/proxy.sh`) and runs an iptables cleanup loop written for NDM-managed rules — neither exists on plain OpenWRT (xkeen primarily targets KeeneticOS), and the iptables loop can spin forever waiting for a rule-deletion condition that never becomes true here. **`lib/common.sh`'s `sr_restart_xray()` no longer calls `xkeen -restart` at all** — it validates the merged confdir with `xray run -test`, then directly kills/relaunches `su -c "xray run" xkeen` itself (same user/env/ulimit xkeen's own script would use), backgrounded in a subshell with `trap '' HUP` since this busybox has neither `nohup` nor `setsid`. If you're debugging by hand and see this hang, don't wait it out — `kill -9` the stuck `xkeen`/`S24xray` process tree and use `sr_restart_xray` (or replicate it manually) instead |
| `pkill: not found` / anything using `pkill` silently aborts a `set -eu` script with exit 127 | This busybox build has `pgrep` but not `pkill`. Use `for pid in $(pgrep -x name); do kill "$pid"; done` instead. This bit `sr_restart_xray` for real — grep the codebase for `pkill` before adding new process-management code |
| Xray fails to start: `"not all dependencies are resolved"` with no further detail, and a `routing.balancers[]` entry uses `"strategy": {"type": "leastPing"}` | `leastPing` depends on Xray's `observatory` feature to actually measure ping; without an `observatory` block whose `subjectSelector` matches the balanced outbound tags, Xray can't resolve the balancer's dependencies and refuses to start — cryptically, with zero mention of "observatory" in the error. `lib/genroute.sh`'s `sr_regen()` now writes `07_observatory.smartroute.json` (`subjectSelector: ["sr_"]`) whenever at least one profile is in balancer mode, and removes it otherwise. If you ever hand-craft a balancer config, remember the observatory block or you'll chase this exact unhelpful error |
| Xray fails to start: `infra/conf: Failed to build XHTTP config. > infra/conf: SeqPlacement must be path when SessionPlacement is path`, and it's blocking every restart including cron-triggered ones | One specific subscription node was observed sending an XHTTP `extra` query param (session/seq placement, padding-obfuscation fields) that this Xray build's validator hard-rejects — seen for real across multiple refreshes as the node roamed to different IPs. `lib/subscription.sh`'s `build_outbound()` no longer merges the `extra` param into `xhttpSettings` at all (just `path`/`host`/`mode`) — no server has ever needed those fields to actually connect, so dropping them entirely was safer than trying to allowlist/strip specific keys one at a time |
| A `test_out="$(cmd)"` assignment is immediately followed by `if [ $? -ne 0 ]; then ...` to handle failure, but the failure branch never runs and the script just exits early instead | Classic `set -e` trap: the assignment is a plain statement, not a condition, so a failing command substitution aborts the script *at the assignment line* — the following `if [ $? ]` is never reached. Use `if var="$(cmd)"; then ... else ...; fi` instead (conditions of `if`/`while` are exempt from `errexit`), keeping the failure-handling code inside the `else` branch. This actually happened in `sr_restart_xray` — a validation failure was silently swallowing the intended error log and leaving the script's real exit code as whatever `xray run -test` returned, not a clean 1 |
| A balancer-mode profile (`genroute.sh`/`09_balancer.smartroute.json`) references server tags that no longer exist, and `sr_restart_xray`'s validation correctly refuses to restart | Profiles pin exact server tags at save time (`.servers: [...]` in `$SR_PROFILES_DIR/<name>.json`), but tags aren't stable forever — a subscription refresh that changes which nodes are present (or the tag-collision fix landing, or a node roaming to a new IP) invalidates any profile that isn't re-synced. There's no automatic reconciliation yet: after a refresh meaningfully changes the server set, re-save affected profiles (`jq --argjson s "$(jq -c '[.[].tag]' state/servers.json)" '.servers = $s' profiles/<name>.json`, matching whatever selection logic the profile actually wants) and re-run `genroute.sh regen`. This is a known gap, not just a one-off — a real data-model fix (profiles storing a dynamic selector instead of a frozen tag list) is still open |
| `outbounds.json` / `04_outbounds.smartroute.json` accumulates dead entries for servers that no longer exist upstream | A server whose provider-side IP changes gets an entirely new tag (the tag embeds the address), so the *old* tag's outbound is never "still present" in a fresh fetch and never gets cleaned up by tag-presence filtering — it just sits there forever, silently carrying whatever config shape it had when first imported (including shapes later fixes were meant to stop producing, as happened with the XHTTP bug above). Every outbound in `SR_OUTBOUNDS_STATE_FILE` now carries a `subscription` label (stripped back out before it ever reaches Xray's real config) so `sr_import()` can do a full `select(.subscription != $lbl)` replace — identical semantics to how `servers.json` has always been handled — instead of the old keep-if-tag-still-present filter |
| Profiles saved through the real LuCI web UI don't seem to take effect — the JSON in `$SR_PROFILES_DIR` is correct, but Xray keeps running the old config until something else restarts it | rpcd (the ubus backend that runs every script this project's LuCI panel triggers) execs script handlers with a bare system `PATH` — `/usr/sbin:/usr/bin:/sbin:/bin`, confirmed via `cat /proc/<rpcd-pid>/environ` on real hardware, no `/opt/anything` — so `command -v xray` inside `sr_restart_xray` silently fails and the restart is skipped, while `save_profile`/`delete_profile` themselves still report success. This is invisible if you only test via SSH (your own shell profile already has `/opt/*` on `PATH`) or via `genroute.sh` invoked directly — it only reproduces through the actual `ubus call luci.xkeen-smartroute save_profile ...` path with rpcd's real environment. Fixed at the root: `common.sh` now does `export PATH="/opt/sbin:/opt/bin:$PATH"` itself, so every script that sources it is correct regardless of caller. If you add a new lib script, source `common.sh` first (as all of them already do) rather than assuming a sane `PATH` |
| `xray api bi --server=127.0.0.1:10085 <balancer>` prints only "Selecting Override"/"Selects" (current pick), no per-outbound ping/health despite the CLI help text saying it includes "health" | The help text is aspirational relative to the actual implementation: `GetBalancerInfo`'s proto response (`app/router/command/command.proto`) only ever carries `Override`/`PrincipleTarget`, nothing else — confirmed by reading the real xray-core source (`app/router/command/command.go`), not by trial and error. Real per-outbound alive/delay data lives in a *different* service, `ObservatoryService.GetOutboundStatus` (`app/observatory/command/command.proto`), which has no built-in CLI subcommand — `gateway/xray.go`'s `queryOutboundHealth()` calls it directly via the vendored Go client. Needs `"ObservatoryService"` added to `config.api.services` in `00_api.smartroute.json` (already done) |
| `leastPing`+`observatory` picked (or kept using) an outbound that's actually broken — e.g. Xray logs `REALITY: received real certificate (potential MITM or redirection)` for it on every real connection | Confirmed, unresolved gap in Xray-core itself ([XTLS/Xray-core#5295](https://github.com/XTLS/Xray-core/issues/5295)): observatory *does* mark the outbound dead, but `leastPing`'s selection doesn't reliably respect that. `gateway/failover.go` works around it: polls the same `ObservatoryService.GetOutboundStatus` data, and when a balancer's effective pick (native or a previous override of ours) isn't alive, calls `RoutingService.OverrideBalancerTarget` to force it onto the fastest outbound observatory currently believes is alive — the same RPC `xray api bo` uses. Don't try to "fix" this by tuning `leastPing`/`observatory` config alone; the bug is in Xray-core's selection logic, not the config |
| A raw `curl`/TLS probe straight to a REALITY server's IP:port returns "fatal alert" / connection reset | **Expected, not a sign the server is broken.** REALITY servers are specifically designed to reject or camouflage any client that doesn't present the exact right handshake (SNI/publicKey/shortId) — a generic TLS client (curl, browser, `openssl s_client`) will never produce that, so a rejected/reset connection here is the server working *correctly*, not evidence of an outage. The only meaningful health check for a REALITY outbound is a real Xray client attempt — i.e. `observatory`'s own probe (see the two rows above), not a raw socket test. Wasted real debugging time on this once; don't repeat it |
| Enabling `observatory`'s `enableConcurrency` (probe every candidate in parallel instead of sequentially) made health data *worse* — most or all outbounds suddenly reported dead | On real, memory-constrained hardware (~250MB RAM, no swap) this project runs on, probing 100+ outbounds concurrently spikes CPU load average past 3 and free memory from ~110MB to ~30MB within one probe cycle; xray's own RSS jumped from a ~37MB post-restart baseline to 114MB almost instantly. Under that resource starvation most probes then fail from local timeouts, not real server death — a strictly worse and *wrong* signal than sequential probing, while also risking a repeat OOM-kill (see next row). `lib/genroute.sh` deliberately does **not** set `enableConcurrency` — don't re-add it without first confirming the target hardware can actually handle N concurrent TLS/REALITY handshakes |
| `dmesg` shows `Out of memory: Killed process <pid> (xray) ...` | Xray's own RSS grows with uptime (observed: ~37MB right after a restart, 100MB+ after some hours running with observatory continuously probing a large subscription) — on hardware this constrained, that's enough headroom loss to risk the kernel OOM-killer taking it out at the worst moment, especially if something else on the router (a large `wget`, a `go build` artifact transfer, another restart) spikes memory at the same time. `install.sh`'s cron step now adds a once-a-day `sr_restart_xray` at a quiet hour (`15 5 * * *`) to bound the growth cheaply — it validates the merged config first, so this can't turn a working router into a broken one the way a blind `kill`+relaunch could |
| xkeen-UI's "Селекторы"/"Соединения" tabs never show up, even with `gui.routing`/`gui.log` enabled in Settings and comment-free JSON configs | These two tabs are unrelated to "GUI Mode" (the routing/log visual editor) entirely — confirmed by reading the actual frontend source (`frontend/src/components/configuration/ConfigPanel.tsx`): they're gated by `isMihomo = currentCore === 'mihomo' && (activeClashApiPort || activeClashApiUnix)`, i.e. Mihomo-core-only, and proxy straight to Mihomo's own Clash-API external-controller. On an Xray-core install (`currentCore: "xray"`, confirmed via `GET /api/control`) they will never appear, full stop — this is xkeen-UI's own upstream behavior, not a bug in our install. `smartroute-gateway`'s `/proxies` (real per-profile selector data) and the planned `/connections` are the Xray-native equivalent, surfaced through our own panel instead |
| `xray api statsquery --server=127.0.0.1:10085 -pattern 'outbound>>>'` returns `{}` forever, no matter how much real traffic flows through a profile — broke the Profiles page's "online now" dot (gateway/activity.go, GET /activity) before it ever shipped | Same precedence bug as the `.ru` routing leak above, different file: xkeen's own `06_policy.json` ships `{"policy":{"levels":{"0":{"connIdle":30}}}}` — no stats flags — while SmartRoute's own `00_api.smartroute.json` sets `policy.system.statsOutboundUplink/statsOutboundDownlink: true`. Both files declare a top-level `"policy"` key; Xray's confdir merge does not deep-merge that key across files, so whichever file the merge picks wins *entirely* and the other's content is silently discarded. `06_policy.json` sorts after `00_api.smartroute.json`, so its stats-less policy was the one actually in effect — confirmed live by moving `06_policy.json` aside and restarting: per-outbound counters appeared immediately. `install.sh` now overwrites `06_policy.json` on every run with the same `levels`+`system` block `00_api.smartroute.json` already carries, so it no longer matters which file confdir picks — both grant the same policy. If a *new* xkeen-shipped confdir file ever silently wins over one of ours again, check for a colliding top-level key (`policy`, `routing`, `log`, ...) first, not the JSON's own correctness |
| **[RESOLVED — worked around, not fixed upstream]** Every profile silently stops matching — traffic for EVERY domain (including domains explicitly listed in a `fixed`-mode custom-domain rule, and even ones that should hit the final `direct` catch-all) goes to a single unrelated outbound instead, as if zero routing rules exist | Root-caused on real hardware, this took an entire debugging session and is worth reading in full before touching `genroute.sh`'s balancer code again. **The trigger is the mere presence of any `balancerTag` rule (i.e. any `mode: "balancer"` profile) anywhere in `routing.rules` alongside other rules** — confirmed by elimination, not guesswork: (1) `xray run -test -confdir ... -dump` showed the merged config's `routing` object has a `balancers` key but **no `rules` key at all** — every rule, not just balancer ones, is silently absent from what Xray actually loads; (2) a from-scratch minimal 2-file confdir reproducing this project's exact file-split (inbounds+outbounds in one file, `routing.rules` in another) with `outboundTag` rules only — no balancer at all — worked perfectly (rule matched, catch-all matched); (3) injecting the real 160-server `04_outbounds.smartroute.json` into that same minimal test still worked — ruling out outbound count/content as the cause; (4) adding a single `balancerTag` rule (`bal_Claude`, real `09_balancer.smartroute.json`, confirmed present and healthy via `xray api bi` — a real, live, single-candidate balancer, not a broken one) back into the *same, single* routing file broke the *other*, unrelated `outboundTag` rule immediately, reproduced three separate times against the live router. Two now-eliminated theories from earlier in the investigation, kept here so they aren't re-tried: it is **not** the documented Xray-core confdir limitation that `routing.rules` doesn't merge across separate files ([XTLS/Xray-core#4593](https://github.com/XTLS/Xray-core/issues/4593)) — merging `rules` and `balancers` into one single file changed nothing; it is **not** about a shared server tag existing in both a `fixed` rule's target and a balancer's `selector` (tested a target that was a member of zero balancers — still broke). Two real, separate, now-*fixed* bugs were found and corrected during the same investigation and should stay fixed regardless of the balancer issue above: (a) `_sr_xray_launch()` in `lib/common.sh` was starting Xray with `export XRAY_LOCATION_CONFDIR=...` — **not a real Xray environment variable** (zero references to it in the compiled binary's strings; the real mechanism is the `-confdir` flag, which `_sr_xray_validate()` already used correctly, so validation always passed while the actual launch silently ran with no rules/balancers at all) — fixed to pass `-confdir` as part of the `su -c` command string instead; (b) `/opt/etc/xray/dat/` only had `geosite_v2fly.dat`/`geoip_v2fly.dat` (xkeen's own updater names files by source), not the plain `geosite.dat`/`geoip.dat` Xray's default asset loader expects for a bare `geosite:category` rule — silently breaking every geosite-based rule's parsing; `install.sh` now symlinks them. **Resolution shipped**: `genroute.sh` no longer emits `balancerTag` rules or `09_balancer.smartroute.json` at all — Xray's own balancer feature is unused entirely now. Instead, `sr_pick_top1()` does the per-profile "pick the best server from this profile's pool" job ourselves, in shell, and `sr_regen()` emits a plain `outboundTag` rule for every profile regardless of `fixed`/`balancer` mode (the same rule shape that already worked reliably). See the README section "Как выбирается сервер в группе (и почему не Xray leastPing)" / "How server-group picking actually works" for the full design (two-signal, four-tier ranking combining a fresh pool-scoped ping with `smartroute-gateway`'s own observatory-backed `health.json`) and how it was tested on real device traffic. This is a permanent workaround, not a stopgap pending an upstream fix — even if XTLS/Xray-core#6642 gets fixed, per-profile selection driven by our own real observatory data (which survives Xray restarts, unlike Xray's in-memory-only balancer state) is strictly better than handing the choice to `leastPing`. Also now eliminated: `strategy.type: "random"` (no `observatory` dependency at all) reproduces the exact same breakage as `leastPing` — so this is **not** an observatory/health-check interaction, it's about the mere presence of a `balancerTag` rule regardless of the balancer's own strategy. Pushed the reproduction to its smallest possible form: a routing config with **exactly one rule** (`{"domain":["geosite:anthropic"],"balancerTag":"bal_Claude"}`) plus the plain catch-all and nothing else — the balancer's own target domain (`claude.ai`) *and* the unrelated catch-all (`example.com`) both landed on the same wrong outbound, and that outbound was confirmed **not even a member of `bal_Claude`'s own `selector`**. So it isn't "balancerTag breaks *other* rules" — a lone balancerTag rule doesn't correctly serve its own domain either, and drags the catch-all down with it. This is conclusively an Xray-core 26.2.6 bug (or an unknown, undocumented config requirement), not anything fixable by rearranging our own JSON. Next step: file upstream against XTLS/Xray-core with this minimal repro (single `balancerTag` rule + catch-all, confdir mode, otherwise-valid balancer) — nothing this specific turned up in the existing issue tracker during this session's search. Until XTLS/Xray-core either fixes this or someone finds the missing config knob, **`mode: "balancer"` profiles cannot be offered as a working feature** — either stay on `mode: "fixed"` only, or investigate pinning to an older Xray-core release known to not have this regression (not yet tested which version range is affected; a newer release, v26.3.27 vs. this router's v26.2.6, is available upstream but was deliberately **not** tried live on the user's router this session — the user asked to hold off on a version swap, so treat this as a untried-but-plausible next step, not a dead end). A web search for prior reports turned up several *related but not exactly matching* upstream issues worth reading before re-investigating: [XTLS/Xray-core#3042](https://github.com/XTLS/Xray-core/issues/3042) describes `leastPing` balancers routing to the first/`direct` outbound only for the first ~5s after startup (observatory's first probe cycle hasn't completed yet) — self-corrects after that, which does **not** match what we saw (permanent, reproduced minutes after startup, and with `random` strategy which has no observatory dependency at all); [XTLS/Xray-core#1398](https://github.com/XTLS/Xray-core/issues/1398) reports a hard startup error ("this rule has no effective fields") for a malformed `balancerTag` rule, not silent misrouting — also not our shape, but the official routing docs quoted in the same discussion say *"you must choose one between balancerTag and outboundTag, and when both are specified, outboundTag takes effect"*, which is a real documented constraint worth double-checking our own rule objects never violate (our rules never set both on the same object, confirmed, but worth re-verifying after any `genroute.sh` change) |

## Extending domain lists

To add a list for a service not in geosite: append candidate domains to
`scripts/seeds.json` under a new key, then either run
`python3 scripts/update_lists.py` locally (needs only Python 3 stdlib) or let
the `update-domain-lists` GitHub Actions workflow do it on its weekly
schedule / manual dispatch. Don't hand-write `lists/custom/*.lst` or
`lists/ip/*.lst` directly — they get overwritten by the next pipeline run; edit
the seeds instead so the file stays reproducible.

## Publishing / pushing changes

If asked to push changes to the public repo: this project's convention is
small, topical commits (one concern per commit — engine, UI, docs, etc.),
not one giant dump. Match that style. Never commit `.env` or any file
containing a subscription URL, router password, or API token — `.gitignore`
already excludes `.env`; keep it that way.

**Branch model — see `docs/release-process.md` for the full spec, but the
short version**: feature branches (any name) → `develop` (only after real
live-router testing, not just "looks right") → `master` (only when `develop`
is stable and ready to release) → a `vX.Y.Z` tag on that `master` commit is
what actually triggers CI to build and publish binaries (`.github/workflows/
release.yml`, separate from `build-gateway.yml`'s rolling `gateway-latest`
dev channel that install.sh tracks). Never push routing/balancer/
subscription-core changes straight to `master` or `develop` without a
dedicated feature branch tested live first. A `master` merge + version tag
is a real, user-facing publish action — confirm with the user before doing
it, don't do it unprompted just because a feature branch's tests passed.
Update `CHANGELOG.md` (Keep a Changelog format) in the same commit/PR as
the release, before the tag.
