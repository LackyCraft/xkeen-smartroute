#!/bin/sh
# lib/killswitch.sh — optional hard kill-switch for XKeen SmartRoute profiles.
#
# Two layers of protection:
#  1. "Soft" (always on, free): traffic for a profile's domains is redirected
#     to xray's local inbound by xkeen's own firewall rules. If the xray
#     process is down, that redirect target is gone and the connection is
#     refused locally — it does NOT silently fall through to a direct route.
#     This already covers geosite:-based profiles with no extra setup.
#  2. "Hard" (opt-in, per profile, custom domain lists only): resolved IPs of
#     the profile's domains are collected into an ipset via dnsmasq, and a
#     firewall rule DROPs traffic to that ipset on wan-out whenever xray is
#     confirmed not running. Needs literal domains (dnsmasq can't expand
#     Xray's compiled geosite.dat), so it only applies to "custom" profiles.
#
# Usage:
#   killswitch.sh enable <profile-name>
#   killswitch.sh disable <profile-name>
#   killswitch.sh check      # run every minute from cron: flips the firewall
#                             # rule on/off depending on whether xray is alive

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

SR_KS_FLAG_DIR="$SR_STATE_DIR/killswitch"
IPSET_NAME="sr_killswitch"
FW_RULE_NAME="xkeen_smartroute_killswitch"

ks_rebuild_dnsmasq() {
	mkdir -p "$SR_KS_FLAG_DIR"
	# remove any previously-added ipset lines for our profiles, then re-add
	while first="$(uci -q get dhcp.@dnsmasq[0].ipset 2>/dev/null | head -n1)" && [ -n "$first" ]; do
		uci -q del_list dhcp.@dnsmasq[0].ipset="$first" || break
	done

	any=0
	for f in "$SR_KS_FLAG_DIR"/*.name; do
		[ -e "$f" ] || continue
		profile="$(cat "$f")"
		pf="$SR_PROFILES_DIR/$profile.json"
		[ -f "$pf" ] || continue
		src_type="$(jq -r '.domain_source.type' "$pf")"
		[ "$src_type" = "custom" ] || continue
		list_file="$SR_LISTS_DIR/$(jq -r '.domain_source.file' "$pf")"
		[ -f "$list_file" ] || continue
		domains="$(grep -v '^#' "$list_file" | grep -v '^$' | tr '\n' '/' | sed 's#/$##')"
		[ -n "$domains" ] || continue
		uci add_list dhcp.@dnsmasq[0].ipset="/${domains}/${IPSET_NAME}"
		any=1
	done
	uci commit dhcp

	if [ "$any" = "1" ]; then
		if ! uci -q get "firewall.$FW_RULE_NAME" >/dev/null 2>&1; then
			uci set firewall.$FW_RULE_NAME="rule"
			uci set firewall.$FW_RULE_NAME.name="XKeen SmartRoute kill-switch"
			uci set firewall.$FW_RULE_NAME.src="lan"
			uci set firewall.$FW_RULE_NAME.dest="wan"
			uci set firewall.$FW_RULE_NAME.ipset="$IPSET_NAME"
			uci set firewall.$FW_RULE_NAME.target="REJECT"
			uci set firewall.$FW_RULE_NAME.enabled="0"
			uci commit firewall
		fi
	else
		uci -q delete firewall.$FW_RULE_NAME 2>/dev/null || true
		uci commit firewall
	fi

	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
}

ks_enable() {
	name="${1:?profile name required}"
	mkdir -p "$SR_KS_FLAG_DIR"
	echo "$name" >"$SR_KS_FLAG_DIR/$name.name"
	ks_rebuild_dnsmasq
	sr_log "kill-switch enabled for profile '$name' (custom domain lists only)"
}

ks_disable() {
	name="${1:?profile name required}"
	rm -f "$SR_KS_FLAG_DIR/$name.name"
	ks_rebuild_dnsmasq
	sr_log "kill-switch disabled for profile '$name'"
}

ks_check() {
	uci -q get "firewall.$FW_RULE_NAME" >/dev/null 2>&1 || exit 0
	alive=0
	# match by process name, not full cmdline: xray runs as bare "xray run"
	# (no resolved path in argv), while unrelated commands merely mentioning
	# /opt/etc/xray/configs/... (e.g. our own genroute.sh) matched instead --
	# the wrong signal for a check that arms/disarms a firewall block.
	pgrep -x xray >/dev/null 2>&1 && alive=1
	cur="$(uci -q get firewall.$FW_RULE_NAME.enabled || echo 0)"
	if [ "$alive" = "1" ] && [ "$cur" != "0" ]; then
		uci set firewall.$FW_RULE_NAME.enabled="0"
		uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1
		sr_log "xray is back up — kill-switch rule disarmed"
	elif [ "$alive" = "0" ] && [ "$cur" != "1" ]; then
		uci set firewall.$FW_RULE_NAME.enabled="1"
		uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1
		sr_log "xray is DOWN — kill-switch rule armed, blocking protected domains"
	fi
}

case "${1:-}" in
	enable) ks_enable "${2:-}" ;;
	disable) ks_disable "${2:-}" ;;
	check) ks_check ;;
	*) echo "usage: $0 {enable <profile>|disable <profile>|check}" >&2; exit 1 ;;
esac
