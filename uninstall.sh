#!/bin/sh
# XKeen SmartRoute — uninstaller / деинсталлятор.
# Removes our LuCI app, generated Xray fragments, cron entry and (optionally)
# the domain-list state directory. Does NOT remove Entware, xkeen or xkeen-UI
# themselves — those are separate projects, remove them with their own tooling.
#
# Удаляет наш LuCI-модуль, сгенерированные конфиги Xray, cron-задачи и (опция)
# каталог с профилями/списками. Entware, xkeen и xkeen-UI не трогает — это
# отдельные проекты, для их удаления используйте их собственные инструменты.

set -eu
log() { echo "[xkeen-smartroute] $*"; }

log "Удаляю сгенерированные конфиги Xray... / Removing generated Xray configs..."
rm -f /opt/etc/xray/configs/04_outbounds.smartroute.json \
      /opt/etc/xray/configs/05_routing.smartroute.json \
      /opt/etc/xray/configs/09_balancer.smartroute.json
command -v xkeen >/dev/null 2>&1 && xkeen -restart >/dev/null 2>&1 || true

log "Удаляю LuCI-модуль... / Removing the LuCI module..."
rm -f /usr/share/rpcd/acl.d/luci-app-xkeen-smartroute.json
rm -f /usr/libexec/rpcd/luci.xkeen-smartroute
rm -f /usr/share/luci/menu.d/luci-app-xkeen-smartroute.json
rm -rf /www/luci-static/resources/view/xkeen-smartroute
rm -f /www/luci-static/resources/xkeen-smartroute.js
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

log "Удаляю библиотеки и cron-задачи... / Removing libraries and cron jobs..."
rm -rf /opt/share/xkeen-smartroute
crontab -l 2>/dev/null | grep -v 'xkeen-smartroute-cron' | crontab - || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

log "Удаляю правило kill-switch, если было... / Removing kill-switch firewall rule, if any..."
uci -q delete firewall.xkeen_smartroute_killswitch 2>/dev/null || true
uci commit firewall 2>/dev/null || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
	log "Удаляю профили и списки доменов (/etc/xkeen-smartroute)... / Removing profiles and domain lists (/etc/xkeen-smartroute)..."
	rm -rf /etc/xkeen-smartroute
else
	log "Профили и списки в /etc/xkeen-smartroute оставлены, запустите с --purge, чтобы удалить и их."
	log "Profiles and lists in /etc/xkeen-smartroute were kept, re-run with --purge to remove them too."
fi

log "Готово. xkeen, xkeen-UI и Entware не тронуты. / Done. xkeen, xkeen-UI and Entware were left untouched."
