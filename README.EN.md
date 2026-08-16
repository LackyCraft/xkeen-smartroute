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
- [System requirements](#system-requirements)
- [Installation](#installation)
- [What gets installed where](#what-gets-installed-where)
- [Quick start after install](#quick-start-after-install)
- [Domain lists missing from geosite](#domain-lists-missing-from-geosite)
- [Diagnostics and common issues](#diagnostics-and-common-issues)
- [Update and uninstall](#update-and-uninstall)
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

Automatically picking the fastest server in a group is a built-in Xray-core mechanism — a **balancer with the `leastPing` strategy** on top of `observatory` (Xray itself pings every server in the group and keeps the route to the healthiest/fastest one). SmartRoute just generates that config from your choice in the UI — there's no custom logic bolted on top of Xray, this is an official core feature.

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

SmartRoute (our LuCI module) and xkeen-UI are two independent front-ends on the same stack: xkeen-UI is great for service tasks (logs, manual edits, updates), SmartRoute is specifically for "domain → server(s)".

## What SmartRoute adds

The `luci-app-xkeen-smartroute` module this repo installs provides:

- **Subscription import** (VLESS/Trojan, V2rayNG/V2Box format: a base64 blob of links) — pulls a server list out of your subscription. Some subscription panels serve a plain HTML instructions page to a browser and only return the real list to a recognized VPN client (by `User-Agent` and device headers). The Subscriptions tab ships 14 client presets (Happ, v2rayNG, Clash/Clash Meta/Mihomo, sing-box, NekoBox, Shadowrocket, Stash, Surge, Loon, FlClash, V2Box, etc.) plus manual Device-OS/Device-Locale/Device-Model/X-Ver-Os/X-Hwid fields (with a random-HWID generator button) under "Customize device headers…".
- **Routing profiles**: a domain list (an Xray geosite category *or* your own list) → one specific server (`fixed`) *or* a group of servers with automatic fastest-pick (`balancer` / `leastPing`).
- **Ad-hoc custom domain lists**: type domains separated by commas in the UI, and a list you can attach to a server appears immediately.
- **Bundled lists for what's missing from Xray's default database (geosite)** — see [below](#domain-lists-missing-from-geosite): currently Character.AI, Grok/x.ai, and the npm registry, auto-refreshed via GitHub Actions.
- **Kill-switch**: a hard firewall+ipset block for profiles built on your own lists if the Xray process suddenly dies (geosite-based profiles are already protected the soft way — without Xray, the redirect just fails the connection instead of falling through to the internet directly). See the [UI](#ui) section → Kill-Switch.
- **Status panel**: whether Xray is alive, how many servers and profiles are configured.
- Fully **bilingual (RU/EN)** — a language switch built right into the module (LuCI can't properly compile `.po` translations without its build SDK, so the language dictionary lives inside the module itself).

## System requirements

**Router:**
- OpenWrt 21.02+ (tested on current 23.05/24.10); should also work on KeeneticOS with Entware (the native environment for `xkeen`) — if you're on a Keenetic, first make sure shell/SSH access is available at all.
- Architecture: mips/mipsel, aarch64, armv7, or x86_64 (anything Entware has a build for — basically any home router from the last 7-8 years).
- Free space: **~25 MB** minimum on overlay for the module itself, but `xkeen` + Xray + the geosite/geoip databases realistically need **50-150 MB** — if your router's flash doesn't have that, plug in a **USB stick** and put Entware there (standard practice; the Entware installer will offer to pick a partition).
- RAM: 128 MB minimum, 256 MB+ comfortable.
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
4. Installs `xkeen-UI` (port 1000).
5. Installs our SmartRoute LuCI module + libraries + domain lists.
6. Sets up cron: geosite/geoip refresh every 8 hours, kill-switch check every minute.

## What gets installed where

| Path | What it is |
|---|---|
| `/opt/` | Entware (opkg, also where `xkeen` lives) |
| `/opt/etc/xray/configs/` | Xray config JSON fragments, including our `04_outbounds.smartroute.json`, `05_routing.smartroute.json`, `09_balancer.smartroute.json` |
| `/opt/share/xkeen-smartroute/lib/` | Our shell scripts: `common.sh`, `subscription.sh`, `genroute.sh`, `killswitch.sh` |
| `/etc/xkeen-smartroute/lists/` | Catalog of available domain lists (geosite categories + our own `.lst` files) |
| `/etc/xkeen-smartroute/profiles/` | Your saved routing profiles (JSON) |
| `/etc/xkeen-smartroute/state/` | `servers.json` — servers pulled from your subscriptions |
| `/usr/libexec/rpcd/luci.xkeen-smartroute` | ubus backend for LuCI |
| `/www/luci-static/resources/view/xkeen-smartroute/` | Module's JS pages |
| xkeen-UI | its own install, usually `/opt/share/www/XKeen-UI`, port **1000** |

## Quick start after install

1. Open `http://<router-ip>/` → **Services → XKeen SmartRoute → Subscriptions**.
2. Paste your subscription URL, click "Import" — a server list appears below.
3. Go to the **Profiles** tab: give it a name (e.g. `youtube`), pick a domain list (`geosite:youtube` category or your own), pick a mode — one specific server or a fastest-pick group, check the server(s), save.
4. Traffic for the chosen domains follows the new rule immediately — Xray restarts automatically on save.
5. If a site isn't in geosite or in the bundled lists — the same Profiles page has an "Add your own domain(s)" form: type them comma-separated, the list shows up in the picker right away.
6. On the **Kill-Switch** tab, turn on hard protection for profiles built on your own lists (optional).
7. Service tasks (logs, manual config, core updates) — `http://<router-ip>:1000/` (xkeen-UI).

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
| Kill-switch not blocking anything | Only works for profiles on your *own* lists (`custom`), not geosite categories — see the note on the Kill-Switch tab |

## Update and uninstall

Updating is just re-running `install.sh` (re-pulls our files; `xkeen`/`xkeen-UI` update through their own mechanisms — `-ux`/`-uk` etc.).

Uninstalling:

```sh
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/uninstall.sh)
# add --purge to also remove all profiles/lists:
sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/uninstall.sh) --purge
```

`xkeen`, `xkeen-UI` and Entware are left untouched — they're separate projects, remove them with their own tooling if needed.

## UI

The images below are placeholders: drop a matching PNG into `docs/screenshots/` (see [docs/screenshots/README.md](docs/screenshots/README.md)) and they'll show up automatically.

![Subscriptions](docs/screenshots/subscriptions.png)
**Subscriptions** — paste a subscription URL, see the server list pulled from it.

![Profiles](docs/screenshots/profiles.png)
**Profiles** — the heart of the module: a domain list on the left, server(s) on the right, mode (fixed / auto-pick fastest) in the middle. Below that — the custom-domain form and a table of configured profiles with a delete button.

![Status](docs/screenshots/status.png)
**Status** — whether Xray is alive, how many servers and profiles the router currently knows about.

![Kill-Switch](docs/screenshots/killswitch.png)
**Kill-Switch** — a list of profiles with a toggle; only available for profiles on your own domain lists (a limitation of the Xray/firewall combo for geosite categories, not ours).

Language switch (RU/EN) — a button in the top-right corner of every page in the module.

## Credits

- Project author: [DanyByLC](https://github.com/LackyCraft)
- [`xkeen`](https://github.com/Skrill0/XKeen) — Xray-core manager for Keenetic/Entware
- [`xkeen-UI`](https://github.com/zxc-rv/XKeen-UI) — web panel for xkeen
- One-command install-script idea — [itdoginfo/domain-routing-openwrt](https://github.com/itdoginfo/domain-routing-openwrt)
- Xray domain data from [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)

If this project was useful, you can support the author:

**SOL:** `<!-- TODO: add SOL wallet address -->`

---

### 🦢 Recommended subscription (optional)

XKeen SmartRoute works with **any** standard-format VLESS/Trojan subscription — there's no hard lock-in to a specific provider. That said, it's been actually tested against the [Gussi VPN](https://t.me/GussiTradeVPNbot) subscription (80 servers worldwide) — if you don't have a subscription yet and would rather not gamble on compatibility, it's a safe pick.

---

## License and disclaimer

Code is licensed under [MIT](LICENSE).

This project is a tool for managing *your own* VPN subscription and *your own* router. Complying with your country's laws around VPN usage and choosing which traffic to route is your responsibility.
