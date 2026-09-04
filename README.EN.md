<div align="center">
  <img width="128" height="128" src="docs/screenshots/logo.png" alt="XKeen SmartRoute">

<h1>XKeen SmartRoute</h1>
<h4>DanyByLC</h4>

<p>
  Per-domain routing over a VLESS/Trojan subscription on OpenWrt/KeeneticOS routers — one command
  <br>
    <a href="#quick-start">Quick start</a>
    ·
    <a href="#documentation">Documentation</a>
    ·
    <a href="https://t.me/SmartRouteByLC">Project chat</a>
</p>

![preview](docs/screenshots/SmartRouteUI/InterfaceUI.gif)

</div>
<br>

[Русский](README.md) | **English**

Per-domain routing over a VLESS/Trojan subscription on OpenWrt routers — one command. `xkeen` (Xray-core manager) + `xkeen-UI` + our **SmartRoute** module (LuCI + a standalone panel): bind domain lists to specific subscription servers, auto-pick the fastest server in a group.

> Inspired by [itdoginfo/domain-routing-openwrt](https://github.com/itdoginfo/domain-routing-openwrt), on a different stack — `xkeen`/Xray-core instead of AmneziaWG/WireGuard, around VLESS subscriptions rather than individual keys.

---

## Contents

- [Quick start](#quick-start)
- [What gets installed where](#what-gets-installed-where)
- [What SmartRoute does](#what-smartroute-does)
- [After installation](#after-installation)
- [System requirements](#system-requirements)
- [Diagnostics](#diagnostics)
- [Documentation](#documentation)
- [Credits](#credits)
- [License and disclaimer](#license-and-disclaimer)

---

## Quick start

```sh
# Install -- over SSH on the router
sh <(wget -q -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/install.sh)
```

```sh
# Update -- same command, the script is idempotent
sh <(wget -q -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/install.sh)
```

```sh
# Uninstall
sh <(wget -q -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/uninstall.sh)
```

```sh
# Uninstall + remove all profiles/lists/subscriptions
sh <(wget -q -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/uninstall.sh) --purge
```

`xkeen`, `xkeen-UI`, and Entware are left untouched — separate projects, remove them with their own tooling.

## What gets installed where

| Path | What it is |
|---|---|
| `/opt/` | Entware (opkg; `xkeen` lives here too) |
| `/opt/etc/xray/configs/` | Xray config JSON fragments: `04_outbounds.smartroute.json` (subscription servers), `05_routing.smartroute.json` (profile rules), `07_observatory.smartroute.json` (liveness checks) |
| `/opt/share/xkeen-smartroute/lib/` | Shell scripts: `common.sh`, `subscription.sh`, `genroute.sh`, `killswitch.sh`, `redirect.sh` |
| `/etc/nftables.d/20-xkeen-smartroute-redirect.nft` | nftables traffic-capture chain — managed via `redirect.sh`, not meant to be hand-edited |
| `/etc/xkeen-smartroute/lists/` | Domain lists (geosite categories + your own `.lst`) |
| `/etc/xkeen-smartroute/profiles/` | Saved routing profiles (JSON) |
| `/etc/xkeen-smartroute/state/` | `servers.json`, `health.json` (observatory status), `gateway_password_hash` |
| `/usr/libexec/rpcd/luci.xkeen-smartroute` | Shared backend (LuCI via ubus, the panel calls it directly) |
| `/www/luci-static/resources/view/xkeen-smartroute/` | The LuCI module's JS pages |
| `/opt/share/xkeen-smartroute/gateway` | SmartRoute panel binary (port **1001**) |
| `/opt/share/xkeen-smartroute/panel/` | Panel static files |
| `/opt/etc/init.d/S98smartroute-gateway` | Panel autostart |
| `/opt/etc/init.d/S23xray-logdir` | Xray's tmpfs log directory |
| `/tmp/xray-logs/` | Xray logs (RAM, enabled manually from the Status tab) |
| xkeen-UI | `/opt/sbin/xkeen-ui`, settings in `/opt/etc/xkeen/xkeen-ui.json`, port **1000** |

## What SmartRoute does

- **Routing profiles** — domains (geosite or your own list) and/or devices (IP/CIDR) and/or IP ranges → one server or a group with auto-pick-the-fastest.
- **Our own server-picking algorithm** — not Xray's built-in `leastPing` (broken on the Xray-core version in use) → [balancer.md](docs/functionality_doc/balancer.md).
- **Policy-Based Routing by device** — "only this device," regardless of domain or combined with one.
- **IP/CIDR-based routing** — for traffic with no SNI/DNS (Telegram MTProto and similar), supports pasting/loading Keenetic Routes `.bat` format → [profiles.md](docs/UI_functionality/profiles.md).
- **VLESS/Trojan subscription import** — 17 client presets to get past a subscription provider's anti-bot checks.
- **Subscription auto-refresh** on a schedule, without losing already-saved servers on a transient failure → [subscription-update.md](docs/functionality_doc/subscription-update.md).
- **Ping + Observatory** — a real liveness check for every server, not just a bare TCP connect.
- **Your own domain lists on the fly** + ready-made lists for what's missing from geosite (Character.AI, Grok/x.ai, npm) → [domain-lists.md](docs/functionality_doc/domain-lists.md).
- **Kill-switch with zero time gap** — a permanently armed firewall rule, not once-a-minute polling; `install.sh` installs `dnsmasq-full` itself, needed for the hard layer.
- **Double VPN** — relays all traffic through one chosen gateway server, gets around an ISP's per-server blocking → [doublevpn.md](docs/functionality_doc/doublevpn.md).
- **Leak protection** — DNS, IPv6, QUIC.
- **Resilient Xray restarts** — config validated before every restart, a broken subscription node can't take the proxy down.
- **Works on plain OpenWrt**, not just KeeneticOS — its own traffic capture, around `xkeen -ap`, which is broken on this platform → [leak-protection.md](docs/functionality_doc/leak-protection.md).
- **The SmartRoute panel** (`smartroute-gateway`, port **1001**) — a LuCI alternative on the same backend: live traffic graph, server health metrics, Xray logs on demand → [gateway-architecture.md](docs/functionality_doc/gateway-architecture.md).
- Interface in **Russian and English**, in both UIs.

On top of: [`xkeen`](https://github.com/Skrill0/XKeen) — an Xray-core/Mihomo manager for Entware; [`xkeen-UI`](https://github.com/zxc-rv/XKeen-UI) (port 1000) — a separate xkeen panel for service tasks (router logs, manual config, core updates). Both are independent projects, not part of SmartRoute — `xkeen` on its own can't import a subscription or route by domain; that's what our module adds.

```
subscription → servers.json → UI (domain/device/IP × server/group) → routing.json → Xray → traffic
```

Full step-by-step breakdown — [routing-generation.md](docs/functionality_doc/routing-generation.md).

## After installation

1. `http://<router-ip>/` → **Services → XKeen SmartRoute → Subscriptions** → paste your link, "Import".
2. **Profiles** → name, domain list, mode (server / group), server(s), save — traffic follows the new rule immediately, Xray restarts automatically.
3. Domain missing from geosite? "Domains" (panel) / "Profiles" (LuCI) → "Add your own domain(s)".
4. **Kill-Switch** → enable protection for a profile.
5. Live panel: `http://<router-ip>:1001/`.
6. Service tasks (router logs, manual config, core updates): `http://<router-ip>:1000/` (xkeen-UI).

By default the panel (`:1001`) and xkeen-UI (`:1000`) listen on all router interfaces — reachable from the whole LAN, same as the router's own admin panel. Both `install.sh` and the panel's Status tab let you set a password — see the warning in [License and disclaimer](#license-and-disclaimer) before exposing the panel outside your LAN.

## System requirements

| Parameter | Requirement |
|---|---|
| Router OS | OpenWrt 22.03+ (tested: 23.05/24.10) or KeeneticOS + Entware |
| Architecture | mips/mipsel, aarch64, armv7, x86_64 |
| Free space | ~25MB minimum, the real stack needs more (see below) |
| RAM | 128MB minimum, 256MB comfortable |
| Internet during install | `bin.entware.net`, `github.com`, `raw.githubusercontent.com` |
| Subscription | a working VLESS or Trojan link (`https://.../sub/xxxxx`) |
| From your computer | SSH access to the router (`root`) |

Real space breakdown (tested: 92MB overlay): Xray 32MB + geosite/geoip 19MB + xkeen-UI 7MB + SmartRoute 14MB ≈ **72MB** total, not counting subscription/log growth. Not enough flash — attach a USB drive and set up Entware on it.

Xray on a large subscription (100+ servers) can grow to 100-120MB of RAM over time — that's exactly why `install.sh` schedules a nightly restart; on 128MB with no swap, 256MB meaningfully lowers OOM risk.

## Diagnostics

```sh
sh check.sh
# or: sh <(wget -q -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/check.sh)
```

Checks OpenWrt/Entware/xkeen/the xray process/xkeen-UI/config validity/the ubus backend/LuCI pages/server and profile counts — `[OK]`/`[FAIL]`/`[--]` per item.

| Problem | What to check |
|---|---|
| No menu entry in LuCI after install | `/etc/init.d/rpcd restart`, then reload the page (Ctrl+F5) |
| "Import" finds nothing | The subscription must serve a base64 block of `vless://`/`trojan://` — open the link in a browser, or try a different client preset |
| Refreshed the subscription, server count didn't change | Refresh runs in the background, a couple minutes on a large subscription — wait and reload; then check the gateway's log |
| Profile saved, traffic didn't switch | `sh check.sh` — is `05_routing.smartroute.json` valid; check logs via the panel (`:1001` → Status → enable logs) or xkeen-UI (`:1000`) |
| Not enough space installing Entware | Attach a USB drive, re-run `install.sh` |
| Panel on port 1001 won't open | `pgrep -f /opt/share/xkeen-smartroute/gateway` (the full path — the short `smartroute-gateway` doesn't match the real process); empty — `/opt/etc/init.d/S98smartroute-gateway restart`, log at `/etc/xkeen-smartroute/state/gateway.log` |
| Panel log shows a Xray API connection error | gRPC API listens on `127.0.0.1:10085`, enabled by `00_api.smartroute.json` — `sh check.sh` shows whether it's in place |
| Forgot the panel or xkeen-UI password | Panel: `rm /etc/xkeen-smartroute/state/gateway_password_hash && /opt/etc/init.d/S98smartroute-gateway restart` — set a new one from Status. For xkeen-UI — see its own docs |
| Install hangs / times out, but `ping 8.8.8.8` works fine | Your ISP is blocking GitHub/CDN traffic (common, SNI-based DPI) — see [docs/github-blocked-workaround.md](docs/github-blocked-workaround.md) (Russian) for an SSH-tunnel workaround from another machine |

## Documentation

This README is an install/setup overview. Technical detail, bug history, and design rationale live under `docs/`:

- **[docs/UI_functionality/](docs/UI_functionality/)** — by UI tab: what's there, how to use it.
- **[docs/functionality_doc/](docs/functionality_doc/)** — by code: why it's built this way, what bug it closes, with file/line references.

### docs/UI_functionality/ — by tab

| File | About |
|---|---|
| [README.md](docs/UI_functionality/README.md) | Section index |
| [subscriptions.md](docs/UI_functionality/subscriptions.md) | Subscriptions: import, auto-refresh, ping, observatory status |
| [profiles.md](docs/UI_functionality/profiles.md) | Profiles: create/edit, devices, IP ranges, what the "online now" dot means |
| [doublevpn.md](docs/UI_functionality/doublevpn.md) | Double VPN: the gateway server pool, auto-pick |
| [domains.md](docs/UI_functionality/domains.md) | Domains: your own lists — a dedicated tab in the panel, part of Profiles in LuCI |
| [status.md](docs/UI_functionality/status.md) | Status: services, health metrics, traffic graph, Xray logs |
| [kill-switch.md](docs/UI_functionality/kill-switch.md) | Kill-Switch: how the protection works, why geosite doesn't give 100% coverage |
| [leak-protection.md](docs/UI_functionality/leak-protection.md) | Leak protection: traffic capture, DNS/IPv6/QUIC |

### docs/functionality_doc/ — how the code works

| File | About |
|---|---|
| [README.md](docs/functionality_doc/README.md) | Section index, by topic |
| [subscription-import.md](docs/functionality_doc/subscription-import.md) | Parsing `vless://`/`trojan://`, anti-bot workarounds, server tag generation, XHTTP `extra` |
| [subscription-update.md](docs/functionality_doc/subscription-update.md) | Profile tag remapping on a subscription refresh |
| [routing-generation.md](docs/functionality_doc/routing-generation.md) | How `genroute.sh` turns a profile into Xray rules |
| [balancer.md](docs/functionality_doc/balancer.md) | Top-1 server picking, why not `leastPing` — the most detailed document in the repo (Russian) |
| [doublevpn.md](docs/functionality_doc/doublevpn.md) | Double VPN: relaying through a gateway, `sockopt.dialerProxy` (Russian) |
| [domain-lists.md](docs/functionality_doc/domain-lists.md) | Auto-updating domain lists missing from geosite (Russian) |
| [leak-protection.md](docs/functionality_doc/leak-protection.md) | nftables internals, why not `xkeen -ap`, DNS/IPv6/QUIC (Russian) |
| [kill-switch.md](docs/functionality_doc/kill-switch.md) | dnsmasq+ipset+nftables/iptables internals (OpenWrt and KeeneticOS), the `ip_ranges` gap (Russian) |
| [gateway-architecture.md](docs/functionality_doc/gateway-architecture.md) | Panel design, why not Mihomo (Russian) |
| [gateway-telemetry.md](docs/functionality_doc/gateway-telemetry.md) | gRPC client, health polling, "online now", per-profile traffic (Russian) |
| [rpc-bridge.md](docs/functionality_doc/rpc-bridge.md) | rpcd as the shared backend for LuCI and the panel (Russian) |
| [logging.md](docs/functionality_doc/logging.md) | Toggleable Xray logs, tmpfs, size cap (Russian) |
| [auth.md](docs/functionality_doc/auth.md) | Panel password/session design (Russian) |
| [install-and-process-management.md](docs/functionality_doc/install-and-process-management.md) | `install.sh`, Xray's process lifecycle, cron (Russian) |

### Everything else

| File | About |
|---|---|
| [docs/install-keenetic.md](docs/install-keenetic.md) | Installing on KeeneticOS: USB drive, Entware, OPKG, platform quirks (Russian only) |
| [docs/release-process.md](docs/release-process.md) | Branching, versioning, and CI/CD publishing (a `vX.Y.Z` tag → build → Release) |
| [docs/screenshots/README.md](docs/screenshots/README.md) | Real screenshots of the LuCI module and the SmartRoute panel |
| [AGENTS.md](AGENTS.md) | Findings log for an AI agent deploying the project on a router |

## Credits

- Project author: [DanyByLC](https://github.com/LackyCraft)
- Mentor/inspiration/reviewer and general deity: [achmel](https://github.com/achmel)
- Project chat: [t.me/SmartRouteByLC](https://t.me/SmartRouteByLC)
- [`xkeen`](https://github.com/Skrill0/XKeen) — Xray-core manager for Keenetic/Entware
- [`xkeen-UI`](https://github.com/zxc-rv/XKeen-UI) — a web panel for xkeen
- The one-command installer idea — [itdoginfo/domain-routing-openwrt](https://github.com/itdoginfo/domain-routing-openwrt)
- Xray's domain data comes from [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)

---

### 🦢 Recommended subscription (optional)

XKeen SmartRoute works with **any** standard-format VLESS/Trojan subscription — no hard tie to a specific provider. But the project has actually been tested against the [Gussi VPN](https://t.me/GussiTradeVPNbot) subscription (80+ servers worldwide) — a safe pick if you don't have one yet.

SmartRoute's author also runs their own projects: the [@GussiTrade](https://t.me/GussiTrade) channel and the [@GussiTradeVPNbot](https://t.me/GussiTradeVPNbot) VPN bot.

---

## License and disclaimer

The code is distributed under the [MIT](LICENSE) license.

This project is a tool for managing *your own* VPN subscription and *your own* router. Complying with your country's laws around VPN use and traffic routing choices is your own responsibility.

**On exposing the panel/xkeen-UI to the internet.** Opening panel access to the internet (port forwarding, DMZ, etc.) without proper security measures can lead to your router being compromised or data leaking. The project author is not liable for these consequences.
