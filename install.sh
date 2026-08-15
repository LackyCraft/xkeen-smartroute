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
#   5. Sets up a cron job to refresh geosite/geoip data periodically.
#
# Safe to re-run (idempotent): existing installs are detected and skipped/updated.

set -eu

REPO_RAW="https://raw.githubusercontent.com/LackyCraft/xkeen-smartroute/main"
XKEEN_INSTALL_URL="https://raw.githubusercontent.com/Skrill0/XKeen/main/install.sh"
XKEEN_UI_REPO="zxc-rv/XKeen-UI"
SR_ETC_DIR="/etc/xkeen-smartroute"
SR_LIB_DIR="/opt/share/xkeen-smartroute/lib"
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
log "Шаг 1/5: Entware"

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

export PATH="/opt/bin:/opt/sbin:$PATH"
/opt/bin/opkg update >/dev/null 2>&1 || true
/opt/bin/opkg install jq curl bash coreutils-base64 grep sed >/dev/null 2>&1 \
	|| die "не удалось поставить базовые пакеты Entware (jq/curl/...) / failed to install base Entware packages"

# ---------------------------------------------------------------------------
log "Шаг 2/5: xkeen"

if ! command -v xkeen >/dev/null 2>&1; then
	log "Ставлю xkeen (Skrill0/XKeen)..."
	sh -c "$(wget -O - "$XKEEN_INSTALL_URL")" || die "установка xkeen завершилась с ошибкой / xkeen install failed"
else
	log "xkeen уже установлен: $(xkeen -status 2>/dev/null | head -n1 || echo ok)"
fi

# ---------------------------------------------------------------------------
log "Шаг 3/5: xkeen-UI (веб-панель, порт 1000)"

if [ ! -x /opt/sbin/xkeen-ui ] && [ ! -x /opt/bin/xkeen-ui ]; then
	log "Ставлю xkeen-UI ($XKEEN_UI_REPO)..."
	wget -O /tmp/xkeen-ui-setup.sh "https://raw.githubusercontent.com/${XKEEN_UI_REPO}/main/setup.sh" \
		&& sh /tmp/xkeen-ui-setup.sh \
		|| log "ПРЕДУПРЕЖДЕНИЕ: автоустановка xkeen-UI не удалась, поставьте вручную по https://github.com/${XKEEN_UI_REPO} — остальной стек всё равно будет настроен."
	rm -f /tmp/xkeen-ui-setup.sh
else
	log "xkeen-UI уже установлен, пропускаю."
fi

# ---------------------------------------------------------------------------
log "Шаг 4/5: XKeen SmartRoute (наш LuCI-модуль + генераторы конфигов)"

mkdir -p "$SR_ETC_DIR/lists" "$SR_ETC_DIR/lists/custom" "$SR_ETC_DIR/profiles" "$SR_ETC_DIR/state" "$SR_LIB_DIR"

for f in common.sh subscription.sh genroute.sh killswitch.sh; do
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
         root/www/luci-static/resources/view/xkeen-smartroute/killswitch.js ; do
	dest="/${f#root/}"
	mkdir -p "$(dirname "$dest")"
	wget -O "$dest" "$REPO_RAW/luci-app-xkeen-smartroute/$f" || die "не удалось скачать $f"
done
chmod +x /usr/libexec/rpcd/luci.xkeen-smartroute
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "Шаг 5/5: cron (обновление geosite/geoip + списков раз в 8 часов)"

CRON_GEO="0 */8 * * * xkeen -ug >/dev/null 2>&1; xkeen -uk >/dev/null 2>&1 #xkeen-smartroute-cron"
CRON_KS="* * * * * sh $SR_LIB_DIR/killswitch.sh check >/dev/null 2>&1 #xkeen-smartroute-cron"
( crontab -l 2>/dev/null | grep -v 'xkeen-smartroute-cron' ; echo "$CRON_GEO" ; echo "$CRON_KS" ) | crontab -
/etc/init.d/cron restart >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
log ""
log "Готово! / Done!"
log "  LuCI:      http://$LAN_IP/  ->  Services / Сервисы -> XKeen SmartRoute"
log "  xkeen-UI:  http://$LAN_IP:1000/"
log "  Списки:    $SR_ETC_DIR/lists/"
log "Диагностика: sh $SR_LIB_DIR/../check.sh (или ./check.sh из репозитория)"
