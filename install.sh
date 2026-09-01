#!/bin/sh
# XKeen SmartRoute — one-shot installer for OpenWrt and KeeneticOS(+Entware).
#
#   OpenWrt:    sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/install.sh)
#   KeeneticOS: wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master/install.sh | sh
#               (this Entware shell has no /dev/fd, so process substitution
#               above doesn't work here -- use the plain pipe form instead.
#               Entware itself must already be installed first, on external
#               USB storage -- see docs/install-keenetic.md.)
#
# What it does, in order:
#   1. Sanity-checks the platform (OpenWrt, or KeeneticOS with Entware already
#      installed), checks free space.
#   2. OpenWrt only: installs Entware (if not already present) — xkeen and its
#      tooling live under /opt. On KeeneticOS, Entware is a precondition the
#      user sets up themselves (see docs/install-keenetic.md) and is only
#      verified here, never installed by this script.
#   3. Installs xkeen (Xray-core manager) + xkeen-UI (existing web panel, port 1000).
#   4. OpenWrt only: copies our LuCI app (luci-app-xkeen-smartroute). Both
#      platforms: lib/ scripts + domain-list catalog.
#   5. Installs smartroute-gateway (Mihomo-style live dashboard, port 1001) —
#      the primary UI on KeeneticOS, since there's no LuCI there.
#   6. Sets up a cron job to refresh geosite/geoip data periodically.
#
# Kill-switch and transparent redirect (lib/killswitch.sh, lib/redirect.sh)
# depend on OpenWrt's uci/fw4/nftables firewall integration and are OpenWrt-only
# for now -- skipped with a warning on KeeneticOS, pending a native NDM-firewall
# port.
#
# Safe to re-run (idempotent): existing installs are detected and skipped/updated.

set -eu

REPO_RAW="https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/master"
GATEWAY_RELEASE_BASE="https://github.com/LackyCraft/xkeen-smartroute/releases/download/gateway-latest"
XKEEN_INSTALL_URL="https://raw.githubusercontent.com/Skrill0/XKeen/main/install.sh"
XKEEN_UI_REPO="zxc-rv/XKeen-UI"
# SR_ETC_DIR is set below, after platform detection -- KeeneticOS's /etc is
# read-only (confirmed live: "mkdir: can't create directory
# '/etc/xkeen-smartroute/': Read-only file system", it's part of the
# router's own squashfs firmware image, not a writable overlay like
# OpenWrt's /etc), so it can't share OpenWrt's plain /etc/xkeen-smartroute
# path -- see the platform-detection block.
SR_SHARE_DIR="/opt/share/xkeen-smartroute"
SR_LIB_DIR="$SR_SHARE_DIR/lib"
SR_GATEWAY_PORT=1001
MIN_FREE_KB=25000

log()  { echo "[xkeen-smartroute] $*"; }
die()  { echo "[xkeen-smartroute] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Проверка окружения / Checking environment..."

if [ -f /etc/openwrt_release ]; then
	PLATFORM="openwrt"
	. /etc/openwrt_release
	log "OpenWrt $DISTRIB_RELEASE, target=$DISTRIB_TARGET, arch=$DISTRIB_ARCH"

	FREE_KB="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
	if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
		die "Слишком мало места на /overlay (${FREE_KB}KB < ${MIN_FREE_KB}KB нужно). Подключите USB-накопитель с extroot и повторите. / Not enough space on /overlay."
	fi
	log "Свободно на /overlay: ${FREE_KB:-unknown} KB"

	command -v opkg >/dev/null 2>&1 || die "opkg not found"
elif uname -r 2>/dev/null | grep -q -- '-ndm-'; then
	# KeeneticOS's own kernel builds are tagged "<ver>-ndm-<n>" (NDM = its
	# Network Device Manager) -- confirmed live on a Hero 4G+/KN-2311
	# (`uname -r` -> "4.9-ndm-5"). There's no /etc/openwrt_release
	# equivalent and no raw shell without Entware, so unlike OpenWrt,
	# Entware here is a precondition this script only verifies, never
	# installs -- see docs/install-keenetic.md for the (manual, KeeneticOS
	# OPKG page driven) setup.
	PLATFORM="keenetic"
	[ -x /opt/bin/opkg ] || die "Это KeeneticOS, но Entware (/opt/bin/opkg) не найден -- сначала поставьте Entware на внешний USB-накопитель, см. docs/install-keenetic.md, и повторите. / This is KeeneticOS but Entware (/opt/bin/opkg) wasn't found -- install Entware on external USB storage first (see docs/install-keenetic.md) and re-run."

	# No $DISTRIB_ARCH here (no /etc/openwrt_release) -- Entware's own
	# release file already records the arch it was built for, and since
	# Entware is a precondition the user installed themselves, trust it
	# instead of re-guessing from `uname -m` (which reports the bare
	# kernel arch "mips" even on this mipsel/softfloat hardware -- not
	# usable on its own to pick the right prebuilt binaries below).
	DISTRIB_ARCH="$(grep '^arch=' /opt/etc/entware_release 2>/dev/null | cut -d= -f2)"
	[ -n "$DISTRIB_ARCH" ] || die "Не удалось определить архитектуру Entware из /opt/etc/entware_release. / Could not determine Entware's architecture from /opt/etc/entware_release."
	log "KeeneticOS ($(uname -r)), Entware arch=$DISTRIB_ARCH"

	FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}')"
	if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
		die "Слишком мало места на /opt (${FREE_KB}KB < ${MIN_FREE_KB}KB нужно). / Not enough space on /opt."
	fi
	log "Свободно на /opt: ${FREE_KB:-unknown} KB"
else
	die "Неизвестная платформа -- поддерживаются только OpenWrt и KeeneticOS (с уже установленным Entware, см. docs/install-keenetic.md). / Unsupported platform -- only OpenWrt and KeeneticOS (with Entware already installed, see docs/install-keenetic.md) are supported."
fi

if [ "$PLATFORM" = "openwrt" ]; then
	SR_ETC_DIR="/etc/xkeen-smartroute"
	# `uci` (OpenWrt's own config system) doesn't exist on KeeneticOS --
	# computed once here and reused everywhere below (the gateway-ready log
	# line and the final summary) instead of repeating this same uci call
	# at each call site, which is how an earlier version of this script
	# ended up printing the wrong ("192.168.1.1" fallback) IP in one place
	# on KeeneticOS after already being fixed in the other.
	LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
else
	# /etc is read-only on KeeneticOS -- /opt/etc (on the same writable
	# external storage everything else already lives on) is the closest
	# equivalent to OpenWrt's writable /etc.
	SR_ETC_DIR="/opt/etc/xkeen-smartroute"
	# No single command like uci to ask KeeneticOS for "the LAN IP" from
	# this Entware shell -- the user already knows it, they just SSH'd into
	# this same router to run this script.
	LAN_IP="<IP роутера>"
fi

# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "openwrt" ]; then
	log "Шаг 1/6: Entware"

	if [ ! -x /opt/bin/opkg ]; then
		log "Entware не найден, устанавливаю..."
		opkg update >/dev/null 2>&1 || true
		opkg install wget-ssl ca-certificates >/dev/null 2>&1 || opkg install wget ca-certificates >/dev/null 2>&1 || true
		case "$DISTRIB_ARCH" in
			mipsel_24kc|mipsel_24kec) ENTWARE_ARCH="mipselsf-k3.4" ;;
			mips_24kc) ENTWARE_ARCH="mipssf-k3.4" ;;
			aarch64*) ENTWARE_ARCH="aarch64-k3.10" ;;
			arm_cortex-a*) ENTWARE_ARCH="armv7sf-k3.2" ;;
			x86_64) ENTWARE_ARCH="x64-k3.2" ;;
			*) die "Архитектура $DISTRIB_ARCH не сопоставлена с Entware-веткой, поставьте Entware вручную и перезапустите install.sh. / Unmapped arch for Entware, install it manually and re-run." ;;
		esac
		wget -O /tmp/entware-install.sh "https://bin.entware.net/${ENTWARE_ARCH}/installer/generic.sh" \
			|| die "не удалось скачать установщик Entware / could not download Entware installer"
		sh /tmp/entware-install.sh || die "установка Entware завершилась с ошибкой / Entware install failed"
		rm -f /tmp/entware-install.sh
	else
		log "Entware уже установлен, пропускаю."
	fi

	# Entware's own installer is supposed to leave a boot hook behind
	# (/etc/init.d/entware, calling /opt/etc/init.d/rc.unslung) so every S*
	# script under /opt/etc/init.d/ -- xray, xkeen-UI, smartroute-gateway, all
	# of it -- actually starts after a reboot. Confirmed missing on real
	# hardware: nothing under /opt started again after a router reboot until
	# this was created by hand. Idempotent and harmless to recreate even if it
	# was already there correctly. OpenWrt-only: KeeneticOS's own OPKG page
	# wires up Entware's boot sequence itself when Entware is installed
	# (confirmed live: installer log's step [4/5] "Настройка сценария
	# запуска"), there's no /etc/init.d/rc.common on KeeneticOS to hook into.
	if [ ! -x /etc/init.d/entware ]; then
		log "Хук автозапуска Entware отсутствует (/etc/init.d/entware) -- без него xray/xkeen-UI/панель не переживут перезагрузку. Создаю."
		cat > /etc/init.d/entware <<'ENTWARE_HOOK_EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

boot() {
	/opt/etc/init.d/rc.unslung start
}

start() {
	/opt/etc/init.d/rc.unslung start
}

stop() {
	/opt/etc/init.d/rc.unslung stop
}
ENTWARE_HOOK_EOF
		chmod +x /etc/init.d/entware
		/etc/init.d/entware enable
	fi

	# -------------------------------------------------------------------
	log "dnsmasq-full (нужен для hard kill-switch)"

	# The stock `dnsmasq` package on most OpenWrt builds has neither ipset nor
	# nftset compiled in (confirmed live: `dnsmasq --version` shows
	# "no-ipset no-nftset"). Without one of those, lib/killswitch.sh's hard
	# kill-switch can write all the UCI it wants -- nothing ever tells dnsmasq
	# to feed resolved IPs into the ipset the firewall REJECT rule depends on.
	# Swapping to dnsmasq-full once here, at install time (a strict superset --
	# DHCP/DNS behavior for users who never touch kill-switch is unchanged),
	# avoids every future kill-switch toggle needing this same package swap
	# under a less controlled, less visible rpcd call. Run with the system
	# `opkg` (not yet shadowed by Entware's own /opt/bin/opkg -- PATH is
	# extended below) since dnsmasq is a base-system package, not an Entware
	# one. OpenWrt-only: KeeneticOS's DNS isn't dnsmasq at all (its own
	# NDM-managed DNS proxy), and kill-switch itself is OpenWrt-only for now
	# (see the Шаг 4/6 block below) -- nothing on KeeneticOS depends on this.
	if ! dnsmasq --version 2>/dev/null | grep -q ' ipset\| nftset'; then
		opkg update >/dev/null 2>&1 || true
		opkg list-installed 2>/dev/null | grep -q '^dnsmasq -' && { opkg remove dnsmasq >/dev/null 2>&1 || true; }
		if opkg install dnsmasq-full >/dev/null 2>&1; then
			/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
			log "dnsmasq-full установлен."
		else
			log "ПРЕДУПРЕЖДЕНИЕ: не удалось поставить dnsmasq-full -- hard kill-switch будет недоступен, пока не поставите его вручную (opkg remove dnsmasq && opkg install dnsmasq-full). / WARNING: could not install dnsmasq-full -- hard kill-switch unavailable until installed manually."
		fi
	else
		log "dnsmasq уже поддерживает ipset/nftset, пропускаю."
	fi
else
	log "Шаг 1/6: Entware (уже установлен на внешний накопитель, только проверка) / Entware (already installed on external storage, verifying only)"
fi

export PATH="/opt/bin:/opt/sbin:$PATH"
/opt/bin/opkg update >/dev/null 2>&1 || true
# wget-ssl/ca-certificates: on OpenWrt this is normally already pulled in by
# the system-opkg step above before Entware's bootstrap even runs. On
# KeeneticOS that step never runs (Entware is a precondition, not installed
# by us) and a fresh Entware install does NOT ship wget-ssl by default --
# confirmed live: bare `wget` resolves via $PATH to /opt/usr/bin/wget (a
# non-SSL busybox-style wget from the opt-ndmsv2 package, which sorts before
# /opt/bin on that platform's default $PATH) and fails every https:// URL
# with "not an http or ftp url" until wget-ssl is installed. Installing it
# unconditionally here (cheap no-op if already present) means every `wget`
# call below -- on either platform -- resolves correctly once $PATH is
# extended just above.
# tar: xkeen's own installer (Skrill0/XKeen) extracts its release tarball
# with `tar --overwrite`, a GNU-tar-only flag busybox's built-in tar applet
# doesn't understand -- confirmed live on KeeneticOS/Entware: when xkeen's
# own installer's own attempt to pull Entware's tar package hit a transient
# download failure (a real network blip, not a permanent issue), it silently
# fell back to busybox tar and died with "tar: unrecognized option
# '--overwrite'" mid-install. Installing it ourselves here means xkeen's
# installer never needs to succeed at that step on its own.
/opt/bin/opkg install jq curl bash coreutils-base64 coreutils-tr coreutils-timeout unzip tar shadow-su grep sed wget-ssl ca-certificates >/dev/null 2>&1 \
	|| die "не удалось поставить базовые пакеты Entware (jq/curl/...) / failed to install base Entware packages"
# stock busybox `tr` on some builds doesn't support [:upper:]/[:lower:] classes
# and silently corrupts strings instead of erroring (e.g. "mips" -> "miws"),
# which breaks xkeen's own architecture detection during `xkeen -i`. Entware's
# coreutils-tr (now first on PATH) is required, not just nice-to-have.
# unzip is needed to unpack the downloaded Xray release. shadow-su provides
# `su`, which xkeen's own /opt/etc/init.d/S24xray uses to drop the xray
# process to an unprivileged "xkeen" user — without it xray fails to start
# with "exec: line ...: su: not found", even though everything else installed
# fine.

# ---------------------------------------------------------------------------
log "Шаг 2/6: xkeen"

if ! command -v xkeen >/dev/null 2>&1; then
	log "Ставлю xkeen (Skrill0/XKeen)..."
	# `xkeen -i` (called at the end of the upstream bootstrap script) is an
	# interactive wizard, not a flag-driven installer. Piped stdin answers
	# feed its `read` prompts in order (verified against xkeen 1.1.3):
	#   4  -> GeoIP menu:  install/update "v2fly"
	#   3  -> GeoSite menu: install/update "v2fly"
	#   1  -> cron menu: enable the missing auto-update tasks
	#   1  -> "same time for all tasks?" -> Yes
	#   8  -> day selector -> "Ежедневно" (daily)
	#   4  -> hour (0-23) -> 04:00 update time
	#   0  -> minute (0-59)
	# If a future xkeen release changes this wizard's flow, the answers will
	# land on the wrong prompts — that's exactly what the check right after
	# this block is for: it fails loudly instead of pretending success.
	# Wrapped in `timeout`: this answer sequence was verified against xkeen
	# 1.1.3, but it's still feeding a moving target with plain stdin (no real
	# pty) — if a future version inserts one more prompt we didn't expect,
	# stdin hits EOF and some xkeen releases retry a bad read in a tight loop
	# instead of erroring. Better to hard-kill after 5 minutes and fail the
	# install cleanly than let a busy-loop peg the router's CPU indefinitely.
	timeout 300 sh -c "printf '%s\n' 4 3 1 1 8 4 0 | sh -c \"\$(wget -O - '$XKEEN_INSTALL_URL')\"" \
		|| die "установка xkeen завершилась с ошибкой (или не уложилась в 5 минут) — запустите 'xkeen -i' вручную и ответьте на вопросы мастера. / xkeen install failed or exceeded its 5-minute budget — run 'xkeen -i' by hand and answer its wizard prompts."
	[ -x /opt/sbin/xray ] || die "xray не появился после установки xkeen — мастер install мог измениться, запустите 'xkeen -i' вручную и ответьте на вопросы. / xray missing after xkeen install — its interactive wizard may have changed, run 'xkeen -i' by hand and answer its prompts."

	# xkeen's own restart path writes a KeeneticOS NDM netfilter hook file
	# and expects to clean up NDM-managed iptables state -- neither applies
	# on real OpenWrt (xkeen primarily targets KeeneticOS), and the missing
	# directory alone makes it fail outright; on OpenWrt hardware tested
	# against, the iptables cleanup step *hung indefinitely* even after
	# creating the directory, wedging this install with no way back short of
	# an SSH session and a manual kill. `timeout` bounds the damage to a
	# warning instead of a stuck installer on OpenWrt; on real KeeneticOS
	# this is xkeen's actual native code path (not a workaround target), so
	# it's expected to just work -- the timeout is kept anyway as a cheap
	# safety net, not because the same hang is expected there too (not yet
	# seen on KeeneticOS in testing). Either way, SmartRoute's own restart
	# helper (lib/common.sh, wired up later below) manages the process
	# directly from here on and never goes through xkeen -restart again.
	mkdir -p /opt/etc/ndm/netfilter.d
	if ! timeout 30 xkeen -restart >/dev/null 2>&1; then
		if [ "$PLATFORM" = "openwrt" ]; then
			log "ПРЕДУПРЕЖДЕНИЕ: xkeen -restart не завершился штатно (известная проблема на чистом OpenWRT) — это ожидаемо, SmartRoute управляет Xray самостоятельно. / xkeen -restart didn't finish cleanly (known issue on plain OpenWRT) — expected, SmartRoute manages Xray itself from here on."
		else
			log "ПРЕДУПРЕЖДЕНИЕ: xkeen -restart не завершился штатно — SmartRoute всё равно управляет Xray самостоятельно дальше. / xkeen -restart didn't finish cleanly — SmartRoute manages Xray itself from here on regardless."
		fi
	fi
else
	log "xkeen уже установлен: $(xkeen -status 2>/dev/null | head -n1 || echo ok)"
fi

# These three used to live inside the "xkeen not yet installed" branch
# above too -- same bug class as 00_api.smartroute.json below: harmless the
# first time, but skipped on every subsequent run once `command -v xkeen`
# succeeds, including a run where xkeen's own binary is present but an
# *earlier* attempt died before reaching these steps (confirmed live: a
# router ended up with the crash-prone hardfloat xray-core, the
# old-format 02_transport.json untouched, and no "xkeen" account at all --
# xray refused to start at all, either on Xray-core's own config
# validation or, once that was fixed, on `su`'s "No passwd entry for user
# 'xkeen'"). All three are cheap and idempotent (opkg no-ops if already
# current; the other two both self-check first), so just always redo them.

# xkeen's own Xray-core download (from its GitHub release) crashed with
# "Illegal instruction" on real mipsel OpenWrt hardware in testing — it's a
# hardfloat build, and this Entware target (mipselsf-k3.4, "sf" = softfloat)
# has no FPU. Entware's own xray-core package is built correctly for this
# exact target and installs to the same /opt/sbin/xray path, so this just
# transparently replaces the broken binary with a working one.
#
# OpenWrt-only: on real KeeneticOS (xkeen's actual primary/native target),
# its own installer wizard already pulls Xray from Entware's opkg repo
# itself during `xkeen -i` -- confirmed live on a Hero 4G+/KN-2311: it
# installs package "xray_s" (not "xray-core"), correctly matched to this
# CPU (mipsel-3.4, softfloat, runs fine, no crash). Forcing our own
# "xray-core" package on top there doesn't just duplicate that work, it
# actively fails: opkg refuses since /opt/sbin/xray is already owned by the
# already-installed "xray_s" package (a real file-ownership conflict, not a
# harmless no-op).
if [ "$PLATFORM" = "openwrt" ]; then
	log "Проверяю, что Xray — сборка из Entware (совместимая с этим CPU)..."
	/opt/bin/opkg install xray-core >/dev/null 2>&1 || die "не удалось поставить entware xray-core / failed to install entware's xray-core"
else
	log "Xray уже поставлен мастером xkeen из Entware (xray_s), пропускаю замену. / Xray was already installed by xkeen's own wizard from Entware (xray_s), skipping the swap."
fi

# The newer Xray-core Entware ships has dropped the old top-level
# "transport" config style xkeen's 02_transport.json template uses
# ("Global transport config has been removed"). We don't need it — every
# outbound we generate carries its own streamSettings — so just neutralize
# the template instead of fighting version skew between two upstreams.
# (lib/common.sh's _sr_xray_validate re-asserts this on every restart too,
# in case xkeen's own wizard ever rewrites the template again later.)
[ -f /opt/etc/xray/configs/02_transport.json ] && echo '{}' > /opt/etc/xray/configs/02_transport.json

# S24xray runs xray as an unprivileged "xkeen" user via `su`, which needs:
# shadow-su (installed above) for `su` itself, a "xkeen" account, and a
# real shell in its passwd entry (shadow's su falls back to /bin/bash,
# which doesn't exist here — only busybox ash). Some OpenWrt builds also
# lack the busybox `adduser` applet entirely, so don't depend on it.
if ! id xkeen >/dev/null 2>&1; then
	command -v adduser >/dev/null 2>&1 && adduser -D -H -u 11111 -g 11111 xkeen 2>/dev/null
	if ! id xkeen >/dev/null 2>&1; then
		for f in /etc/passwd /etc/group /opt/etc/passwd /opt/etc/group; do
			case "$f" in
				*group) grep -q '^xkeen:' "$f" 2>/dev/null || echo 'xkeen:x:11111:' >> "$f" ;;
				*passwd) grep -q '^xkeen:' "$f" 2>/dev/null || echo 'xkeen:x:0:11111:::/bin/sh' >> "$f" ;;
			esac
		done
	fi
fi

# Both of these used to live inside the "xkeen not yet installed" branch
# above -- harmless the first time, but it meant neither ever got redone on
# a plain reinstall (xkeen already present, so that whole branch is skipped
# every time after the first). Confirmed live: 00_api.smartroute.json in
# particular going missing after a reinstall silently took the gateway
# panel's entire gRPC connection to Xray with it (no stats, no Observatory,
# no live traffic graph) while check.sh still reported it as "not generated
# yet" rather than a failure -- both are cheap, idempotent overwrites, so
# just always redo them.
#
# xkeen's default 04_outbounds.json ships a placeholder "vless-reality"
# outbound with empty address/id/publicKey fields, meant to be hand-edited.
# Left as-is, Xray refuses to start at all (even once a real subscription
# is imported into our own 04_outbounds.smartroute.json) because this
# invalid stub is loaded from the same confdir. Replace it with just the
# harmless "direct" outbound; real servers come from SmartRoute.
echo '{"outbounds":[{"protocol":"freedom","tag":"direct"}]}' > /opt/etc/xray/configs/04_outbounds.json

# Xray's own gRPC API (stats/handler/routing), loopback-only -- SmartRoute's
# panel reads live traffic/connection data through it. Off by default;
# this is what turns it on.
cat > /opt/etc/xray/configs/00_api.smartroute.json <<'XRAY_API_EOF'
{
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService", "ObservatoryService"]
  },
  "policy": {
    "levels": {
      "0": {
        "connIdle": 30,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ]
}
XRAY_API_EOF
# No "routing" block above on purpose, even though the inbound needs one
# (inboundTag:["api"] -> outboundTag:"api") to actually be reachable --
# confirmed live via `xray run -test -confdir ... -dump`: once ANY other
# confdir file also defines a top-level "routing" key, this file's own
# "routing" block loses the merge with no error logged anywhere, and Xray
# quietly runs with no route to its own API service (gateway panel's gRPC
# calls fail with "error reading server preface: EOF" -- health/Observatory/
# traffic data goes stale, everything else keeps working). genroute.sh emits
# this exact rule itself now, in 05_routing.smartroute.json, the one file
# that's actually guaranteed to win that merge -- see its own comment next
# to the redirect/tproxy catch-all it already had to do the same thing for.

# Xray's own log directory lives on tmpfs (/tmp/xray-logs, see 01_log.json
# below) so the on-demand logging toggle never wears the flash -- but tmpfs
# is wiped every reboot, and xkeen's own S24xray boot script execs xray
# directly (not through lib/common.sh), so this project's own restart
# helpers aren't in the loop at boot time. A tiny init.d script numbered to
# run just before S24xray is the one choke point that's actually guaranteed
# to fire before Xray does, every boot, regardless of which of the several
# things that can start Xray (boot, cron restart, a manual restart from any
# UI) ends up doing it this time.
mkdir -p /tmp/xray-logs /opt/etc/init.d
cat > /opt/etc/init.d/S23xray-logdir <<'XRAY_LOGDIR_EOF'
#!/bin/sh
# Ensures Xray's tmpfs log directory exists before S24xray starts it.
mkdir -p /tmp/xray-logs
XRAY_LOGDIR_EOF
chmod +x /opt/etc/init.d/S23xray-logdir

# xkeen ships 01_log.json/03_inbounds.json/05_routing.json with `//` comments
# (and, on some mirrors, non-UTF8 Cyrillic in those comments). Functionally
# harmless to Xray itself, but xkeen-UI's GUI Mode (visual routing/log editor,
# see its own Settings page) parses these files as strict JSON to render
# them -- a file with comments fails that parse and the UI just shows nothing,
# which looks like the config doesn't exist at all. Overwritten unconditionally
# on every run (not just fresh installs) so an existing install picks this up
# too; functionally identical to xkeen's own templates, just comment-free.
#
# loglevel "none" is not a severity filter -- Xray's own log app sets BOTH
# AccessLogType and ErrorLogType to "none" for this value, so nothing is
# *ever* written, not even a suppressed/rotated-away line. This is the
# deliberate default (access logging every request has a real cost, both in
# flash wear were it pointed at /opt and in RAM if left on indefinitely on
# tmpfs) -- SmartRoute UI/LuCI's own log toggle
# (sr_set_log_enabled/sr_apply_log_config in lib/common.sh) flips loglevel
# and restarts xray on demand. The path already points at tmpfs so toggling
# logging on never needs to touch this file's path, only its loglevel --
# keep this literal block in sync with sr_apply_log_config's "off" output.
cat > /opt/etc/xray/configs/01_log.json <<'XRAY_LOG_EOF'
{
  "log": {
    "access": "/tmp/xray-logs/access.log",
    "error": "/tmp/xray-logs/error.log",
    "loglevel": "none",
    "dnsLog": false
  }
}
XRAY_LOG_EOF

cat > /opt/etc/xray/configs/03_inbounds.json <<'XRAY_INBOUNDS_EOF'
{
  "inbounds": [
    {
      "tag": "redirect",
      "port": 61219,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ]
}
XRAY_INBOUNDS_EOF

# Same content as xkeen's own template, minus comments, MINUS the ".ru/.su/...
# domains always go direct" rule xkeen ships by default.
#
# That rule used to be kept on the (wrong) assumption that Xray's confdir
# merge always evaluates lib/genroute.sh's own 05_routing.smartroute.json
# rules first, making this file's rules dead/unreachable regardless of their
# content. Real on-router testing proved the opposite: a profile that
# explicitly included 2ip.ru (a .ru domain) still leaked the real IP with
# leak-protection fully enabled, because THIS file's domain-specific ".ru ->
# direct" rule was actually winning over the user's own SmartRoute rule for
# that same domain. Xray's actual confdir load order interleaves same-prefix
# files by full filename, and "05_routing.json" sorts before
# "05_routing.smartroute.json" -- so this rule was live and taking priority
# the entire time. See AGENTS.md ("05_routing.json .ru precedence leak") for
# the full writeup if this resurfaces.
#
# The plain, domain-unrestricted catch-all rule below is left in (still
# pointed at "direct", not xkeen's broken placeholder "vless-reality" tag) --
# it's harmless regardless of load order since it's the exact same fallback
# lib/genroute.sh's own catch-all already provides, just redundant.
cat > /opt/etc/xray/configs/05_routing.json <<'XRAY_ROUTING_EOF'
{
  "routing": {
    "rules": [
      {
        "inboundTag": ["redirect", "tproxy"],
        "outboundTag": "direct",
        "type": "field"
      }
    ]
  }
}
XRAY_ROUTING_EOF

# Same precedence bug as the .ru routing rule above, different file: xkeen's
# own 06_policy.json ships with just {"policy":{"levels":{"0":{"connIdle":
# 30}}}} -- no stats flags at all -- and Xray's confdir merge does not deep-
# merge two files that both declare a top-level "policy" key, so whichever
# one the merge picks wins *entirely*, silently discarding the other's
# content. 06_policy.json sorts after 00_api.smartroute.json (SmartRoute's
# own policy block, with statsOutboundUplink/Downlink -- see the "api" step
# below), so its bare connIdle-only policy was winning and Xray's outbound
# traffic counters stayed permanently empty ("{}" from a live statsquery no
# matter how much traffic actually flowed) -- the LuCI Profiles page's
# "online now" dot depends on exactly these counters. Confirmed live: moving
# 06_policy.json aside and restarting Xray made per-outbound counters appear
# immediately. Fixed the same way as the routing rule -- keep the file (some
# tooling may expect the standard xkeen file layout to exist), just make its
# content match 00_api.smartroute.json's policy block instead of a stripped-
# down subset, so it no longer matters which file confdir actually picks.
cat > /opt/etc/xray/configs/06_policy.json <<'XRAY_POLICY_EOF'
{
  "policy": {
    "levels": {
      "0": {
        "connIdle": 30,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "stats": {}
}
XRAY_POLICY_EOF
# "stats": {} above is not decorative -- without a top-level "stats" block
# (separate from "policy", which only configures *what* gets counted once
# the stats app is actually running), Xray never enables its app/stats
# feature at all, and QueryStats fails with "QueryStats only works its own
# stats.Manager" on every call -- confirmed live, and a known upstream
# report (XTLS/Xray-core#2296, and the same fix independently confirmed in
# XTLS/Xray-core#4509's own discussion). GetSysStats/lsrules/lso all worked
# fine throughout, which is what made this one non-obvious -- only the
# per-outbound/per-user QueryStats path needs the real stats.Manager this
# unlocks. That's the gateway panel's traffic graph and the "online now"
# dot's data source (see gateway/xray.go's queryOutboundTrafficByTag).

# ---------------------------------------------------------------------------
log "Шаг 3/6: xkeen-UI (веб-панель, порт 1000)"

if [ ! -x /opt/sbin/xkeen-ui ] && [ ! -x /opt/bin/xkeen-ui ]; then
	log "Ставлю xkeen-UI ($XKEEN_UI_REPO)..."
	wget -O /tmp/xkeen-ui-setup.sh "https://raw.githubusercontent.com/${XKEEN_UI_REPO}/main/setup.sh" \
		&& sh /tmp/xkeen-ui-setup.sh \
		|| log "ПРЕДУПРЕЖДЕНИЕ: автоустановка xkeen-UI не удалась, поставьте вручную по https://github.com/${XKEEN_UI_REPO} — остальной стек всё равно будет настроен."
	rm -f /tmp/xkeen-ui-setup.sh
else
	log "xkeen-UI уже установлен, пропускаю."
fi

# xkeen-UI ships with its own web login *disabled* by default -- anyone on
# the LAN can open port 1000 and manage Xray with no password at all. Ask
# once for the same password already protecting this router (SSH/LuCI) and
# apply it to xkeen-UI's own auth too, so there's one password protecting
# everything, not just the parts we happened to remember to lock. Password
# first, *then* auth.enabled -- the other order leaves a real (if short)
# window where auth is required but no password exists yet, locking
# xkeen-UI's own API out from under itself (hit this for real while testing).
if command -v curl >/dev/null 2>&1 && curl -s -m 3 http://127.0.0.1:1000/api/version >/dev/null 2>&1; then
	# Checked straight off disk, not via /api/settings: once auth is on,
	# that endpoint requires a session itself, so an unauthenticated probe
	# can no longer tell "already configured" apart from "server down".
	# install.sh runs directly on the router, so the file is just... there.
	xkeenui_cfg="/opt/etc/xkeen/xkeen-ui.json"
	# Not `[ -s "$f" ] && jq ...` inside the substitution: under `set -eu`,
	# a plain top-level `var="$(cmd)"` inherits cmd's exit status same as
	# any other simple command -- when `[ -s "$xkeenui_cfg" ]` is false
	# (the normal case on a fresh install, before xkeen-UI has ever had a
	# password set), the whole `&&` list's exit status is 1 and this
	# assignment silently killed the entire script right here, with xkeen,
	# xkeen-UI, dnsmasq-full etc. all already installed but XKeen
	# SmartRoute itself, the gateway, and cron never even attempted.
	# Confirmed live with `sh -x`: the trace just stops dead at this exact
	# line, no error, no further output. Same class of bug as the
	# `_sr_xray_launch` fix in lib/common.sh, found completely
	# independently in much older code.
	already_has_pw=""
	if [ -s "$xkeenui_cfg" ]; then
		already_has_pw="$(jq -r '.auth.password_hash // empty' "$xkeenui_cfg" 2>/dev/null || true)"
	fi
	if [ -n "$already_has_pw" ]; then
		log "У xkeen-UI уже задан пароль, пропускаю."
	elif [ -r /dev/tty ]; then
		log "Задайте пароль для веб-панели xkeen-UI (порт 1000) -- рекомендуется тот же, что и для входа на роутер."
		printf "Пароль: "
		# `|| true`/`|| xkeenui_pw=""` on all three -- this busybox doesn't
		# ship an `stty` applet at all on some builds (confirmed live: "ash:
		# stty: not found"), and these calls, bare, killed the entire install
		# under `set -eu` right after printing the prompt. Echo suppression
		# is a nicety (don't show the password on screen while typing), not
		# something worth aborting the whole install over if unavailable.
		# `read` itself needs the same guard for a different reason: `[ -r
		# /dev/tty ]` above only checks this special file's permission bits,
		# not whether the process actually has a controlling terminal to
		# open it against -- confirmed live running install.sh non-
		# interactively (no ctty at all, e.g. a backgrounded/detached shell):
		# `[ -r /dev/tty ]` still reads true, but the `read ... < /dev/tty`
		# redirection itself then fails to open the device ("No such device
		# or address"), and under `set -eu` an unguarded redirection failure
		# on a simple command aborts the whole script right there -- Step
		# 6/6 (cron) and the final summary were silently never reached.
		# Falling back to an empty password here instead makes that case
		# behave exactly like "prompted, user hit enter with nothing typed"
		# (skip, log a reminder) rather than a hard, unexplained stop.
		stty -echo < /dev/tty 2>/dev/null || true
		read -r xkeenui_pw < /dev/tty 2>/dev/null || xkeenui_pw=""
		stty echo < /dev/tty 2>/dev/null || true
		printf "\n"
		if [ -n "$xkeenui_pw" ]; then
			setup_resp="$(curl -s -m 5 -X POST http://127.0.0.1:1000/api/auth/setup -H 'Content-Type: application/json' \
				--data-binary "$(jq -n --arg pw "$xkeenui_pw" '{password:$pw}')" 2>/dev/null)"
			case "$setup_resp" in
				*'"success":true'*)
					curl -s -m 5 -X PATCH http://127.0.0.1:1000/api/settings -H 'Content-Type: application/json' \
						-d '{"auth":{"enabled":true}}' >/dev/null 2>&1
					log "Пароль для xkeen-UI установлен."
					;;
				*)
					log "ПРЕДУПРЕЖДЕНИЕ: не удалось установить пароль xkeen-UI ($setup_resp) -- панель осталась без пароля, задайте его вручную в Настройках."
					;;
			esac
		else
			log "Пароль не введён, xkeen-UI останется без авторизации -- задайте её вручную в Настройках при желании."
		fi
		unset xkeenui_pw
	else
		log "ПРЕДУПРЕЖДЕНИЕ: нет интерактивного терминала (запуск через curl|sh без tty?), пропускаю установку пароля xkeen-UI -- задайте его вручную в Настройках."
	fi
fi

# ---------------------------------------------------------------------------
log "Шаг 4/6: XKeen SmartRoute (наш LuCI-модуль + генераторы конфигов)"

mkdir -p "$SR_ETC_DIR/lists" "$SR_ETC_DIR/lists/custom" "$SR_ETC_DIR/profiles" "$SR_ETC_DIR/state" "$SR_LIB_DIR"

for f in common.sh subscription.sh genroute.sh killswitch.sh redirect.sh; do
	wget -O "$SR_LIB_DIR/$f" "$REPO_RAW/lib/$f" || die "не удалось скачать lib/$f"
	chmod +x "$SR_LIB_DIR/$f"
done

# luci.xkeen-smartroute is a self-contained CLI (`list` / `call <method>`),
# not actually rpcd/ubus-specific despite its home under
# luci-app-xkeen-smartroute/ -- it's the one script that implements the
# entire subscriptions/profiles/kill-switch/leak-protection surface, and the
# gateway panel (Шаг 5/6 below) execs it directly for all of that, on BOTH
# platforms, via SR_GATEWAY_RPCD_SCRIPT. Fetched here to a
# platform-independent path so the gateway panel has this functionality even
# on KeeneticOS, where the OpenWrt-only rpcd/ubus copy below never happens.
wget -O "$SR_LIB_DIR/luci.xkeen-smartroute" "$REPO_RAW/luci-app-xkeen-smartroute/root/usr/libexec/rpcd/luci.xkeen-smartroute" \
	|| die "не удалось скачать luci.xkeen-smartroute"
chmod +x "$SR_LIB_DIR/luci.xkeen-smartroute"

wget -O "$SR_ETC_DIR/lists/geosite-categories.json" "$REPO_RAW/lists/geosite-categories.json" || true
wget -O "$SR_ETC_DIR/lists/custom-categories.json" "$REPO_RAW/lists/custom-categories.json" || true
mkdir -p "$SR_ETC_DIR/lists/custom"
for svc in character-ai grok npm; do
	wget -O "$SR_ETC_DIR/lists/custom/${svc}.lst" "$REPO_RAW/lists/custom/${svc}.lst" 2>/dev/null || true
done

if [ "$PLATFORM" = "openwrt" ]; then
	mkdir -p /usr/share/rpcd/acl.d /usr/libexec/rpcd /www/luci-static/resources/view/xkeen-smartroute /usr/share/luci/menu.d
	for f in root/usr/share/rpcd/acl.d/luci-app-xkeen-smartroute.json \
	         root/usr/libexec/rpcd/luci.xkeen-smartroute \
	         root/usr/share/luci/menu.d/luci-app-xkeen-smartroute.json \
	         root/www/luci-static/resources/xkeen-smartroute.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/subscriptions.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/profiles.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/doublevpn.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/status.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/killswitch.js \
	         root/www/luci-static/resources/view/xkeen-smartroute/protection.js ; do
		dest="/${f#root/}"
		mkdir -p "$(dirname "$dest")"
		wget -O "$dest" "$REPO_RAW/luci-app-xkeen-smartroute/$f" || die "не удалось скачать $f"
	done
	chmod +x /usr/libexec/rpcd/luci.xkeen-smartroute
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
	[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
else
	# No LuCI on KeeneticOS at all -- the gateway panel (Шаг 5/6, port
	# $SR_GATEWAY_PORT) and xkeen-UI (port 1000) are the only UI here.
	log "LuCI на KeeneticOS нет, пропускаю установку LuCI-модуля -- используйте панель (порт $SR_GATEWAY_PORT) или xkeen-UI (порт 1000). / No LuCI on KeeneticOS, skipping the LuCI module -- use the gateway panel (port $SR_GATEWAY_PORT) or xkeen-UI (port 1000) instead."
fi

# On a reinstall over `uninstall.sh` (without --purge) or any re-run of this
# script, $SR_ETC_DIR/state's flags/profiles/state/outbounds.json survive on
# disk, but the actual enforcement they describe (the nftables redirect
# chain, kill-switch's dnsmasq/firewall UCI sections,
# 04_outbounds.smartroute.json, routing) does NOT survive -- those live
# outside $SR_ETC_DIR and only ever get (re)built by an explicit
# enable/regen call. Confirmed live: after a plain reinstall, check.sh still
# showed everything "[OK]" except the lines that actually matter, while
# traffic silently stopped being captured/routed at all -- outbounds/routing
# still pointed at server tags Xray had no outbound for. Redo those calls
# now so a reinstall really is idempotent, not just file-copy-idempotent.
if [ -s "$SR_ETC_DIR/state/outbounds.json" ]; then
	jq '{outbounds: [.[] | del(.subscription)]}' "$SR_ETC_DIR/state/outbounds.json" \
		>/opt/etc/xray/configs/04_outbounds.smartroute.json.tmp \
		&& mv /opt/etc/xray/configs/04_outbounds.smartroute.json.tmp /opt/etc/xray/configs/04_outbounds.smartroute.json
fi
# redirect.sh/killswitch.sh are built on OpenWrt's uci/fw4/nftables firewall
# integration -- no KeeneticOS (NDM netfilter) port exists yet, so there's
# nothing meaningful to restore here on that platform (and no way for these
# state files to be non-empty from a prior run there anyway, since nothing
# below ever enables them on KeeneticOS in the first place).
if [ "$PLATFORM" = "openwrt" ]; then
	if [ "$(cat "$SR_ETC_DIR/state/redirect_enabled" 2>/dev/null)" = "1" ]; then
		sh "$SR_LIB_DIR/redirect.sh" enable >/dev/null 2>&1 || true
	fi
	for f in "$SR_ETC_DIR/state/killswitch"/*.name; do
		[ -e "$f" ] || continue
		sh "$SR_LIB_DIR/killswitch.sh" enable "$(cat "$f")" >/dev/null 2>&1 || true
	done
else
	log "ПРЕДУПРЕЖДЕНИЕ: kill-switch и прозрачный редирект трафика пока поддержаны только на OpenWrt -- на KeeneticOS в разработке. / WARNING: kill-switch and transparent redirect are OpenWrt-only for now -- not yet available on KeeneticOS."
fi
# The CLI `regen` verb always does a real, network-bound ping pass per
# balancer-mode profile (see sr_regen's own comment) -- fine for cron every
# 3 minutes, but blocking the rest of this installer on it would add minutes
# to every run on a subscription with several such profiles. Fire it in the
# background instead of waiting on it here; the crontab entry just installed
# below picks it up again in 3 minutes either way if this particular run
# hasn't finished by then.
sh "$SR_LIB_DIR/genroute.sh" regen >/dev/null 2>&1 &

# ---------------------------------------------------------------------------
log "Шаг 5/6: smartroute-gateway (живая панель в духе Mihomo, порт $SR_GATEWAY_PORT)"

if [ "$PLATFORM" = "openwrt" ]; then
	case "$DISTRIB_ARCH" in
		mipsel_24kc|mipsel_24kec) GATEWAY_ASSET="smartroute-gateway-mipsle-softfloat" ;;
		mips_24kc)                GATEWAY_ASSET="smartroute-gateway-mips-softfloat" ;;
		aarch64*)                 GATEWAY_ASSET="smartroute-gateway-arm64" ;;
		arm_cortex-a*)             GATEWAY_ASSET="smartroute-gateway-arm7" ;;
		x86_64)                   GATEWAY_ASSET="smartroute-gateway-amd64" ;;
		*) GATEWAY_ASSET="" ;;
	esac
else
	# $DISTRIB_ARCH here is Entware's own "arch=" token (e.g. "mipsel"), not
	# OpenWrt's DISTRIB_ARCH ("mipsel_24kc") -- match against Entware's own
	# fields (arch + float, both read from /opt/etc/entware_release above)
	# instead. Confirmed live on a Hero 4G+/KN-2311: arch=mipsel, float=soft.
	ENTWARE_FLOAT="$(grep '^float=' /opt/etc/entware_release 2>/dev/null | cut -d= -f2)"
	case "$DISTRIB_ARCH:$ENTWARE_FLOAT" in
		mipsel:soft)         GATEWAY_ASSET="smartroute-gateway-mipsle-softfloat" ;;
		mips:soft)           GATEWAY_ASSET="smartroute-gateway-mips-softfloat" ;;
		aarch64:*)           GATEWAY_ASSET="smartroute-gateway-arm64" ;;
		arm:*)               GATEWAY_ASSET="smartroute-gateway-arm7" ;;
		x86-64:*|x86_64:*)   GATEWAY_ASSET="smartroute-gateway-amd64" ;;
		*) GATEWAY_ASSET="" ;;
	esac
fi

if [ -z "$GATEWAY_ASSET" ]; then
	log "ПРЕДУПРЕЖДЕНИЕ: архитектура $DISTRIB_ARCH не собирается в CI для smartroute-gateway, пропускаю панель (остальной стек всё равно работает)."
else
	mkdir -p "$SR_SHARE_DIR/panel"
	wget -O /tmp/smartroute-gateway.gz "$GATEWAY_RELEASE_BASE/${GATEWAY_ASSET}.gz" \
		&& gunzip -f /tmp/smartroute-gateway.gz \
		&& mv /tmp/smartroute-gateway "$SR_SHARE_DIR/gateway" \
		&& chmod +x "$SR_SHARE_DIR/gateway" \
		|| log "ПРЕДУПРЕЖДЕНИЕ: не удалось скачать smartroute-gateway, пропускаю панель (остальной стек всё равно работает)."
	rm -f /tmp/smartroute-gateway.gz

	if [ -x "$SR_SHARE_DIR/gateway" ]; then
		for f in index.html style.css app.js status.js subscriptions.js profiles.js doublevpn.js domains.js killswitch.js protection.js logo.png logo_without_background.png; do
			wget -O "$SR_SHARE_DIR/panel/$f" "$REPO_RAW/gateway/static/$f" \
				|| die "не удалось скачать панель gateway/static/$f"
		done

		cat > /opt/etc/init.d/S98smartroute-gateway <<GATEWAY_INIT_EOF
#!/bin/sh
# XKeen SmartRoute gateway -- live dashboard backed by Xray's own gRPC API
# and SmartRoute's state (servers/profiles). Managed directly (not via
# procd/systemd, neither of which Entware provides) the same way
# lib/common.sh's sr_restart_xray manages xray itself: kill by pgrep+kill,
# relaunch with SIGHUP ignored so it survives the launching shell exiting --
# this busybox has neither nohup nor setsid.
BIN="$SR_SHARE_DIR/gateway"
LOG="$SR_ETC_DIR/state/gateway.log"
export SR_GATEWAY_LISTEN="0.0.0.0:$SR_GATEWAY_PORT"
export SR_GATEWAY_XRAY_API="127.0.0.1:10085"
export SR_GATEWAY_STATIC_DIR="$SR_SHARE_DIR/panel"
# Explicit on both platforms rather than relying on the binary's own default
# (which points at the OpenWrt/rpcd-only path) -- see the download of this
# same file into \$SR_LIB_DIR above (Шаг 4/6) for why.
export SR_GATEWAY_RPCD_SCRIPT="$SR_LIB_DIR/luci.xkeen-smartroute"
export SR_ETC_DIR="$SR_ETC_DIR"

start() {
	[ -x "\$BIN" ] || exit 0
	mkdir -p "\$(dirname "\$LOG")"
	(trap '' HUP; exec "\$BIN" >"\$LOG" 2>&1 </dev/null) &
}

stop() {
	for pid in \$(pgrep -f "\$BIN" 2>/dev/null); do kill "\$pid" 2>/dev/null; done
}

case "\${1:-start}" in
	start) start ;;
	stop) stop ;;
	restart) stop; sleep 1; start ;;
	*) echo "usage: \$0 {start|stop|restart}" >&2; exit 1 ;;
esac
GATEWAY_INIT_EOF
		chmod +x /opt/etc/init.d/S98smartroute-gateway
		for pid in $(pgrep -f "$SR_SHARE_DIR/gateway" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
		sleep 1
		/opt/etc/init.d/S98smartroute-gateway start
		log "Панель: http://$LAN_IP:$SR_GATEWAY_PORT/"

		# The gateway panel now does more than show live traffic -- it can edit
		# subscriptions/profiles/kill-switch too, the same as LuCI -- so it
		# gets the same one-time password prompt xkeen-UI already has above,
		# hitting its own /api/change-password instead. Skipped (not forced)
		# if a password is already set, same reasoning as xkeen-UI's block:
		# re-running install.sh must never silently reset a password someone
		# already chose.
		gw_pw_file="$SR_ETC_DIR/state/gateway_password_hash"
		if [ -s "$gw_pw_file" ]; then
			log "У панели SmartRoute уже задан пароль, пропускаю."
		elif [ -r /dev/tty ] && command -v curl >/dev/null 2>&1; then
			sleep 1
			log "Задайте пароль для панели SmartRoute (порт $SR_GATEWAY_PORT) -- рекомендуется тот же, что и для входа на роутер. Пусто = без пароля (панель останется открытой всем в сети)."
			printf "Пароль: "
			# See the identical xkeen-UI password prompt above for both
			# guards: `|| true` on stty (no `stty` applet on some builds),
			# `|| gw_pw=""` on read (confirmed live: `[ -r /dev/tty ]` above
			# can read true with no real controlling terminal at all --
			# e.g. install.sh run non-interactively/backgrounded -- and the
			# bare `read ... < /dev/tty` then fails to open the device,
			# which under `set -eu` aborted the whole script right here,
			# before Step 6/6 and the final summary).
			stty -echo < /dev/tty 2>/dev/null || true
			read -r gw_pw < /dev/tty 2>/dev/null || gw_pw=""
			stty echo < /dev/tty 2>/dev/null || true
			printf "\n"
			if [ -n "$gw_pw" ]; then
				gw_resp="$(curl -s -m 5 -X POST "http://127.0.0.1:$SR_GATEWAY_PORT/api/change-password" -H 'Content-Type: application/json' \
					--data-binary "$(jq -n --arg pw "$gw_pw" '{current:"",new:$pw}')" 2>/dev/null)"
				case "$gw_resp" in
					*'"ok":true'*) log "Пароль для панели SmartRoute установлен." ;;
					*) log "ПРЕДУПРЕЖДЕНИЕ: не удалось установить пароль панели SmartRoute ($gw_resp) -- панель осталась без пароля, задайте его вручную на вкладке Статус." ;;
				esac
			else
				log "Пароль не введён, панель SmartRoute останется без авторизации -- задайте её вручную на вкладке Статус при желании."
			fi
			unset gw_pw
		else
			log "ПРЕДУПРЕЖДЕНИЕ: нет интерактивного терминала, пропускаю установку пароля панели SmartRoute -- задайте его вручную на вкладке Статус."
		fi
	fi
fi

# xkeen's own geo-data updater (xkeen -ug, wired into cron just below) fetches
# real geosite/geoip databases into /opt/etc/xray/dat, but names them by
# source (e.g. geosite_v2fly.dat, geoip_v2fly.dat) rather than the plain
# "geosite.dat"/"geoip.dat" Xray's own default asset lookup expects for a
# bare "geosite:category" domain rule. Without this, every routing rule that
# uses geosite: (every profile the LuCI UI creates) silently fails to parse
# at Xray startup -- no crash, no error in the usual logs, Xray just ends up
# with zero working routing rules and falls back to its documented "no rule
# matched -> use the first outbound" behavior for literally all traffic.
# Confirmed for real on this project's own test router. Idempotent: only
# creates the symlink if a same-named real file isn't already sitting there
# (some setups may already have a plainly-named geosite.dat from elsewhere).
for pair in "geosite_v2fly.dat:geosite.dat" "geoip_v2fly.dat:geoip.dat"; do
	src="${pair%%:*}"; dst="${pair##*:}"
	if [ -f "/opt/etc/xray/dat/$src" ] && [ ! -e "/opt/etc/xray/dat/$dst" ]; then
		ln -sf "/opt/etc/xray/dat/$src" "/opt/etc/xray/dat/$dst"
	fi
done

# ---------------------------------------------------------------------------
log "Шаг 6/6: cron (обновление geosite/geoip раз в 8 часов, подписок — по расписанию, ночной рестарт Xray)"

CRON_GEO="0 */8 * * * xkeen -ug >/dev/null 2>&1; xkeen -uk >/dev/null 2>&1 #xkeen-smartroute-cron"
# Fires hourly, but subscription.sh refresh itself checks a timestamp against
# the configured interval (default 12h, changeable in the UI without editing
# crontab) and exits immediately if it isn't due yet -- simpler and more
# flexible than rewriting a cron schedule string for an arbitrary N-hour gap.
CRON_SUB="7 * * * * sh $SR_LIB_DIR/subscription.sh refresh >/dev/null 2>&1 #xkeen-smartroute-cron"
# Xray's own RSS grows with uptime (observed on real hardware: ~37MB right
# after a restart, ~120MB+ after some hours running with observatory
# continuously probing ~10 outbounds every 30s) -- on a router with ~250MB
# total RAM and no swap, that's enough to risk the kernel OOM-killer taking
# it out at the worst possible moment. A once-a-day restart at a quiet hour
# bounds the growth cheaply; sr_restart_xray already validates the merged
# config first and only swaps the process if that passes, so this can't turn
# a working router into a broken one the way a blind `kill` + relaunch could.
CRON_RESTART="15 5 * * * sh -c '. $SR_LIB_DIR/common.sh; sr_restart_xray' >/dev/null 2>&1 #xkeen-smartroute-cron"
# balancer-mode profiles pick their single fastest, not-currently-dead
# server themselves now (see genroute.sh's sr_pick_top1 -- Xray's own
# balancerTag is unusable, see AGENTS.md) from smartroute-gateway's
# health.json (real observatory verdicts, refreshed continuously in the
# background every 20s by failover.go regardless of this cron) plus
# ping.json as a fallback signal. genroute.sh regen just re-reads those
# already-fresh files and rewrites routing rules -- no network calls of its
# own -- so it's cheap enough to run every 3 minutes without the "a full
# sequential ping sweep takes real time" concern that applied when regen
# itself needed to trigger a fresh ping pass first.
CRON_REGEN="*/3 * * * * sh $SR_LIB_DIR/genroute.sh regen >/dev/null 2>&1 #xkeen-smartroute-cron"
# ping.json (sr_pick_top1's fallback ranking for a server health.json
# hasn't reached yet, and the Subscriptions page's displayed numbers) still
# needs its own refresh -- just far less urgently than regen now that
# picking a *working* server doesn't depend on it. Every 2 hours, sequential
# (see the sequential-vs-concurrent-probing note in genroute.sh for why not
# more often/parallel on this hardware).
CRON_PING="0 */2 * * * sh $SR_LIB_DIR/subscription.sh ping >/dev/null 2>&1 #xkeen-smartroute-cron"
# `grep -v` exits 1 (no lines selected) whenever root has no crontab yet --
# every first-ever install, and every reinstall after uninstall.sh, which
# clears out the xkeen-smartroute-cron entries entirely. Under `set -e`,
# that non-zero status used to abort this whole subshell right after the
# `crontab -l | grep -v` pipe and before any of the `echo`s below ran --
# confirmed live: `crontab -` then received empty stdin and silently wrote
# an empty crontab, taking subscription refresh, domain-list refresh, the
# nightly Xray restart, and (worst of it) genroute.sh's regen loop with it,
# the last of which is what actually (re)writes 04_outbounds.smartroute.json
# and 00_api.smartroute.json from already-imported subscription data -- so
# a router in this state looked installed (check.sh: everything else [OK])
# but silently had zero working outbound routing until someone noticed.
( crontab -l 2>/dev/null | grep -v 'xkeen-smartroute-cron' || true ; echo "$CRON_GEO" ; echo "$CRON_SUB" ; echo "$CRON_RESTART" ; echo "$CRON_REGEN" ; echo "$CRON_PING" ) | crontab -
/etc/init.d/cron restart >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# $LAN_IP was already computed once, right after platform detection.
log ""
log "Готово! / Done!"
if [ "$PLATFORM" = "openwrt" ]; then
	log "  LuCI:      http://$LAN_IP/  ->  Services / Сервисы -> XKeen SmartRoute"
fi
log "  xkeen-UI:  http://$LAN_IP:1000/"
log "  Панель:    http://$LAN_IP:$SR_GATEWAY_PORT/"
log "  Списки:    $SR_ETC_DIR/lists/"
if [ "$PLATFORM" = "keenetic" ]; then
	log "  ПРИМЕЧАНИЕ: LuCI на KeeneticOS нет -- панель и xkeen-UI выше единственный UI. Kill-switch и прозрачный редирект трафика пока не поддержаны на KeeneticOS (в разработке)."
fi
log "Диагностика: sh $SR_LIB_DIR/../check.sh (или ./check.sh из репозитория)"
