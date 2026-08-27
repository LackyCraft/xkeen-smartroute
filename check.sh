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

if pgrep -x xray >/dev/null 2>&1; then
	ok "процесс xray запущен / xray process is running"
else
	bad "процесс xray не запущен / xray process is not running"
fi

if [ -x /opt/sbin/xkeen-ui ] || [ -x /opt/bin/xkeen-ui ] || pgrep -f xkeen-ui >/dev/null 2>&1; then
	ok "xkeen-UI похоже установлен/запущен, порт 1000 / xkeen-UI looks installed/running, port 1000"
else
	info "xkeen-UI не обнаружен (не обязателен для SmartRoute) / xkeen-UI not found (not required for SmartRoute)"
fi

for f in /opt/etc/xray/configs/00_api.smartroute.json \
         /opt/etc/xray/configs/04_outbounds.smartroute.json \
         /opt/etc/xray/configs/05_routing.smartroute.json \
         /opt/etc/xray/configs/07_observatory.smartroute.json ; do
	if [ -f "$f" ]; then
		if command -v jq >/dev/null 2>&1 && jq empty "$f" >/dev/null 2>&1; then
			ok "$f — валидный JSON / valid JSON"
		else
			bad "$f — присутствует, но НЕ валидный JSON / present but NOT valid JSON"
		fi
	else
		info "$f — ещё не сгенерирован (нет подписки/профиля/balancer-профиля) / not generated yet (no subscription/profile/balancer-mode profile)"
	fi
done
# 09_balancer.smartroute.json is deliberately NOT checked here -- genroute.sh
# unconditionally rm -f's it on every regen (routing.balancers is unused by
# design, see sr_pick_top1's own comment), so it never exists anymore and
# "not generated yet" would be permanently, confusingly wrong rather than
# actually informative.

SR_GATEWAY_BIN="/opt/share/xkeen-smartroute/gateway"
if pgrep -f "$SR_GATEWAY_BIN" >/dev/null 2>&1; then
	if command -v curl >/dev/null 2>&1 && curl -s -m 3 http://127.0.0.1:1001/version >/dev/null 2>&1; then
		ok "smartroute-gateway запущен и отвечает, порт 1001 / smartroute-gateway running and responding, port 1001"
	else
		bad "smartroute-gateway процесс есть, но порт 1001 не отвечает / smartroute-gateway process found but port 1001 not responding"
	fi
else
	info "smartroute-gateway не запущен (панель :1001 недоступна; необязательна для основной маршрутизации) / smartroute-gateway not running (the :1001 panel is unavailable; not required for core routing)"
fi

if [ -f /etc/nftables.d/20-xkeen-smartroute-redirect.nft ]; then
	ok "nftables-правило перехвата трафика найдено / traffic-capture nftables rule found"
else
	info "nftables-правило перехвата трафика отсутствует (перехват выключен) / traffic-capture nftables rule absent (capture disabled)"
fi

if crontab -l 2>/dev/null | grep -q 'xkeen-smartroute-cron'; then
	ok "cron-задача найдена / cron job found"
else
	bad "cron-задача отсутствует — автообновление подписок/списков не будет работать / cron job missing -- subscription/list auto-refresh won't run"
fi

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
