#!/bin/sh
# lib/killswitch.sh — optional hard kill-switch for XKeen SmartRoute profiles.
#
# Two layers of protection:
#  1. "Soft" (always on, free): traffic for a profile's domains is redirected
#     to xray's local inbound by xkeen's own firewall rules. If the xray
#     process is down, that redirect target is gone and the connection is
#     refused locally — it does NOT silently fall through to a direct route.
#     This already covers geosite:-based profiles with no extra setup.
#  2. "Hard" (opt-in, per profile): resolved IPs of the profile's domains are
#     collected into an ipset via dnsmasq, and a firewall REJECT rule on the
#     LAN->WAN forward chain covers that ipset. dnsmasq needs literal domain
#     names, not Xray's compiled geosite.dat, so for "geosite" profiles we
#     resolve the category's *source* domain list from
#     v2fly/domain-list-community (the same project Xray's geosite.dat is
#     built from) via resolve_geosite_domains() below, and feed it into the
#     exact same ipset mechanism "custom" profiles already use. Only that
#     source list's literal `domain:`/`full:` entries translate to dnsmasq
#     ipset rules -- categories that lean on `keyword:`/`regexp:` matches
#     (Xray-only features, no literal domain to hand to dnsmasq) get partial
#     coverage, not the exact same match set Xray itself uses. Good enough to
#     fail closed for the vast majority of a category's traffic; not a
#     byte-for-byte guarantee.
#
#     The REJECT rule is armed the instant kill-switch is enabled and stays
#     armed until it's disabled -- it does NOT get toggled by polling whether
#     xray is alive (an earlier version did, once a minute via cron, which
#     left up to a 60s window where a dead xray wasn't yet blocked). That
#     polling turned out to be unnecessary: xkeen's own PREROUTING REDIRECT
#     sends matched traffic to xray's local inbound via DNAT, and DNAT to a
#     local address routes the packet through INPUT, never through FORWARD --
#     so properly redirected traffic can never reach this rule in the first
#     place, whether xray is up or down. The rule only ever fires for traffic
#     that *isn't* captured by the redirect at all (xray's process or its own
#     firewall rules gone), which is exactly the failure mode it exists for.
#     Always-on and gap-free, and simpler than the polling version was.
#
# Usage:
#   killswitch.sh enable <profile-name>
#   killswitch.sh disable <profile-name>

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

SR_KS_FLAG_DIR="$SR_STATE_DIR/killswitch"
SR_GEOSITE_CACHE_DIR="$SR_LISTS_DIR/geosite-resolved"
GEOSITE_SRC_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
GEOSITE_CACHE_MAX_AGE_DAYS=7
IPSET_NAME="sr_killswitch"
FW_RULE_NAME="xkeen_smartroute_killswitch"

# resolve_geosite_domains <category> [_seen-categories]
# Prints one literal domain per line, resolving `include:` references
# recursively (guarded against cycles) and dropping keyword:/regexp: entries
# that have no literal-domain equivalent. Caches each category's result for
# GEOSITE_CACHE_MAX_AGE_DAYS so re-enabling kill-switch doesn't refetch every
# time; ks_check (the once-a-minute cron job) never calls this at all.
resolve_geosite_domains() {
	category="$1"; seen="${2:-}"
	case " $seen " in *" $category "*) return 0 ;; esac
	seen="$seen $category"

	mkdir -p "$SR_GEOSITE_CACHE_DIR"
	cache_file="$SR_GEOSITE_CACHE_DIR/$category.lst"
	fresh=0
	if [ -f "$cache_file" ]; then
		age_days=$(( ($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)) / 86400 ))
		[ "$age_days" -lt "$GEOSITE_CACHE_MAX_AGE_DAYS" ] && fresh=1
	fi

	if [ "$fresh" != "1" ]; then
		src="$(curl -fsSL --max-time 15 "$GEOSITE_SRC_BASE/$category" 2>/dev/null)" || src=""
		if [ -n "$src" ]; then
			printf '%s\n' "$src" \
				| sed 's/#.*$//' \
				| grep -v '^[[:space:]]*$' \
				| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
				| grep -vE '^(keyword|regexp):' \
				| sed -E 's/^(domain|full)://; s/[[:space:]]*@[^[:space:]]*$//' \
				| sed 's/[[:space:]]*$//' \
				| sort -u > "$cache_file.direct"
			printf '%s\n' "$src" | grep -oE '^[[:space:]]*include:[A-Za-z0-9_-]+' | sed 's/.*include://' > "$cache_file.includes" || true
		else
			: > "$cache_file.direct"
			: > "$cache_file.includes"
		fi
	fi

	[ -f "$cache_file.direct" ] && cat "$cache_file.direct"
	if [ -f "$cache_file.includes" ]; then
		while IFS= read -r inc; do
			[ -n "$inc" ] || continue
			resolve_geosite_domains "$inc" "$seen"
		done < "$cache_file.includes"
	fi
}

ks_rebuild_dnsmasq() {
	mkdir -p "$SR_KS_FLAG_DIR"
	# Drop the whole ipset list option in one operation and rebuild it from
	# scratch below. The previous approach called `uci get` + `uci del_list`
	# once per existing entry -- fine for a handful of custom-list domains,
	# but a single geosite category can resolve to 100+ domains, and each
	# get/del round-trip re-parses the whole UCI config file, so removing them
	# one at a time took minutes instead of the expected instant. `uci delete`
	# on the option itself is a single O(1) operation regardless of length.
	uci -q delete dhcp.@dnsmasq[0].ipset 2>/dev/null || true

	any=0
	for f in "$SR_KS_FLAG_DIR"/*.name; do
		[ -e "$f" ] || continue
		profile="$(cat "$f")"
		pf="$SR_PROFILES_DIR/$profile.json"
		[ -f "$pf" ] || continue
		src_type="$(jq -r '.domain_source.type' "$pf")"
		if [ "$src_type" = "custom" ]; then
			list_file="$SR_LISTS_DIR/$(jq -r '.domain_source.file' "$pf")"
			[ -f "$list_file" ] || continue
			domains="$(grep -v '^#' "$list_file" | grep -v '^$' | tr '\n' '/' | sed 's#/$##')"
		elif [ "$src_type" = "geosite" ]; then
			category="$(jq -r '.domain_source.value' "$pf")"
			domains="$(resolve_geosite_domains "$category" | tr '\n' '/' | sed 's#/$##')"
		else
			continue
		fi
		[ -n "$domains" ] || continue
		uci add_list dhcp.@dnsmasq[0].ipset="/${domains}/${IPSET_NAME}"
		any=1
	done
	uci commit dhcp

	if [ "$any" = "1" ]; then
		# Always on from the moment a profile has kill-switch enabled -- not
		# toggled by polling xray's liveness. Properly redirected traffic
		# (xkeen's PREROUTING REDIRECT to xray's local inbound) never reaches
		# this LAN->WAN FORWARD rule at all: DNAT-to-a-local-address sends the
		# packet through INPUT, not FORWARD, regardless of whether xray is
		# actually listening on the other end. So this rule is inert during
		# normal operation and only ever fires for the situation it exists
		# for: traffic that *isn't* captured by the redirect (xray's process
		# or its firewall rules gone) has nowhere else to go but here. No
		# polling means no window where protection is one cron tick behind.
		uci set firewall.$FW_RULE_NAME="rule"
		uci set firewall.$FW_RULE_NAME.name="XKeen SmartRoute kill-switch"
		uci set firewall.$FW_RULE_NAME.src="lan"
		uci set firewall.$FW_RULE_NAME.dest="wan"
		uci set firewall.$FW_RULE_NAME.ipset="$IPSET_NAME"
		uci set firewall.$FW_RULE_NAME.target="REJECT"
		uci set firewall.$FW_RULE_NAME.enabled="1"
		uci commit firewall
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
	sr_log "kill-switch enabled for profile '$name'"
}

ks_disable() {
	name="${1:?profile name required}"
	rm -f "$SR_KS_FLAG_DIR/$name.name"
	ks_rebuild_dnsmasq
	sr_log "kill-switch disabled for profile '$name'"
}

ks_list_enabled() {
	printf '['
	first=1
	for f in "$SR_KS_FLAG_DIR"/*.name; do
		[ -e "$f" ] || continue
		[ "$first" = "1" ] || printf ','
		first=0
		jq -Rn --arg n "$(cat "$f")" '$n'
	done
	printf ']'
}

case "${1:-}" in
	enable) ks_enable "${2:-}" ;;
	disable) ks_disable "${2:-}" ;;
	list-enabled) ks_list_enabled ;;
	*) echo "usage: $0 {enable <profile>|disable <profile>|list-enabled}" >&2; exit 1 ;;
esac
