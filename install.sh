#!/bin/sh
# XKeen SmartRoute — one-shot installer for OpenWrt.
#
#   sh <(wget -O - https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main/install.sh)
#
# What it does, in order:
#   1. Sanity-checks this is OpenWrt, checks free space on /overlay.
#   2. Installs Entware (if not already present) — xkeen and its tooling live under /opt.
#   3. Installs xkeen (Xray-core manager) + xkeen-UI (existing web panel, port 1000).
#   4. Copies our LuCI app (luci-app-xkeen-smartroute) + lib/ scripts + domain-list catalog.
#   5. Installs smartroute-gateway (Mihomo-style live dashboard, port 1001).
#   6. Sets up a cron job to refresh geosite/geoip data periodically.
#
# Safe to re-run (idempotent): existing installs are detected and skipped/updated.

set -eu

REPO_RAW="https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main"
GATEWAY_RELEASE_BASE="https://github.com/LackyCraft/xkeen-smartroute/releases/download/gateway-latest"
XKEEN_INSTALL_URL="https://raw.githubusercontent.com/Skrill0/XKeen/main/install.sh"
XKEEN_UI_REPO="zxc-rv/XKeen-UI"
SR_ETC_DIR="/etc/xkeen-smartroute"
SR_SHARE_DIR="/opt/share/xkeen-smartroute"
SR_LIB_DIR="$SR_SHARE_DIR/lib"
SR_GATEWAY_PORT=1001
MIN_FREE_KB=25000

log()  { echo "[xkeen-smartroute] $*"; }
die()  { echo "[xkeen-smartroute] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Проверка окружения / Checking environment..."

[ -f /etc/openwrt_release ] || die "Это не OpenWrt (не найден /etc/openwrt_release). / This does not look like OpenWrt."
. /etc/openwrt_release
log "OpenWrt $DISTRIB_RELEASE, target=$DISTRIB_TARGET, arch=$DISTRIB_ARCH"

FREE_KB="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
	die "Слишком мало места на /overlay (${FREE_KB}KB < ${MIN_FREE_KB}KB нужно). Подключите USB-накопитель с extroot и повторите. / Not enough space on /overlay."
fi
log "Свободно на /overlay: ${FREE_KB:-unknown} KB"

command -v opkg >/dev/null 2>&1 || die "opkg not found"

# ---------------------------------------------------------------------------
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
# was already there correctly.
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

export PATH="/opt/bin:/opt/sbin:$PATH"
/opt/bin/opkg update >/dev/null 2>&1 || true
/opt/bin/opkg install jq curl bash coreutils-base64 coreutils-tr coreutils-timeout unzip shadow-su grep sed >/dev/null 2>&1 \
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

	# xkeen's own Xray-core download (from its GitHub release) crashed with
	# "Illegal instruction" on real mipsel hardware in testing — it's a
	# hardfloat build, and this Entware target (mipselsf-k3.4, "sf" = softfloat)
	# has no FPU. Entware's own xray-core package is built correctly for this
	# exact target and installs to the same /opt/sbin/xray path, so this just
	# transparently replaces the broken binary with a working one.
	log "Заменяю Xray на сборку из Entware (совместимую с этим CPU)..."
	/opt/bin/opkg install xray-core >/dev/null 2>&1 || die "не удалось поставить entware xray-core / failed to install entware's xray-core"

	# The newer Xray-core Entware ships has dropped the old top-level
	# "transport" config style xkeen's 02_transport.json template uses
	# ("Global transport config has been removed"). We don't need it — every
	# outbound we generate carries its own streamSettings — so just neutralize
	# the template instead of fighting version skew between two upstreams.
	[ -f /opt/etc/xray/configs/02_transport.json ] && echo '{}' > /opt/etc/xray/configs/02_transport.json

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
    "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"]
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
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      }
    ]
  }
}
XRAY_API_EOF

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

	# xkeen's own restart path writes a KeeneticOS NDM netfilter hook file
	# and expects to clean up NDM-managed iptables state -- neither applies
	# on real OpenWrt (xkeen primarily targets KeeneticOS), and the missing
	# directory alone makes it fail outright; on hardware tested against,
	# the iptables cleanup step *hung indefinitely* even after creating the
	# directory, wedging this install with no way back short of an SSH
	# session and a manual kill. `timeout` bounds the damage to a warning
	# instead of a stuck installer; SmartRoute's own restart helper
	# (lib/common.sh, wired up later below) manages the process directly
	# for everything from here on and never goes through xkeen -restart.
	mkdir -p /opt/etc/ndm/netfilter.d
	timeout 30 xkeen -restart >/dev/null 2>&1 || log "ПРЕДУПРЕЖДЕНИЕ: xkeen -restart не завершился штатно (известная проблема на чистом OpenWRT) — это ожидаемо, SmartRoute управляет Xray самостоятельно. / xkeen -restart didn't finish cleanly (known issue on plain OpenWRT) — expected, SmartRoute manages Xray itself from here on."
else
	log "xkeen уже установлен: $(xkeen -status 2>/dev/null | head -n1 || echo ok)"
fi

# xkeen ships 01_log.json/03_inbounds.json/05_routing.json with `//` comments
# (and, on some mirrors, non-UTF8 Cyrillic in those comments). Functionally
# harmless to Xray itself, but xkeen-UI's GUI Mode (visual routing/log editor,
# see its own Settings page) parses these files as strict JSON to render
# them -- a file with comments fails that parse and the UI just shows nothing,
# which looks like the config doesn't exist at all. Overwritten unconditionally
# on every run (not just fresh installs) so an existing install picks this up
# too; functionally identical to xkeen's own templates, just comment-free.
cat > /opt/etc/xray/configs/01_log.json <<'XRAY_LOG_EOF'
{
  "log": {
    "access": "/opt/var/log/xray/access.log",
    "error": "/opt/var/log/xray/error.log",
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

# Same content as xkeen's own template, minus comments, with one deliberate
# fix: the trailing catch-all's outboundTag corrected from "vless-reality" (a
# placeholder outbound install.sh deletes -- see the 04_outbounds.json step
# above) to "direct". lib/genroute.sh already appends its own "direct"
# catch-all that takes effect first (confdir load-order), so this rule is
# unreachable in practice -- fixed anyway so xkeen-UI's visualizer doesn't
# point at a tag that doesn't exist.
cat > /opt/etc/xray/configs/05_routing.json <<'XRAY_ROUTING_EOF'
{
  "routing": {
    "rules": [
      {
        "inboundTag": ["redirect", "tproxy"],
        "domain": [
          "regexp:^([\\w\\-\\.]+\\.)ru$",
          "regexp:^([\\w\\-\\.]+\\.)su$",
          "regexp:^([\\w\\-\\.]+\\.)xn--p1ai$",
          "regexp:^([\\w\\-\\.]+\\.)xn--p1acf$",
          "regexp:^([\\w\\-\\.]+\\.)xn--80asehdb$",
          "regexp:^([\\w\\-\\.]+\\.)xn--c1avg$",
          "regexp:^([\\w\\-\\.]+\\.)xn--80aswg$",
          "regexp:^([\\w\\-\\.]+\\.)xn--80adxhks$",
          "regexp:^([\\w\\-\\.]+\\.)moscow$",
          "regexp:^([\\w\\-\\.]+\\.)xn--d1acj3b$"
        ],
        "outboundTag": "direct",
        "type": "field"
      },
      {
        "inboundTag": ["redirect", "tproxy"],
        "outboundTag": "direct",
        "type": "field"
      }
    ]
  }
}
XRAY_ROUTING_EOF

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
	already_has_pw="$( [ -s "$xkeenui_cfg" ] && jq -r '.auth.password_hash // empty' "$xkeenui_cfg" 2>/dev/null )"
	if [ -n "$already_has_pw" ]; then
		log "У xkeen-UI уже задан пароль, пропускаю."
	elif [ -r /dev/tty ]; then
		log "Задайте пароль для веб-панели xkeen-UI (порт 1000) -- рекомендуется тот же, что и для входа на роутер."
		printf "Пароль: "
		stty -echo < /dev/tty 2>/dev/null
		read -r xkeenui_pw < /dev/tty
		stty echo < /dev/tty 2>/dev/null
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
sed -i "s#XKEEN_CONFIGS_DIR=\"/opt/etc/xray/configs\"#XKEEN_CONFIGS_DIR=\"/opt/etc/xray/configs\"#" "$SR_LIB_DIR/common.sh" 2>/dev/null || true

wget -O "$SR_ETC_DIR/lists/geosite-categories.json" "$REPO_RAW/lists/geosite-categories.json" || true
wget -O "$SR_ETC_DIR/lists/custom-categories.json" "$REPO_RAW/lists/custom-categories.json" || true
mkdir -p "$SR_ETC_DIR/lists/custom"
for svc in character-ai grok npm; do
	wget -O "$SR_ETC_DIR/lists/custom/${svc}.lst" "$REPO_RAW/lists/custom/${svc}.lst" 2>/dev/null || true
done

mkdir -p /usr/share/rpcd/acl.d /usr/libexec/rpcd /www/luci-static/resources/view/xkeen-smartroute /usr/share/luci/menu.d
for f in root/usr/share/rpcd/acl.d/luci-app-xkeen-smartroute.json \
         root/usr/libexec/rpcd/luci.xkeen-smartroute \
         root/usr/share/luci/menu.d/luci-app-xkeen-smartroute.json \
         root/www/luci-static/resources/xkeen-smartroute.js \
         root/www/luci-static/resources/view/xkeen-smartroute/subscriptions.js \
         root/www/luci-static/resources/view/xkeen-smartroute/profiles.js \
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

# ---------------------------------------------------------------------------
log "Шаг 5/6: smartroute-gateway (живая панель в духе Mihomo, порт $SR_GATEWAY_PORT)"

case "$DISTRIB_ARCH" in
	mipsel_24kc|mipsel_24kec) GATEWAY_ASSET="smartroute-gateway-mipsle-softfloat" ;;
	mips_24kc)                GATEWAY_ASSET="smartroute-gateway-mips-softfloat" ;;
	aarch64*)                 GATEWAY_ASSET="smartroute-gateway-arm64" ;;
	arm_cortex-a*)             GATEWAY_ASSET="smartroute-gateway-arm7" ;;
	x86_64)                   GATEWAY_ASSET="smartroute-gateway-amd64" ;;
	*) GATEWAY_ASSET="" ;;
esac

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
		wget -O "$SR_SHARE_DIR/panel/index.html" "$REPO_RAW/gateway/static/index.html" \
			|| die "не удалось скачать панель gateway/static/index.html"

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
		log "Панель: http://$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1):$SR_GATEWAY_PORT/"
	fi
fi

# ---------------------------------------------------------------------------
log "Шаг 6/6: cron (обновление geosite/geoip раз в 8 часов, подписок — по расписанию)"

CRON_GEO="0 */8 * * * xkeen -ug >/dev/null 2>&1; xkeen -uk >/dev/null 2>&1 #xkeen-smartroute-cron"
# Fires hourly, but subscription.sh refresh itself checks a timestamp against
# the configured interval (default 12h, changeable in the UI without editing
# crontab) and exits immediately if it isn't due yet -- simpler and more
# flexible than rewriting a cron schedule string for an arbitrary N-hour gap.
CRON_SUB="7 * * * * sh $SR_LIB_DIR/subscription.sh refresh >/dev/null 2>&1 #xkeen-smartroute-cron"
( crontab -l 2>/dev/null | grep -v 'xkeen-smartroute-cron' ; echo "$CRON_GEO" ; echo "$CRON_SUB" ) | crontab -
/etc/init.d/cron restart >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
log ""
log "Готово! / Done!"
log "  LuCI:      http://$LAN_IP/  ->  Services / Сервисы -> XKeen SmartRoute"
log "  xkeen-UI:  http://$LAN_IP:1000/"
log "  Панель:    http://$LAN_IP:$SR_GATEWAY_PORT/"
log "  Списки:    $SR_ETC_DIR/lists/"
log "Диагностика: sh $SR_LIB_DIR/../check.sh (или ./check.sh из репозитория)"
