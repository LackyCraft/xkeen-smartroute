#!/bin/sh
# XKeen SmartRoute — diagnostics / диагностика.
# Run after install (or any time something looks wrong) for a quick health report.
# Запустите после установки (или в любой непонятной ситуации) для быстрой проверки.

ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; }
info() { echo "  [--]   $*"; }

echo "XKeen SmartRoute — диагностика / diagnostics"
echo "=============================================="

if [ -f /etc/openwrt_release ]; then
	. /etc/openwrt_release
	ok "OpenWrt обнаружен / OpenWrt detected ($DISTRIB_DESCRIPTION)"
else
	bad "Это не OpenWrt / this is not OpenWrt"
fi

if [ -x /opt/bin/opkg ]; then ok "Entware установлен / Entware installed"; else bad "Entware не найден / Entware not found"; fi

if command -v xkeen >/dev/null 2>&1; then
	ok "xkeen найден / xkeen found: $(xkeen -status 2>/dev/null | head -n1)"
else
	bad "xkeen не найден в PATH / xkeen not found in PATH"
fi

if pgrep -f '/opt/.*/xray' >/dev/null 2>&1 || pgrep xray >/dev/null 2>&1; then
	ok "процесс xray запущен / xray process is running"
else
	bad "процесс xray не запущен / xray process is not running"
fi

if [ -x /opt/sbin/xkeen-ui ] || [ -x /opt/bin/xkeen-ui ] || pgrep -f xkeen-ui >/dev/null 2>&1; then
	ok "xkeen-UI похоже установлен/запущен, порт 1000 / xkeen-UI looks installed/running, port 1000"
else
	info "xkeen-UI не обнаружен (не обязателен для SmartRoute) / xkeen-UI not found (not required for SmartRoute)"
fi

for f in /opt/etc/xray/configs/04_outbounds.smartroute.json \
         /opt/etc/xray/configs/05_routing.smartroute.json \
         /opt/etc/xray/configs/09_balancer.smartroute.json ; do
	if [ -f "$f" ]; then
		if command -v jq >/dev/null 2>&1 && jq empty "$f" >/dev/null 2>&1; then
			ok "$f — валидный JSON / valid JSON"
		else
			bad "$f — присутствует, но НЕ валидный JSON / present but NOT valid JSON"
		fi
	else
		info "$f — ещё не сгенерирован (нет подписки/профиля) / not generated yet (no subscription/profile)"
	fi
done

[ -f /usr/libexec/rpcd/luci.xkeen-smartroute ] && ok "ubus backend установлен / ubus backend installed" || bad "ubus backend отсутствует / ubus backend missing"
[ -d /www/luci-static/resources/view/xkeen-smartroute ] && ok "LuCI view установлен / LuCI view installed" || bad "LuCI view отсутствует / LuCI view missing"

n_servers=0
if [ -f /etc/xkeen-smartroute/state/servers.json ] && command -v jq >/dev/null 2>&1; then
	n_servers="$(jq 'length' /etc/xkeen-smartroute/state/servers.json 2>/dev/null || echo 0)"
fi
info "серверов из подписок известно / servers known from subscriptions: $n_servers"

n_profiles="$(ls /etc/xkeen-smartroute/profiles/*.json 2>/dev/null | wc -l)"
info "профилей (правил маршрутизации) настроено / profiles (routing rules) configured: $n_profiles"

echo "=============================================="
echo "Если что-то FAIL — см. README, раздел Troubleshooting / Диагностика."
echo "If anything shows FAIL — see the README, Troubleshooting section."
