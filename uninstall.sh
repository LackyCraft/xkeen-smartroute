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

SR_SHARE_DIR="/opt/share/xkeen-smartroute"
SR_LIB_DIR="$SR_SHARE_DIR/lib"
if [ -f /etc/openwrt_release ] || ! uname -r 2>/dev/null | grep -q -- '-ndm-'; then
	SR_ETC_DIR="/etc/xkeen-smartroute"
else
	# KeeneticOS's /etc is read-only -- install.sh puts this under /opt/etc
	# there instead, see its own platform-detection comment for why.
	SR_ETC_DIR="/opt/etc/xkeen-smartroute"
fi

log "Удаляю сгенерированные конфиги Xray... / Removing generated Xray configs..."
# Every Xray confdir fragment SmartRoute itself ever creates: the *.smartroute
# suffix marks the ones lib/genroute.sh and lib/subscription.sh generate at
# runtime; 00_api.smartroute.json and 01_log.json are install.sh/common.sh's
# own, unsuffixed but just as exclusively ours (01_log.json in particular is
# sr_apply_log_config's file, not something xkeen ships). Left behind, these
# keep routing/observatory/logging config alive under Xray indefinitely after
# "uninstall" -- not just clutter, active behavior.
rm -f /opt/etc/xray/configs/00_api.smartroute.json \
      /opt/etc/xray/configs/01_log.json \
      /opt/etc/xray/configs/04_outbounds.smartroute.json \
      /opt/etc/xray/configs/05_routing.smartroute.json \
      /opt/etc/xray/configs/07_observatory.smartroute.json \
      /opt/etc/xray/configs/09_balancer.smartroute.json

# Not `xkeen -restart`: confirmed in lib/common.sh (sr_restart_xray's own
# comment) that it hangs indefinitely on real OpenWrt trying to write a
# Keenetic-only NDM netfilter hook file -- that's exactly why the rest of
# this codebase never calls it either. sr_restart_xray is the same detached,
# bounded-wait relaunch every other write path already uses, so borrow it
# here instead of reintroducing the one command this project has already
# proven can hang the whole uninstall. Sourced from lib/ before it's removed
# below; timeout is still a hard backstop in case xray itself misbehaves.
if [ -f "$SR_LIB_DIR/common.sh" ]; then
	# shellcheck source=/dev/null
	. "$SR_LIB_DIR/common.sh"
	if command -v timeout >/dev/null 2>&1; then
		timeout 30 sh -c 'sr_restart_xray' >/dev/null 2>&1 || true
	else
		sr_restart_xray >/dev/null 2>&1 || true
	fi
fi

log "Удаляю LuCI-модуль... / Removing the LuCI module..."
rm -f /usr/share/rpcd/acl.d/luci-app-xkeen-smartroute.json
rm -f /usr/libexec/rpcd/luci.xkeen-smartroute
rm -f /usr/share/luci/menu.d/luci-app-xkeen-smartroute.json
rm -rf /www/luci-static/resources/view/xkeen-smartroute
rm -f /www/luci-static/resources/xkeen-smartroute.js
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

log "Останавливаю панель smartroute-gateway... / Stopping the smartroute-gateway panel..."
if [ -x /opt/etc/init.d/S98smartroute-gateway ]; then
	/opt/etc/init.d/S98smartroute-gateway stop >/dev/null 2>&1 || true
fi
# Belt and braces: the init script's stop() only kills what pgrep -f finds
# under $SR_SHARE_DIR/gateway, which is about to be removed anyway below --
# make sure nothing is left listening on the panel port regardless.
for pid in $(pgrep -f "$SR_SHARE_DIR/gateway" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
rm -f /opt/etc/init.d/S98smartroute-gateway

log "Удаляю правило перехвата трафика (nftables)... / Removing the traffic-capture nftables rule..."
# lib/redirect.sh's managed .nft file -- fw4 loads every *.nft under
# /etc/nftables.d/ on every boot/reload regardless of whether SmartRoute
# itself is still installed. Left behind with capture enabled, this keeps
# redirecting LAN DNS/TCP 80+443 to a now-deleted xray inbound and keeps
# dropping all LAN->WAN IPv6 forever -- an uninstalled SmartRoute would
# otherwise leave the router's internet access silently half-broken instead
# of restoring plain routing.
rm -f /etc/nftables.d/20-xkeen-smartroute-redirect.nft

log "Удаляю библиотеки и cron-задачи... / Removing libraries and cron jobs..."
rm -rf "$SR_SHARE_DIR"
crontab -l 2>/dev/null | grep -v 'xkeen-smartroute-cron' | crontab - || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

log "Удаляю правила kill-switch, если были... / Removing kill-switch firewall/dnsmasq state, if any..."
# All three pieces lib/killswitch.sh can leave armed: the LAN->WAN REJECT
# rule, the firewall-side ipset that actually backs it, and the dhcp-side
# ipset section telling dnsmasq which domains feed it. Missing any one of
# these used to mean either a dangling nftables set (harmless but untidy) or
# -- worse -- dnsmasq left permanently pointed at a set/table that no longer
# has a rule using it.
uci -q delete firewall.xkeen_smartroute_killswitch 2>/dev/null || true
uci -q delete firewall.sr_killswitch_ipset 2>/dev/null || true
uci -q delete dhcp.sr_killswitch 2>/dev/null || true
uci commit firewall 2>/dev/null || true
uci commit dhcp 2>/dev/null || true
nft delete set inet fw4 sr_killswitch >/dev/null 2>&1 || true
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
	log "Удаляю профили и списки доменов ($SR_ETC_DIR)... / Removing profiles and domain lists ($SR_ETC_DIR)..."
	rm -rf "$SR_ETC_DIR"
else
	log "Профили и списки в $SR_ETC_DIR оставлены, запустите с --purge, чтобы удалить и их."
	log "Profiles and lists in $SR_ETC_DIR were kept, re-run with --purge to remove them too."
fi

log "Готово. xkeen, xkeen-UI и Entware не тронуты. / Done. xkeen, xkeen-UI and Entware were left untouched."
