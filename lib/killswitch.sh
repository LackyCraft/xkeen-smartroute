#!/bin/sh
# lib/killswitch.sh — optional hard kill-switch for XKeen SmartRoute profiles.
#
# Two layers of protection:
#  1. "Soft" (always on, free): traffic for a profile's domains is redirected
#     to xray's local inbound by lib/redirect.sh's own firewall rules. If the
#     xray process is down, that redirect target is gone and the connection
#     is refused locally — it does NOT silently fall through to a direct
#     route (unless the user opted into leak-protect's fail-open default,
#     see redirect.sh's own FLAG_LEAK_PROTECT comment). Covers geosite:-based
#     profiles with no extra setup.
#  2. "Hard" (opt-in, per profile): resolved IPs of the profile's domains are
#     collected into an ipset, and a firewall REJECT rule on the LAN->WAN
#     forward chain covers that ipset. This closes the gap "soft" can't:
#     traffic that never went through the redirect at all (xray's process or
#     its firewall rules gone entirely, not just misbehaving).
#
#     Two platform backends, same domain-collection logic feeding both:
#      - OpenWrt (ks_apply_openwrt): the system's own dnsmasq (already the
#        LAN's real DHCP/DNS server) gets a UCI `config ipset` telling it
#        which domains feed the set, and a UCI firewall rule referencing it.
#        dnsmasq needs literal domain names, not Xray's compiled geosite.dat,
#        so for "geosite" profiles we resolve the category's *source* domain
#        list from v2fly/domain-list-community (the same project Xray's
#        geosite.dat is built from) via resolve_geosite_domains() below.
#        Only that source list's literal `domain:`/`full:` entries translate
#        to dnsmasq ipset rules -- categories that lean on `keyword:`/
#        `regexp:` matches (Xray-only features, no literal domain to hand to
#        dnsmasq) get partial coverage, not the exact same match set Xray
#        itself uses. Good enough to fail closed for the vast majority of a
#        category's traffic; not a byte-for-byte guarantee.
#      - KeeneticOS (ks_apply_keenetic): there is no system dnsmasq to piggy
#        back on at all -- KeeneticOS's own DNS is NDM's `ndnproxy`, already
#        bound to port 53, not dnsmasq-based. So this backend runs its own
#        dedicated Entware `dnsmasq-full` instance purely as an ipset
#        populator (not the LAN's real resolver): a PREROUTING REDIRECT sends
#        LAN port-53 traffic to this shadow instance instead, which forwards
#        every query on to ndnproxy (127.0.0.1:53, the router's real answer,
#        unchanged) while also feeding matching domains' resolved IPs into
#        the same ipset the REJECT rule below reads. Confirmed live: dnsmasq
#        does NOT auto-create the ipset its own `ipset=` directive names (as
#        opposed to `nftset=`, which can) -- it must already exist before
#        dnsmasq starts, or every resolution for a watched domain is just
#        silently dropped from the set instead of erroring.
#
#     The REJECT rule (both backends) is armed the instant kill-switch is
#     enabled and stays armed until it's disabled -- it does NOT get toggled
#     by polling whether xray is alive (an earlier version did, once a
#     minute via cron, which left up to a 60s window where a dead xray
#     wasn't yet blocked). That polling turned out to be unnecessary:
#     lib/redirect.sh's own PREROUTING redirect sends matched traffic to
#     xray's local inbound via a form of DNAT, and DNAT to a local address
#     routes the packet through INPUT, never through FORWARD -- so properly
#     redirected traffic can never reach this rule in the first place,
#     whether xray is up or down. The rule only ever fires for traffic that
#     *isn't* captured by the redirect at all (xray's process, or its
#     firewall rules, gone), which is exactly the failure mode it exists
#     for. Always-on and gap-free.
#
#     KeeneticOS's DNS-redirect-to-shadow-instance rule is a different
#     story: unlike the REJECT rule, IT actively intercepts every LAN DNS
#     query the instant kill-switch is armed for any profile, so a shadow
#     dnsmasq that's crashed (not "no domains configured", an actual process
#     death) would blackhole DNS resolution for the *entire* LAN, not just
#     kill-switch-protected profiles -- exactly the class of bug
#     redirect.sh's own fail-open leak-protect redesign exists to avoid.
#     ks_apply_keenetic only arms that redirect once it's confirmed the
#     freshly (re)launched shadow instance is actually up; `reapply` (the
#     boot hook + a cron watchdog, install.sh) re-checks and self-heals a
#     crashed instance the same way redirect.sh's own reapply does for
#     capture.
#
# Usage:
#   killswitch.sh enable <profile-name>
#   killswitch.sh disable <profile-name>
#   killswitch.sh list-enabled
#   killswitch.sh reapply              # KeeneticOS boot hook / cron watchdog

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

SR_KS_FLAG_DIR="$SR_STATE_DIR/killswitch"
SR_GEOSITE_CACHE_DIR="$SR_LISTS_DIR/geosite-resolved"
GEOSITE_SRC_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
GEOSITE_CACHE_MAX_AGE_DAYS=7
IPSET_NAME="sr_killswitch"
FW_IPSET_SECTION="sr_killswitch_ipset" # OpenWrt firewall `config ipset` -- creates the actual nftables set
DHCP_IPSET_SECTION="sr_killswitch"     # OpenWrt dhcp `config ipset` -- tells dnsmasq which domains feed it
FW_RULE_NAME="xkeen_smartroute_killswitch"

# KeeneticOS-only: the shadow dnsmasq instance and its firewall plumbing.
# 5310 -- arbitrary, high, and confirmed live not to collide with anything
# else this project or KeeneticOS itself already binds (xray's API on
# 10085, the panel on 1001, xkeen-UI on 1000, redirect.sh's own dynamic
# REDIRECT_PORT, NDM's ndnproxy on 53 itself).
KS_DNS_PORT=5310
KS_DNSMASQ_BIN="/opt/sbin/dnsmasq"
KS_DNSMASQ_CONF="$SR_STATE_DIR/killswitch_dnsmasq.conf"
KS_DNSMASQ_PID="$SR_STATE_DIR/killswitch_dnsmasq.pid"
IPT_CHAIN_KS_REJECT="SR_KS_REJECT"
IPT_CHAIN_KS_DNS="SR_KS_DNS_REDIRECT"

# ipt: every KeeneticOS iptables call in this file goes through this
# instead of the bare binary (no ip6tables here -- kill-switch is IPv4-only
# on both platforms, matching OpenWrt's own family="4" scope), same
# reasoning and same fix as lib/redirect.sh's own ipt()/ip6t() wrappers
# (see that file's own comment) -- the legacy xtables lock is a single
# systemwide lock file, so a kill-switch rebuild can lose the race against
# a concurrent redirect.sh call just as easily as against another
# kill-switch one, on top of the same-script races ks_rebuild_dnsmasq's own
# lock (above) already serializes. This build's iptables only supports the
# bare `-w` (no numeric timeout), which blocks until the lock is free
# instead of failing outright.
ipt() { iptables -w "$@"; }

# resolve_geosite_domains <category> [_seen-categories]
# Prints one literal domain per line, resolving `include:` references
# recursively (guarded against cycles) and dropping keyword:/regexp: entries
# that have no literal-domain equivalent. Caches each category's result for
# GEOSITE_CACHE_MAX_AGE_DAYS so re-enabling kill-switch doesn't refetch every
# time; `reapply` (the boot hook / cron watchdog) relies on that cache too,
# it never forces a refetch on its own.
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

# ks_collect_domains: prints one literal domain per line (not necessarily
# unique -- caller sorts/dedupes) across every currently-enabled profile,
# and reports via $ks_any (a global the caller reads right after calling
# this, plain sh has no other cheap way to return a second value) whether
# at least one enabled profile pointed at a real domain source, regardless
# of whether that source actually produced any domains (e.g. a geosite
# fetch that failed over the network) -- callers use that distinction to
# tell "nothing enabled" (fully tear down) apart from "enabled, but
# temporarily has nothing to show" (leave existing state alone rather than
# thrash it over a transient fetch failure).
ks_collect_domains() {
	ks_any=0
	for f in "$SR_KS_FLAG_DIR"/*.name; do
		[ -e "$f" ] || continue
		profile="$(cat "$f")"
		pf="$SR_PROFILES_DIR/$profile.json"
		[ -f "$pf" ] || continue
		src_type="$(jq -r '.domain_source.type' "$pf")"
		if [ "$src_type" = "custom" ]; then
			list_file="$SR_LISTS_DIR/$(jq -r '.domain_source.file' "$pf")"
			[ -f "$list_file" ] || continue
			grep -v '^#' "$list_file" | grep -v '^$'
		elif [ "$src_type" = "geosite" ]; then
			category="$(jq -r '.domain_source.value' "$pf")"
			resolve_geosite_domains "$category"
		else
			continue
		fi
		ks_any=1
	done
}

ks_rebuild_dnsmasq() {
	mkdir -p "$SR_KS_FLAG_DIR"
	sr_ensure_dirs

	# Without this lock, an interactive enable/disable racing the 1-minute
	# cron watchdog (killswitch.sh reapply, KeeneticOS) can interleave two
	# full rebuild sequences -- confirmed live: each ks_apply_keenetic call
	# flushes its chains before re-adding rules, but two overlapping calls'
	# flush/append steps can interleave, leaving duplicate REDIRECT rules in
	# SR_KS_DNS_REDIRECT (harmless here, since they're identical, but not a
	# guarantee in general and exactly the kind of state this project treats
	# as a real bug elsewhere). Same mkdir-is-atomic mutex pattern as
	# genroute.sh's own regen lock, for the same reason (no flock on this
	# busybox); a lock older than 60s -- comfortably more than one rebuild
	# should ever take -- is treated as abandoned and reclaimed.
	lock_dir="$SR_STATE_DIR/.killswitch.lock"
	if ! mkdir "$lock_dir" 2>/dev/null; then
		lock_age=999999
		[ -d "$lock_dir" ] && lock_age=$(( $(date +%s) - $(date -r "$lock_dir" +%s 2>/dev/null || echo 0) ))
		if [ "$lock_age" -lt 60 ]; then
			sr_log "kill-switch rebuild already in progress, skipping this run"
			return 0
		fi
		sr_log "reclaiming stale kill-switch lock (${lock_age}s old)"
		rm -rf "$lock_dir"
		mkdir "$lock_dir" 2>/dev/null || return 0
	fi
	trap 'rm -rf "$lock_dir"' EXIT INT TERM

	domains_file="$(mktemp)"
	ks_collect_domains > "$domains_file"
	any="$ks_any"
	[ -s "$domains_file" ] || any=0

	if [ "$SR_PLATFORM" = "openwrt" ]; then
		ks_apply_openwrt "$domains_file" "$any"
	else
		ks_apply_keenetic "$domains_file" "$any"
	fi
	rm -f "$domains_file"
	rm -rf "$lock_dir"
	trap - EXIT INT TERM
}

# ks_apply_openwrt: unchanged from the original single-platform
# implementation -- see this file's own top comment for the mechanism.
ks_apply_openwrt() {
	domains_file="$1"; any="$2"

	# Named section (not @ipset[n]) so removing a stale one is a single O(1)
	# `uci delete` by name, same reasoning that replaced the old per-domain
	# del_list churn -- a geosite category can resolve to 100+ domains and
	# each get/del round-trip used to re-parse the whole UCI file.
	uci -q delete dhcp.$DHCP_IPSET_SECTION 2>/dev/null || true

	# dhcp-side `config ipset`: tells dnsmasq's own init script which
	# domains feed the set. It auto-emits either the legacy `ipset=`
	# directive or the modern `nftset=` one into dnsmasq.conf depending on
	# what this build's dnsmasq binary was actually compiled with (see
	# `dnsmasq --version`) -- we don't have to pick between them ourselves.
	if [ "$any" = "1" ]; then
		uci set dhcp.$DHCP_IPSET_SECTION="ipset"
		uci add_list dhcp.$DHCP_IPSET_SECTION.name="$IPSET_NAME"
		sort -u "$domains_file" | while IFS= read -r d; do
			[ -n "$d" ] || continue
			uci add_list dhcp.$DHCP_IPSET_SECTION.domain="$d"
		done
	fi
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

# ks_dnsmasq_up: is the shadow instance (KeeneticOS only) actually running
# right now -- matched by its config path, not just "any dnsmasq", since
# opkg installing dnsmasq-full doesn't start anything on its own and this
# project never runs a second, unrelated dnsmasq instance.
ks_dnsmasq_up() {
	pgrep -f "$KS_DNSMASQ_BIN -C $KS_DNSMASQ_CONF" >/dev/null 2>&1
}

ks_dnsmasq_stop() {
	for p in $(pgrep -f "$KS_DNSMASQ_BIN -C $KS_DNSMASQ_CONF" 2>/dev/null); do
		kill "$p" 2>/dev/null || true
	done
	rm -f "$KS_DNSMASQ_PID"
}

# ks_dnsmasq_start: dnsmasq daemonizes itself by default (no -k/-d here,
# unlike xray or this project's own gateway binary, neither of which can) --
# no HUP-trap/backgrounding dance needed, plain exec is enough. -x writes
# its own pidfile once actually listening, which is what ks_dnsmasq_up
# effectively double-checks via pgrep (belt and braces: -x's pidfile alone
# doesn't prove the process behind that PID is still this dnsmasq and not
# some unrelated process that reused the PID after a crash).
ks_dnsmasq_start() {
	"$KS_DNSMASQ_BIN" -C "$KS_DNSMASQ_CONF" -x "$KS_DNSMASQ_PID" >/dev/null 2>&1 || true
}

# ks_ipset_ensure: dnsmasq's `ipset=` directive (unlike `nftset=`) does NOT
# auto-create the set it names -- confirmed live: querying through a freshly
# (re)started shadow instance against a not-yet-created set resolves the
# domain correctly but silently adds nothing to the set, no error anywhere.
# Must exist before dnsmasq starts, every time.
ks_ipset_ensure() {
	ipset create "$IPSET_NAME" hash:ip -exist
}

ks_apply_keenetic() {
	domains_file="$1"; any="$2"

	if [ "$any" = "1" ]; then
		ks_ipset_ensure
		# no-resolv/no-hosts: this instance's only job is watching queries
		# for kill-switch domains and populating the ipset -- it must not
		# become a second, independently-configured resolver for anything
		# else. server=127.0.0.1 forwards every query on to NDM's own
		# ndnproxy (already bound to :53) so the *answer* a LAN client gets
		# is identical to not having this instance in the path at all --
		# only the ipset side-effect is new.
		#
		# interface=$LAN_DEVICE, not listen-address=127.0.0.1 -- confirmed
		# live this matters: iptables REDIRECT rewrites a packet's
		# destination to the *incoming interface's own address* (here,
		# whatever IP br0 currently has), not to 127.0.0.1, so a LAN
		# client's query arrives addressed to the router's real LAN IP on
		# port $KS_DNS_PORT, not to loopback -- a dnsmasq bound only to
		# 127.0.0.1 never even sees it (silent timeout, no error either
		# side). Binding by interface name instead of a specific IP also
		# means this keeps working if that IP ever changes, same reasoning
		# lib/redirect.sh's own rules use "$LAN_DEVICE" for.
		{
			echo "port=$KS_DNS_PORT"
			echo "no-resolv"
			echo "no-hosts"
			echo "interface=$LAN_DEVICE"
			echo "server=127.0.0.1"
			domain_list="$(sort -u "$domains_file" | tr '\n' '/' | sed 's#/$##')"
			[ -n "$domain_list" ] && echo "ipset=/$domain_list/$IPSET_NAME"
		} > "$KS_DNSMASQ_CONF"

		ks_dnsmasq_stop
		ks_dnsmasq_start

		if ks_dnsmasq_up; then
			ks_ipt_arm_dns_redirect
		else
			# Fail open on the DNS side specifically -- see this file's own
			# top comment for why a dead shadow instance must NOT leave LAN
			# DNS redirected into it (that would blackhole all DNS, not
			# just kill-switch-protected profiles').
			sr_log "ERROR: kill-switch shadow dnsmasq (KeeneticOS) failed to start -- DNS redirect left disarmed, domain->IP watching is NOT active until this is fixed"
			ks_ipt_disarm_dns_redirect
		fi
		ks_ipt_arm_reject
	else
		ks_ipt_disarm_dns_redirect
		ks_ipt_disarm_reject
		ks_dnsmasq_stop
		# Must come after ks_ipt_disarm_reject -- destroying a set an
		# ipt rule still references fails outright.
		ipset destroy "$IPSET_NAME" >/dev/null 2>&1 || true
	fi
}

ks_ipt_arm_dns_redirect() {
	ipt -t nat -N "$IPT_CHAIN_KS_DNS" 2>/dev/null || true
	ipt -t nat -F "$IPT_CHAIN_KS_DNS"
	ipt -t nat -A "$IPT_CHAIN_KS_DNS" -p tcp --dport 53 -j REDIRECT --to-port "$KS_DNS_PORT"
	ipt -t nat -A "$IPT_CHAIN_KS_DNS" -p udp --dport 53 -j REDIRECT --to-port "$KS_DNS_PORT"
	ipt -t nat -D PREROUTING -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_DNS" 2>/dev/null || true
	# Inserted at the top of PREROUTING (not appended), not just hooked --
	# NAT rules are first-match-wins per connection, so if redirect.sh's own
	# dns-protect chain is also active, kill-switch's need to actually see
	# every query for its ipset to mean anything takes priority over the
	# softer leak-protection redirect. Both still land the query at the
	# router either way (this chain's own server=127.0.0.1 forwards on to
	# the same place dns-protect's redirect would have sent it directly),
	# so nothing about dns-protect's own guarantee is weakened by this --
	# it's strictly an extra hop, not a bypass.
	ipt -t nat -I PREROUTING 1 -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_DNS"
}

ks_ipt_disarm_dns_redirect() {
	ipt -t nat -D PREROUTING -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_DNS" 2>/dev/null || true
	ipt -t nat -F "$IPT_CHAIN_KS_DNS" 2>/dev/null || true
	ipt -t nat -X "$IPT_CHAIN_KS_DNS" 2>/dev/null || true
}

ks_ipt_arm_reject() {
	ipt -N "$IPT_CHAIN_KS_REJECT" 2>/dev/null || true
	ipt -F "$IPT_CHAIN_KS_REJECT"
	ipt -A "$IPT_CHAIN_KS_REJECT" -m set --match-set "$IPSET_NAME" dst -j REJECT
	ipt -D FORWARD -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_REJECT" 2>/dev/null || true
	# Inserted at the very top of FORWARD (not appended) -- confirmed live
	# this matters: KeeneticOS's own NDM chains (_NDM_FORWARD,
	# _NDM_SL_FORWARD, ...) already ACCEPT/terminate ordinary LAN->WAN
	# forwarding earlier in the same chain, so an appended rule here never
	# gets evaluated at all for traffic NDM's own rules already let through
	# -- reproduced live: 0 hits on this rule while a direct connection to
	# a watched IP succeeded outright. Same class of first-match-wins
	# ordering issue as the DNS redirect above, just in FORWARD instead of
	# PREROUTING.
	ipt -I FORWARD 1 -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_REJECT"
}

ks_ipt_disarm_reject() {
	ipt -D FORWARD -i "$LAN_DEVICE" -j "$IPT_CHAIN_KS_REJECT" 2>/dev/null || true
	ipt -F "$IPT_CHAIN_KS_REJECT" 2>/dev/null || true
	ipt -X "$IPT_CHAIN_KS_REJECT" 2>/dev/null || true
}

ks_check_dnsmasq_capability() {
	if [ "$SR_PLATFORM" = "openwrt" ]; then
		dnsmasq --version 2>/dev/null | grep -q ' ipset\| nftset' \
			|| sr_die "system dnsmasq lacks ipset/nftset support -- install dnsmasq-full (opkg remove dnsmasq && opkg install dnsmasq-full) to use the hard kill-switch"
	else
		# install.sh installs dnsmasq-full + ipset via Entware's own opkg at
		# install time (mirrors OpenWrt's system-package swap, see its own
		# comment) -- this is a defensive re-check for an install predating
		# that step, not the primary install path. Deliberately does not
		# opkg-install anything itself from what can be an unattended rpcd
		# call -- same reasoning as OpenWrt's branch above, which has always
		# just told the user what to run rather than doing it on their
		# behalf from a toggle click.
		[ -x "$KS_DNSMASQ_BIN" ] && "$KS_DNSMASQ_BIN" --version 2>/dev/null | grep -q ' ipset' \
			|| sr_die "dnsmasq-full (с поддержкой ipset) не установлен -- выполните: opkg install dnsmasq-full ipset / dnsmasq-full (with ipset support) isn't installed -- run: opkg install dnsmasq-full ipset"
		command -v ipset >/dev/null 2>&1 \
			|| sr_die "ipset не установлен -- выполните: opkg install ipset / ipset isn't installed -- run: opkg install ipset"
	fi
}

ks_enable() {
	name="${1:?profile name required}"
	# name becomes a filename below ($SR_KS_FLAG_DIR/$name.name) -- same
	# path-escape guard as lib/genroute.sh's save/delete (a literal "/" is
	# the only thing that can turn this into a path outside the flag dir).
	case "$name" in */*) sr_die "profile name cannot contain '/'" ;; esac
	ks_check_dnsmasq_capability
	mkdir -p "$SR_KS_FLAG_DIR"
	echo "$name" >"$SR_KS_FLAG_DIR/$name.name"
	ks_rebuild_dnsmasq
	sr_log "kill-switch enabled for profile '$name'"
}

ks_disable() {
	name="${1:?profile name required}"
	case "$name" in */*) sr_die "profile name cannot contain '/'" ;; esac
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
	# reapply: re-applies current on-disk enabled-profile state without
	# changing it -- KeeneticOS's boot hook (install.sh's S99 init script)
	# and a 1-minute cron watchdog both call this, mirroring
	# redirect.sh's own reapply verb and for the same reason: KeeneticOS
	# has no equivalent of fw4's "just reloads *.nft on boot/restart" for
	# either the iptables rules here or the shadow dnsmasq process itself,
	# both of which are runtime-only and vanish on reboot or a crash. A
	# no-op on OpenWrt beyond re-running the same idempotent UCI writes
	# (dnsmasq/firewall already survive reboots there on their own).
	reapply) ks_rebuild_dnsmasq ;;
	*) echo "usage: $0 {enable <profile>|disable <profile>|list-enabled|reapply}" >&2; exit 1 ;;
esac
