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
#     polling turned out to be unnecessary: lib/redirect.sh's own PREROUTING
#     redirect (nftables `redirect to :port`, not xkeen's -ap -- see that
#     file for why) sends matched traffic to xray's local inbound via a form
#     of DNAT, and DNAT to a local address routes the packet through INPUT,
#     never through FORWARD -- so properly redirected traffic can never reach
#     this rule in the first place, whether xray is up or down. The rule only
#     ever fires for traffic that *isn't* captured by the redirect at all
#     (xray's process, or lib/redirect.sh's own rules, gone), which is
#     exactly the failure mode it exists for. Always-on and gap-free, and
#     simpler than the polling version was.
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
FW_IPSET_SECTION="sr_killswitch_ipset" # firewall `config ipset` -- creates the actual nftables set
DHCP_IPSET_SECTION="sr_killswitch"     # dhcp `config ipset` -- tells dnsmasq which domains feed it
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
	# Named section (not @ipset[n]) so removing a stale one is a single O(1)
	# `uci delete` by name, same reasoning that replaced the old per-domain
	# del_list churn -- a geosite category can resolve to 100+ domains and
	# each get/del round-trip used to re-parse the whole UCI file.
	uci -q delete dhcp.$DHCP_IPSET_SECTION 2>/dev/null || true

	domains_file="$(mktemp)"
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
			grep -v '^#' "$list_file" | grep -v '^$' >>"$domains_file"
		elif [ "$src_type" = "geosite" ]; then
			category="$(jq -r '.domain_source.value' "$pf")"
			resolve_geosite_domains "$category" >>"$domains_file"
		else
			continue
		fi
		any=1
	done

	# dhcp-side `config ipset`: tells dnsmasq's own init script which
	# domains feed the set. It auto-emits either the legacy `ipset=`
	# directive or the modern `nftset=` one into dnsmasq.conf depending on
	# what this build's dnsmasq binary was actually compiled with (see
	# `dnsmasq --version`) -- we don't have to pick between them ourselves.
	if [ "$any" = "1" ] && [ -s "$domains_file" ]; then
		uci set dhcp.$DHCP_IPSET_SECTION="ipset"
		uci add_list dhcp.$DHCP_IPSET_SECTION.name="$IPSET_NAME"
		sort -u "$domains_file" | while IFS= read -r d; do
			[ -n "$d" ] || continue
			uci add_list dhcp.$DHCP_IPSET_SECTION.domain="$d"
		done
	else
		any=0
	fi
	rm -f "$domains_file"
	uci commit dhcp

	if [ "$any" = "1" ]; then
		# firewall-side `config ipset`: this is what actually creates the
		# native nftables set the REJECT rule below references. It was
		# missing entirely before -- the rule existed and looked armed, but
		# `ipset=$IPSET_NAME` pointed at a set fw4 had never been told to
		# create, so nothing was ever actually blocked.
		uci set firewall.$FW_IPSET_SECTION="ipset"
		uci set firewall.$FW_IPSET_SECTION.name="$IPSET_NAME"
		uci set firewall.$FW_IPSET_SECTION.match="dst_ip"
		uci set firewall.$FW_IPSET_SECTION.family="4"
		uci set firewall.$FW_IPSET_SECTION.timeout="-1"

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
		uci -q delete firewall.$FW_IPSET_SECTION 2>/dev/null || true
		uci commit firewall
	fi

	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	/etc/init.d/firewall reload >/dev/null 2>&1 || true

	# `firewall reload` rebuilds rules/sets that are still in the config but
	# does NOT prune a set that's no longer configured -- confirmed live: an
	# `ipset` UCI section removed above still leaves its nftables set (and
	# whatever IPs were already resolved into it) sitting in the live
	# ruleset untouched. Left alone, that stale set either lingers
	# unreferenced (harmless but untidy) or, worse, gets silently reused the
	# next time *any* profile re-enables kill-switch (same set name/type),
	# carrying IPs resolved for a since-disabled or since-edited profile's
	# domains into a REJECT rule that has nothing to do with them --
	# over-blocking traffic that was never supposed to be in scope. Flush
	# (still armed) or delete (nothing armed) the live set explicitly so it
	# only ever reflects the domain list just written, never a previous one.
	if [ "$any" = "1" ]; then
		nft flush set inet fw4 "$IPSET_NAME" >/dev/null 2>&1 || true
	else
		nft delete set inet fw4 "$IPSET_NAME" >/dev/null 2>&1 || true
	fi
}

ks_check_dnsmasq_capability() {
	dnsmasq --version 2>/dev/null | grep -q ' ipset\| nftset' \
		|| sr_die "system dnsmasq lacks ipset/nftset support -- install dnsmasq-full (opkg remove dnsmasq && opkg install dnsmasq-full) to use the hard kill-switch"
}

ks_enable() {
	name="${1:?profile name required}"
	ks_check_dnsmasq_capability
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
