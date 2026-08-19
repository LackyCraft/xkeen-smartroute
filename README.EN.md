# XKeen SmartRoute DanyByLC

[Русский](README.md) | **English**

One-command deployment of per-domain routing over a VLESS/Trojan subscription on OpenWrt routers: `xkeen` (Xray-core manager) + `xkeen-UI` + our **SmartRoute** LuCI module, which adds what neither of them provides out of the box — binding domain lists to specific subscription servers and automatically picking the fastest server in a group.

> Inspired by [itdoginfo/domain-routing-openwrt](https://github.com/itdoginfo/domain-routing-openwrt), but built for a different stack — `xkeen`/Xray-core instead of AmneziaWG/WireGuard, and centered on VLESS subscriptions rather than single keys.

---

## Contents

- [Why](#why)
- [How it works](#how-it-works)
- [What xkeen does](#what-xkeen-does)
- [What xkeen-UI does](#what-xkeen-ui-does)
- [What SmartRoute adds](#what-smartroute-adds)
- [Cross-platform: how SmartRoute fixes xkeen on OpenWrt](#cross-platform-how-smartroute-fixes-xkeen-on-openwrt)
- [How server-group picking actually works (and why not Xray's leastPing)](#how-server-group-picking-actually-works-and-why-not-xrays-leastping)
- [The SmartRoute panel, and why not Mihomo](#the-smartroute-panel-and-why-not-mihomo)
- [System requirements](#system-requirements)
- [Installation](#installation)
- [What gets installed where](#what-gets-installed-where)
- [Quick start after install](#quick-start-after-install)
- [Domain lists missing from geosite](#domain-lists-missing-from-geosite)
- [Diagnostics and common issues](#diagnostics-and-common-issues)
- [Update and uninstall](#update-and-uninstall)
- [What the Actions and Releases tabs on the repo are for](#what-the-actions-and-releases-tabs-on-the-repo-are-for)
- [UI](#ui)
- [Credits](#credits)
- [License and disclaimer](#license-and-disclaimer)

---

## Why

You have one VLESS/Trojan subscription (same format as V2rayNG/V2Box) with a bunch of servers in different countries. A standard client lets you pick *one* server for all traffic. SmartRoute lets you configure this precisely, right from the router's web UI:

- "All of YouTube → the server in Germany"
- "Discord → pick the fastest out of these three chosen servers, and keep re-checking which one's fastest"
- "Character.AI/Grok (not in Xray's default domain database) → a dedicated server"
- "If the Xray process dies, don't let these domains fall through to a direct connection bypassing the VPN"

Everything else (not matched by any profile) behaves as usual — direct, or through whatever default outbound you've set up in `xkeen`/`xkeen-UI`.

## How it works

```
[Your VLESS/Trojan subscription]
        │
        ▼
 SmartRoute: subscription.sh  ──► server list (servers.json)
        │
        ▼
 SmartRoute LuCI module (web UI)
   • pick a domain list (an Xray geosite category OR our own file)
   • pick: 1 specific server, OR a group of servers
        │
        ▼
 SmartRoute: genroute.sh ──► routing.json + balancer.json (for Xray)
        │
        ▼
      xkeen (manages Xray-core) ──► actually moves the traffic
        │
        ▼
    xkeen-UI (port 1000) — a separate panel for service tasks:
    config editor, logs, core/geosite/geoip updates
```

Automatically picking the fastest server in a group was meant to be a built-in Xray-core mechanism (a `balancer` with the `leastPing` strategy on top of `observatory`) — but on the Xray-core version this project runs against, that turned out to be fundamentally broken in practice, so SmartRoute picks the server itself, using the same `observatory` data. Details, what was tested, and why — in [How server-group picking actually works](#how-server-group-picking-actually-works-and-why-not-xrays-leastping) below.

## What xkeen does

[`xkeen`](https://github.com/Skrill0/XKeen) is a CLI manager for Xray-core (and, optionally, the Mihomo/Clash core), installed via **Entware** (an opkg-compatible package manager for embedded systems, including OpenWrt).

- Protocols: **VLESS** (including Reality, TLS, tcp/ws/grpc/xhttp transports), **VMess**, **Trojan**, **Shadowsocks**.
- Two swappable cores: **Xray-core** and **Mihomo (Clash)**.
- The Xray config is assembled from separate JSON fragments under `/opt/etc/xray/configs/` (that's exactly where our `04_outbounds.smartroute.json`, `05_routing.smartroute.json`, `09_balancer.smartroute.json` live).
- Service control: `xkeen -start` / `-stop` / `-restart` / `-status` / `-auto`.
- Updates: `-uk` (core), `-ux` (Xray), `-um` (Mihomo), `-ug` (geosite/geoip domain & IP databases).
- Port-based inclusion/exclusion: `-ap`/`-dp`/`-ape`/`-dpe`.
- Config backup/restore: `-kb` / `-kbr`.
- Diagnostics: `-diag`, `-tpx`.
- Works as a local HTTP/SOCKS proxy and/or via firewall redirect (depending on your setup) — domain/IP routing is implemented through Xray-core's `routing.rules`, which is exactly what SmartRoute drives.

> `xkeen` has no built-in subscription-import command — that (like the rest of SmartRoute's functionality) is what our module adds.

## What xkeen-UI does

[`xkeen-UI`](https://github.com/zxc-rv/XKeen-UI) is a separate web panel for `xkeen` — a static Go binary running on **port 1000**, unrelated to LuCI (it's a standalone service).

- Start/stop/status for the Xray/Mihomo service.
- Config file editor with syntax validation.
- Log viewer (auto-refresh, filtering, timezone).
- Core switching and updates (Xray ⇄ Mihomo).
- **Outbound Generator** — a separate page: paste a link from a panel like 3X-UI → get a ready-made `outbounds.json`.
- Under the Mihomo core — Clash API: per-group node ping, pin/unpin a node right from the UI.

SmartRoute (our LuCI module + a standalone panel, see [below](#the-smartroute-panel-and-why-not-mihomo)) and xkeen-UI are independent front-ends on the same stack: xkeen-UI is great for service tasks (logs, manual config edits, core updates, backups), SmartRoute is for day-to-day "domain/device → server(s)" and live monitoring.

`install.sh` also asks once for a password to log into xkeen-UI (it ships wide open to anyone on the LAN by default) and turns it on — we recommend reusing the same password you use to log into the router itself.

## What SmartRoute adds

The `luci-app-xkeen-smartroute` module (LuCI) + `smartroute-gateway` (a standalone panel, see [below](#the-smartroute-panel-and-why-not-mihomo)) — here's what gets added on top of plain `xkeen`/`xkeen-UI`:

- **Subscription import** (VLESS/Trojan, V2rayNG/V2Box format: a base64 blob of links) — pulls a server list out of your subscription. Some subscription panels serve a plain HTML instructions page to a browser and only return the real list to a recognized VPN client (by `User-Agent` and device headers). The Subscriptions tab ships 17 client presets (Happ, v2rayNG, Clash/Clash Meta/Mihomo, sing-box, NekoBox, Shadowrocket, Stash, Surge, Loon, FlClash, V2Box, incy, etc.) plus manual Device-OS/Device-Locale/Device-Model/X-Ver-Os/X-Hwid fields (with a random-HWID generator button) under "Customize device headers…".
- **Automatic subscription refresh**: every configurable interval (12 hours by default, changeable right in the UI) every saved subscription is re-fetched with no user action needed. Refresh is multi-subscription-safe: several subscriptions won't wipe each other's servers, and an invalid/empty response from the provider (a transient hiccup) doesn't wipe out already-saved servers — it's just skipped until the next attempt.
- **Server ping**: TCP latency to every subscription server right in the UI (without ever showing IP addresses), tested against all servers in parallel.
- **Routing profiles**: a domain list (an Xray geosite category *or* your own list), **and/or** specific devices on your network (Policy-Based Routing — see below) → one specific server (`fixed`) *or* a group of servers with automatic fastest-pick (`balancer`, our own algorithm — see [below](#how-server-group-picking-actually-works-and-why-not-xrays-leastping), not Xray's built-in `leastPing`).
- **Policy-Based Routing by device**: a profile can be restricted not just by domain but by specific devices (IP/CIDR) — "only the TV goes through VPN", regardless of which sites it visits, or "only the TV, only for YouTube" — both restrictions at once. The Profiles tab shows devices detected via the router's DHCP leases and ARP table (with hostname and MAC where known), plus a manual IP/CIDR field for a statically-addressed device or a whole subnet.
- **IP/CIDR-based routing, not just by domain** — for apps whose core traffic never resolves through a domain at all. The classic case is **Telegram**: `geosite:telegram` (Xray's domain list) is only 21 entries (`telegram.org`, `t.me`, `telegra.ph`, `cdn-telegram.org`, etc.) covering the website and the web client, but the native phone/desktop apps talk MTProto **straight to datacenter IPs**, with no DNS lookup and no TLS SNI — there's nothing for Xray to sniff to apply a domain rule at all. Confirmed on a real test: `web.telegram.org` loaded fine on a `geosite:telegram` profile while the phone and desktop apps didn't, on that exact same profile. The fix: any profile (alongside domains and/or devices, or on its own) can carry a list of IP/CIDR ranges — e.g. [Telegram's own published datacenter ranges](https://core.telegram.org/resources/cidr.txt) (`91.108.56.0/22`, `149.154.160.0/20`, etc.). SmartRoute doesn't hardcode any such list itself (they drift over time) — it just adds a separate `ip`-based routing rule alongside the domain one, pointed at the same server/group.
- **Ad-hoc custom domain lists**: type domains separated by commas in the UI, and a list you can attach to a server appears immediately.
- **Bundled lists for what's missing from Xray's default database (geosite)** — see [below](#domain-lists-missing-from-geosite): currently Character.AI, Grok/x.ai, and the npm registry, auto-refreshed via GitHub Actions.
- **DNS and IPv6 leak protection**: a dedicated "Leak protection" tab — forces LAN DNS through the router itself even if a device is hardcoded to a third-party resolver (closing off a way to bypass profiles/kill-switch around the VPN), and can optionally block LAN→WAN IPv6 outright, since our traffic capture is IPv4-only and a site reachable over IPv6 could otherwise load directly through your ISP, bypassing every rule.
- **Gapless kill-switch**: once enabled for a profile, the firewall+ipset block stays armed permanently, not re-checked once a minute. DNAT-redirected traffic physically flows through the firewall's `INPUT` chain, not `FORWARD`, so the blocking rule never interferes with normal redirected traffic and can just stay on all the time — no window between Xray dying and the check catching up (the window that could have leaked a real IP before). Works for both custom domain lists and geosite categories. See the [UI](#ui) section → Kill-Switch.
- **Real live-server picking within a group** — our own algorithm, not Xray-core's built-in `leastPing` (which turned out to be fundamentally broken on the core version this project runs against, not just "doesn't always switch away" — see the [dedicated section below](#how-server-group-picking-actually-works-and-why-not-xrays-leastping) for the investigation, what was tested, and the upstream bug report).
- **Resilient Xray restarts**: the merged config is validated (`xray run -test`) before every restart — if something's wrong (a broken node from a subscription, tags drifting out of sync after a server-list change), Xray is left alone and keeps running on its last-known-good config instead of crashing. On plain OpenWrt (as opposed to KeeneticOS, xkeen's native home) the restart itself bypasses `xkeen -restart`, which hangs indefinitely on that platform. Xray is additionally restarted once a day on a schedule (overnight by default): on modest hardware with no swap its memory footprint grows over time, and a scheduled restart is cheaper than waiting for the kernel's OOM-killer to do it for us.
- **Status panel**: whether Xray is alive, how many servers and profiles are configured.
- **The SmartRoute panel** (`smartroute-gateway`, a standalone service on port `1001`) — a live, Mihomo-style dashboard: server list with ping, real-time server switching within a profile, a traffic graph, Xray's logs — no need to switch the core to Mihomo. Details and reasoning — [below](#the-smartroute-panel-and-why-not-mihomo).
- Fully **bilingual (RU/EN)** — a language switch built right into the module (LuCI can't properly compile `.po` translations without its build SDK, so the language dictionary lives inside the module itself; same for the SmartRoute panel).

## Cross-platform: how SmartRoute fixes xkeen on OpenWrt

`xkeen` was originally written for **KeeneticOS** — Keenetic routers' native platform. Entware (the environment `xkeen`/Xray-core/our whole stack lives in) officially supports OpenWrt too, so the stack itself works — but one of `xkeen`'s own built-in features, its LAN-traffic port-based redirect (`xkeen -ap`), does nothing at all on plain OpenWrt 21.02+, and here's why.

On that OpenWrt, the kernel talks **nftables** by default (via the `fw4` frontend), not classic iptables. But Entware installs its own, completely independent **legacy iptables** (`/opt/sbin/iptables` → `xtables-multi`) — and `xkeen -ap` writes its rules into that. The kernel only ever consults the real nftables stack (`/usr/sbin/iptables`, actually a compatible `xtables-nft-multi` wrapper, or `nft` itself). The result: `xkeen -ap 443,80` reports success — while real LAN devices' traffic keeps flowing right past Xray, as if the command had never run at all. We confirmed this directly on hardware: `conntrack` showed zero marking (`mark=0`) and zero connections reaching Xray's redirect port, even after `xkeen` considered the ports already enabled. This gap doesn't exist on genuine KeeneticOS — that's the stack `xkeen` was actually written against.

So SmartRoute adds its own traffic capture (`lib/redirect.sh`), independent of `xkeen -ap` — through `fw4`'s officially supported extension point, the `/etc/nftables.d/` directory. Our module drops its own nft chain there (capturing TCP 80/443 into Xray's redirect inbound, plus optional DNS/IPv6 leak-protection rules), and it survives `fw4 reload`, `/etc/init.d/firewall restart`, and a full reboot — and it's what makes the whole "route by domain/device" idea possible on this platform in the first place. Without it, profiles, kill-switch, and Policy-Based Routing would just be valid JSON that no real LAN packet ever reaches.

## How server-group picking actually works (and why not Xray's leastPing)

A profile in "server group" (`balancer`) mode is supposed to pick the fastest live server out of the chosen pool on its own. The standard way to do that in Xray-core is `routing.balancers` with the `leastPing` strategy, backed by the built-in `observatory` (which genuinely tries to connect through every server in the group). That's how it was originally implemented here — but real-hardware testing turned up a fundamental problem specific to the Xray-core version this project runs against (26.2.6).

### The problem

Simply having **any** rule with a `balancerTag` — a reference into `routing.balancers` — anywhere in the config causes **every single routing rule to stop working**, including the balancer rule itself and even the final catch-all rule ("anything else → direct"). All traffic instead falls through to whatever the first outbound in the merged config happens to be, regardless of which domain is being opened or which profile is supposed to handle it.

Confirmed on a live router by elimination:
- A minimal test config (2 files, one domain rule + a catch-all, no balancer at all) works correctly.
- The same config with the real 160-server subscription swapped in for the two test outbounds — still works.
- Adding **one** `balancerTag` rule pointing at a real, healthy, already-selecting balancer — breaks everything, including requests to that exact balancer's own domain.
- Tested both `leastPing` and `random` strategies (the latter has no dependency on `observatory` at all) — breaks identically either way, so it isn't an observatory-timing issue.
- Tested with a balancer whose group has only a single server — breaks exactly the same way.

A minimal reproduction was filed upstream: [XTLS/Xray-core#6642](https://github.com/XTLS/Xray-core/issues/6642).

### What SmartRoute does instead

Until that's fixed in Xray-core, SmartRoute doesn't use `routing.balancers`/`balancerTag` at all. Instead, `lib/genroute.sh` computes the "server #1" for each group itself and writes it as a plain `outboundTag` rule — the exact same mechanism `fixed`-mode profiles already use, and that's confirmed reliable.

The pick is based on two independent signals, because neither one alone tells the whole story:

1. **A fresh ping of just that profile's own servers** (not the whole subscription — only the ones actually in the group, which keeps it fast). Checks whether the server accepts a TCP connection right now.
2. **Real `observatory` data** — the same Xray observer, but read not through the broken balancer, straight over gRPC (`ObservatoryService.GetOutboundStatus`) by `smartroute-gateway`, which already polls it every 20 seconds for the panel. This is a **genuine** VLESS/REALITY connection attempt through the server, not a bare TCP connect.

Why both are needed: real-world testing turned up servers that answer a TCP connection almost instantly but can't actually complete a real VLESS/REALITY handshake (the server presents a genuine TLS certificate instead of the expected REALITY camouflage — a telltale sign the camouflage config is broken on the provider's side). A plain ping can't tell that server apart from a working one; only a real observatory check can.

Final ranking of candidates, best first:
1. Ping succeeded **and** observatory currently believes the server is alive — sorted by observatory's real delay.
2. Ping succeeded, but observatory hasn't reached this particular server yet (it sweeps the whole subscription one server at a time, not instantly) — sorted by the fresh ping.
3. Ping succeeded, but observatory previously flagged the server dead — used only if nothing else in the group qualifies at all.
4. Ping failed outright — last resort.

### Why not ping right before every connection

It would seem safest to check the group's servers the instant a site is opened. In practice that would mean a delay on **every new domain** the browser touches (dozens per page load — CDNs, analytics, fonts), and for large groups (a pool of 50-60 servers) that delay would be noticeable. Instead, the pick is recomputed on a schedule (every 3 minutes via `cron`) from already-fresh data — the specific group's servers still get pinged again on every recompute, it just doesn't block the page the user is trying to open.

### Keeping observatory's data across restarts, and checking what matters first

Xray's own `observatory` only keeps results in memory — every Xray restart (a profile's top pick changing, the nightly scheduled restart, etc.) resets its progress to zero. `smartroute-gateway` **persists** what it already knows across those resets (the `health.json` file is merged into, not overwritten wholesale, atomically — survives even a power cut mid-write), and every entry carries a timestamp for when it was last actually checked.

The list of servers Xray is actively probing right now (`subjectSelector`) isn't static either: every time routing is recomputed, it narrows down to whatever's actually stale (not checked within the configurable period) — servers used by current profiles first, and only once none of those are stale does it fall back to the rest of the subscription. Profile servers always get checked first this way, and a restart never throws away all accumulated progress, at most the one probe that was in flight. For the full mechanics, the real algorithm, and a live example, see [docs/balancer.md](docs/balancer.md) (Russian).

Each server's observatory status (alive / dead / not checked yet, with when it was last checked) is shown right in the server list on the Subscriptions tab, where the check period (`time_period_observatory`, 20 minutes by default) is also configurable.

## The SmartRoute panel, and why not Mihomo

`xkeen` can switch its engine from Xray-core to **Mihomo** (a Clash fork) out of the box, and Mihomo genuinely has a nice ecosystem of ready-made web dashboards (yacd, metacubexd, and so on) — that's exactly the level of interface we were aiming for. We didn't switch the engine itself, though, for a couple of reasons:

- **The Xray configs are already written and working.** The whole module (profiles, balancers, kill-switch) generates JSON specifically for Xray-core (`routing.rules`, `routing.balancers` with `leastPing`). Moving to Mihomo would mean rewriting the config generator for Clash's YAML format from scratch — just to get an interface that's reachable another way.
- **Xray-core is already debugged for this exact hardware** (see the bug history in [AGENTS.md](AGENTS.md) — everything from hardfloat/softfloat mismatches to version-skewed configs). Switching engines would mean walking part of that path again.
- Some of Mihomo's features (TUN mode, its own DNS server, a full Clash API out of the box) are overkill for this project's actual scope — the goal was targeted per-domain routing over an existing subscription, not a full replacement of the whole network stack.

So we built our own: **`smartroute-gateway`**, a small Go service that talks to the real Xray-core over its own gRPC API (traffic stats) and to SmartRoute's state (server list, profiles) directly — and serves a live dashboard on top of that, on port **`1001`**, with no engine switch involved.

The first version of the panel was built on **metacubexd** (a ready-made open-source Clash dashboard speaking the same protocol) — but in practice it turned out to assume the full Mihomo feature set (live connection tracking, DNS tools, a rule editor, a dozen protocols we don't have) and required a separate "connect" screen, leaving several tabs empty even with a fully working backend behind them. Rather than bend a third-party UI to fit what we actually have, we wrote our own — small, no build step, exactly matching what SmartRoute does:

- the subscription's server list with live ping;
- switching which server a profile uses (or auto) right from the panel — writes into the same SmartRoute profiles LuCI does, there's no second state store;
- a real-time traffic graph;
- Xray's log.

`smartroute-gateway` is installed and updated automatically by `install.sh` (built in GitHub Actions for 5 architectures: mipsle/mips-softfloat, arm7, arm64, amd64) and runs as a permanent service — nothing to start by hand.

## System requirements

**Router:**
- OpenWrt 21.02+ (tested on current 23.05/24.10); should also work on KeeneticOS with Entware (the native environment for `xkeen`) — if you're on a Keenetic, first make sure shell/SSH access is available at all.
- Architecture: mips/mipsel, aarch64, armv7, or x86_64 (anything Entware has a build for — basically any home router from the last 7-8 years).
- Free space: `install.sh` will start with **~25 MB** free on overlay, but that's cutting it close. Measured on a real test router (92 MB overlay): the Xray binary — 32 MB, geosite/geoip databases — 19 MB, xkeen-UI — 7 MB, the whole SmartRoute module (the `smartroute-gateway` panel + lib scripts + domain lists) — **~14 MB** — **~72 MB** total for the stack alone, before subscription growth or logs. If your router's flash doesn't have that, plug in a **USB stick** and put Entware there (standard practice; the Entware installer will offer to pick a partition).
- RAM: 128 MB minimum, 256 MB+ comfortable **and genuinely needed**: Xray itself sits around 25-40 MB idle, but with a large subscription (100+ servers) and continuous observatory health checks, its memory grows over time — testing observed it reach 100-120 MB after a few hours of uptime. `install.sh` sets up a nightly Xray restart via cron specifically to bound that, but a 128 MB router with no swap is still meaningfully more at risk of the kernel's OOM-killer stepping in than a 256 MB one.
- Internet access during install (needs to download Entware, xkeen, xkeen-UI, our module — access to `bin.entware.net`, `github.com`, `raw.githubusercontent.com`).
- A working **VLESS or Trojan subscription** (a URL like `https://.../sub/xxxxx` that returns a base64 server list).

**On your computer (to run the one-line install):**
- SSH access to the router (default login `root`).

## Installation

Over SSH on the router:

```sh
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/install.sh)
```

The script is idempotent — safe to re-run any number of times; already-installed pieces get skipped. Step by step, it:

1. Checks this is OpenWrt and that there's enough space.
2. Installs Entware (if not already present).
3. Installs `xkeen`.
4. Installs `xkeen-UI` (port 1000) and asks once for a password to log into it.
5. Installs our SmartRoute LuCI module + libraries + domain lists.
6. Installs `smartroute-gateway` — the panel on port 1001.
7. Sets up cron: geosite/geoip refresh every 8 hours, subscription refresh on its configured interval, plus a nightly Xray restart (guards against memory growth on modest hardware).

## What gets installed where

| Path | What it is |
|---|---|
| `/opt/` | Entware (opkg, also where `xkeen` lives) |
| `/opt/etc/xray/configs/` | Xray config JSON fragments, including our `04_outbounds.smartroute.json`, `05_routing.smartroute.json`, `09_balancer.smartroute.json` |
| `/opt/share/xkeen-smartroute/lib/` | Our shell scripts: `common.sh`, `subscription.sh`, `genroute.sh`, `killswitch.sh`, `redirect.sh` |
| `/etc/nftables.d/20-xkeen-smartroute-redirect.nft` | Our nftables traffic-capture chain (see [Cross-platform](#cross-platform-how-smartroute-fixes-xkeen-on-openwrt)) — managed by `redirect.sh`, don't edit by hand |
| `/etc/xkeen-smartroute/lists/` | Catalog of available domain lists (geosite categories + our own `.lst` files) |
| `/etc/xkeen-smartroute/profiles/` | Your saved routing profiles (JSON) — domains, and/or devices, and/or IP/CIDR ranges (see [above](#what-smartroute-adds) re: Telegram/MTProto) |
| `/etc/xkeen-smartroute/state/` | `servers.json` — servers pulled from your subscriptions; `health.json` — real per-server observatory health (see [server-group picking](#how-server-group-picking-actually-works-and-why-not-xrays-leastping)) |
| `/usr/libexec/rpcd/luci.xkeen-smartroute` | ubus backend for LuCI |
| `/www/luci-static/resources/view/xkeen-smartroute/` | Module's JS pages |
| `/opt/share/xkeen-smartroute/gateway` | The SmartRoute panel binary (port **1001**) |
| `/opt/share/xkeen-smartroute/panel/` | The panel's static files |
| `/opt/etc/init.d/S98smartroute-gateway` | Autostart for the panel |
| xkeen-UI | its own install (`/opt/sbin/xkeen-ui` or `/opt/bin/xkeen-ui`), settings in `/opt/etc/xkeen/xkeen-ui.json`, port **1000** |

## Quick start after install

1. Open `http://<router-ip>/` → **Services → XKeen SmartRoute → Subscriptions**.
2. Paste your subscription URL, click "Import" — a server list appears below.
3. Go to the **Profiles** tab: give it a name (e.g. `youtube`), pick a domain list (`geosite:youtube` category or your own), pick a mode — one specific server or a fastest-pick group, check the server(s), save.
4. Traffic for the chosen domains follows the new rule immediately — Xray restarts automatically on save.
5. If a site isn't in geosite or in the bundled lists — the same Profiles page has an "Add your own domain(s)" form: type them comma-separated, the list shows up in the picker right away.
6. On the **Kill-Switch** tab, turn on hard protection for a profile (works for both geosite and custom lists).
7. The live panel with server ping, a traffic graph, and logs — `http://<router-ip>:1001/` (SmartRoute panel).
8. Service tasks (logs, manual config, core updates) — `http://<router-ip>:1000/` (xkeen-UI).

## Domain lists missing from geosite

Xray-core uses the **geosite** database ([v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)) — hundreds of ready-made categories (`geosite:youtube`, `geosite:discord`, `geosite:openai`, `geosite:anthropic`, etc.) that SmartRoute offers out of the box, no maintenance needed on our side.

But as of 2026-08-15, that database is **missing** dedicated categories for: **Character.AI**, **Grok/x.ai**, and the **npm registry** — for those, this repo ships its own lists in `lists/custom/*.lst`, which SmartRoute also offers in the domain-list picker (flagged as "not in geosite").

(While checking, we also ruled out some common worries — ChatGPT/OpenAI and Claude/Anthropic are **already** in geosite as `openai` and `anthropic`, no separate maintenance needed there.)

These lists **auto-refresh**: the `.github/workflows/update-domain-lists.yml` workflow (`scripts/update_lists.py`) runs weekly (and on manual trigger, Actions → Update domain/IP lists → Run workflow), pulls candidates from `scripts/seeds.json`, checks that they're actually reachable (DNS + TLS handshake, with a few retries to avoid flagging things dead over a one-off network blip), and rewrites `lists/custom/*.lst` with only the live ones — if something goes dead, it drops off on the next run instead of silently rotting for years.

The same run also saves **resolved IPv4 snapshots** to `lists/ip/*.lst` — not just for the three lists above, but for a couple of popular services too (YouTube, Discord, Claude/Anthropic), purely for visibility. These are **reference-only** files, not routing data: CDN IPs rotate constantly, a one-time DNS snapshot guarantees nothing — actual routing always stays domain-based (geosite or our own list), never keyed off these IPs.

Whenever something in the lists actually changed, the pipeline commits it and publishes a **GitHub Release** describing what changed — how many domains/IPs were added/removed per service — see [Releases](https://github.com/LackyCraft/xkeen-smartroute/releases).

Want to add a list for your own service? Two ways:
- **Via PR**: add candidates to `scripts/seeds.json`, the pipeline verifies and builds the file for you.
- **Right on the router**: Profiles tab → "Add your own domain(s)" — works with zero GitHub access, entirely local.

## Diagnostics and common issues

```sh
sh check.sh
```

(or fetch and run: `sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/check.sh)`)

The script checks: OpenWrt/Entware/xkeen/the xray process/xkeen-UI/generated-config validity/presence of the ubus backend and LuCI pages/server and profile counts — and flags each as `[OK]`/`[FAIL]`/`[--]`.

| Issue | What to check |
|---|---|
| No menu entry in LuCI after install | `/etc/init.d/rpcd restart`, then hard-refresh LuCI (Ctrl+F5) |
| "Import" finds nothing | The subscription must return a base64 blob of `vless://`/`trojan://` lines — open the URL in a browser and check by hand |
| Profile saved but traffic didn't switch | Run `sh check.sh` — is `05_routing.smartroute.json` valid? Check logs via xkeen-UI (`:1000`) |
| Out of space while installing Entware | Plug in a USB stick, re-run `install.sh` |
| Panel on port 1001 doesn't load | Check `pgrep -f smartroute-gateway`; if empty — `/opt/etc/init.d/S98smartroute-gateway restart`, log at `/etc/xkeen-smartroute/state/gateway.log` |
| Panel log shows an Xray API connection error | Xray's gRPC API only listens on `127.0.0.1:10085`, enabled by the `00_api.smartroute.json` fragment — `sh check.sh` will show whether it's in place |

## Update and uninstall

Updating is just re-running `install.sh` (re-pulls our files; `xkeen`/`xkeen-UI` update through their own mechanisms — `-ux`/`-uk` etc.).

Uninstalling:

```sh
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/uninstall.sh)
# add --purge to also remove all profiles/lists:
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/uninstall.sh) --purge
```

`xkeen`, `xkeen-UI` and Entware are left untouched — they're separate projects, remove them with their own tooling if needed.

## What the Actions and Releases tabs on the repo are for

The GitHub project page has **Actions** and **Releases** tabs — both are used only by the repo's own automation; you never need to touch them by hand. Here's what's there and why:

**Actions** — two automated workflows:

- **`Build smartroute-gateway`** — on every change to the `gateway/` folder (our panel's Go code), builds a binary for 5 architectures (mipsle/mips-softfloat, arm7, arm64, amd64) and uploads them to a Release tagged `gateway-latest`. `install.sh` detects your router's architecture itself and downloads the matching file — you never need to pick or download a binary by hand.
- **`Update domain/IP lists`** — once a week (Mondays), re-verifies our bundled domain/IP lists (`lists/custom`, `lists/ip`), updates them if anything changed, and publishes a Release with a changelog of what changed.

Both workflows are fully automatic — you don't run them yourself. The Actions tab is only worth checking for diagnostics — e.g. if `install.sh` seems to be pulling a stale/broken panel build, you can check whether the latest `Build smartroute-gateway` run actually succeeded (green checkmark).

**Releases** — what those workflows publish:

- **`gateway-latest`** — a single tag, overwritten on every new panel build. It holds 5 `.gz` files, one per architecture (e.g. `smartroute-gateway-mipsle-softfloat.gz`). This isn't a project release in the usual sense ("v1.2 is out") — it's just storage for `install.sh` to pull ready-made binaries from. No need to download anything here by hand.
- **`lists-YYYY-MM-DD-N`** — a new tag each week, only when the domain/IP lists actually changed, with a changelog of what was added/removed. Also not for manual install — `install.sh`/`subscription.sh` pull the lists directly from the repo, not from Releases. These tags are just a readable history, in case you're curious what changed.

If the project ever ships a "real" versioned release (v1.0 and so on), it'll be a separate, clearly-labeled tag.

## UI

The images below are placeholders: drop a matching PNG into `docs/screenshots/` (see [docs/screenshots/README.md](docs/screenshots/README.md)) and they'll show up automatically.

![Subscriptions](docs/screenshots/subscriptions.png)
**Subscriptions** — paste a subscription URL, see the server list pulled from it.

![Profiles](docs/screenshots/profiles.png)
**Profiles** — the heart of the module: a domain list on the left, server(s) on the right, mode (fixed / auto-pick fastest) in the middle. Below that — the custom-domain form and a table of configured profiles with a delete button.

![Status](docs/screenshots/status.png)
**Status** — whether Xray is alive, how many servers and profiles the router currently knows about.

![Kill-Switch](docs/screenshots/killswitch.png)
**Kill-Switch** — a list of profiles with a toggle; gapless for any profile, both geosite categories and your own domain lists.

![Leak protection](docs/screenshots/protection.png)
**Leak protection** — DNS and IPv6 protection toggles, plus the list of TCP ports SmartRoute captures (80/443 by default).

Language switch (RU/EN) — a button in the top-right corner of every page in the module.

![SmartRoute panel](docs/screenshots/panel.png)
**The SmartRoute panel** (`http://<router-ip>:1001/`) — a standalone live dashboard: servers with ping, real-time server switching within a profile, a traffic graph, Xray's log. Details — [above](#the-smartroute-panel-and-why-not-mihomo).

## Credits

- Project author: [DanyByLC](https://github.com/LackyCraft)
- Mentor/Reviewer:[achmel](https://github.com/achmel)
- Project chat: [t.me/SmartRouteByLC](https://t.me/SmartRouteByLC)
- [`xkeen`](https://github.com/Skrill0/XKeen) — Xray-core manager for Keenetic/Entware
- [`xkeen-UI`](https://github.com/zxc-rv/XKeen-UI) — web panel for xkeen
- One-command install-script idea — [itdoginfo/domain-routing-openwrt](https://github.com/itdoginfo/domain-routing-openwrt)
- Xray domain data from [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)

---

### 🦢 Recommended subscription (optional)

XKeen SmartRoute works with **any** standard-format VLESS/Trojan subscription — there's no hard lock-in to a specific provider. That said, it's been actually tested against the [Gussi VPN](https://t.me/GussiTradeVPNbot) subscription (80 servers worldwide) — if you don't have a subscription yet and would rather not gamble on compatibility, it's a safe pick.

The SmartRoute author also runs their own projects: the [@GussiTrade](https://t.me/GussiTrade) channel and the [@GussiTradeVPNbot](https://t.me/GussiTradeVPNbot) VPN bot.

---

## License and disclaimer

Code is licensed under [MIT](LICENSE).

This project is a tool for managing *your own* VPN subscription and *your own* router. Complying with your country's laws around VPN usage and choosing which traffic to route is your responsibility.
