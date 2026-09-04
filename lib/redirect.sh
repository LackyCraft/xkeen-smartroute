#!/bin/sh
# lib/redirect.sh — the actual LAN traffic capture SmartRoute's domain-based
# routing depends on: without it, every profile/balancer/kill-switch we
# generate is JSON that nothing ever hands real packets to.
#
# xkeen ships its own version of this (port-based inclusion, `xkeen -ap`),
# but on OpenWrt it writes rules through Entware's *legacy* iptables
# (xtables-multi), which is a completely separate ruleset from the one that
# platform's kernel actually consults for packet forwarding on OpenWrt
# 22.03+ (nftables/fw4 by default, via the xtables-nft compat binary).
# `xkeen -ap 443,80` reports success and silently does nothing there --
# confirmed on real hardware: zero fwmark, zero conntrack entries through
# xray's redirect inbound, real devices' traffic flagged as ordinary NAT'd
# forwarding, `mark=0` throughout, even after xkeen itself claims the ports
# were added. rd_write_nft below is what makes SmartRoute (and,
# transitively, xkeen's own domain routing) actually work with real LAN
# devices on plain OpenWrt.
#
# On genuine KeeneticOS (xkeen's native platform) that legacy/nftables split
# doesn't exist -- confirmed live: `iptables -t nat -L PREROUTING` there
# already lists KeeneticOS's own NDM chains (_NDM_DNAT, _NDM_DNS_REDIRECT,
# ...), meaning legacy iptables genuinely is the ruleset the kernel consults
# for real traffic, the same table NDM itself manages. rd_write_iptables
# below targets that directly instead of trying to reach nftables/fw4, which
# don't exist there at all.
#
# fw4 (OpenWrt's nftables front end) loads every *.nft file under
# /etc/nftables.d/ into the `inet fw4` table on every start/reload -- the
# officially supported way to add custom rules that survive reboots and
# `/etc/init.d/firewall restart` without hand-editing fw4's own generated
# ruleset. See /etc/nftables.d/README on the router itself. KeeneticOS has
# no equivalent auto-load-on-boot directory for custom iptables rules, so
# install.sh wires up an Entware init.d hook there instead that just calls
# this script's own `reapply` verb -- see its own comment for why that's
# safe to call unconditionally on every boot.
#
# Usage:
#   redirect.sh enable                 # turn on TCP 80/443 -> xray redirect
#   redirect.sh disable
#   redirect.sh dns-protect on|off      # force LAN DNS(53) through this router
#   redirect.sh ipv6-protect on|off     # drop LAN->WAN IPv6 forwarding
#   redirect.sh quic-protect on|off     # block outbound UDP on the redirected ports
#   redirect.sh status                  # print current flags as JSON
#   redirect.sh reapply                 # re-apply current flags, no state change (boot hook)

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

NFT_FILE="/etc/nftables.d/20-xkeen-smartroute-redirect.nft"
# LAN_DEVICE itself comes from common.sh now (lib/killswitch.sh needs the
# exact same value -- see its own comment there for why this moved).
REDIRECT_PORT=61219
IPT_CHAIN_REDIRECT="SR_SMARTROUTE_REDIRECT"
IPT_CHAIN_QUIC="SR_SMARTROUTE_BLOCK_QUIC"
IPT_CHAIN_DNS="SR_SMARTROUTE_DNS"
IP6T_CHAIN_BLOCK="SR_SMARTROUTE_BLOCK_V6"
FLAG_ENABLED="$SR_STATE_DIR/redirect_enabled"
FLAG_DNS="$SR_STATE_DIR/redirect_dns_protect"
FLAG_IPV6="$SR_STATE_DIR/redirect_ipv6_protect"
FLAG_QUIC="$SR_STATE_DIR/redirect_quic_protect"
FLAG_PORTS="$SR_STATE_DIR/redirect_ports"
# FLAG_LEAK_PROTECT: OFF by default, deliberately opposite of every other
# flag in this file. Confirmed live -- reported directly by a user testing
# on KeeneticOS: with the plain redirect rule active and Xray stopped (a
# deliberate test, but the exact same thing happens on any real Xray
# crash), EVERY LAN device lost internet access entirely, not just
# SmartRoute-routed traffic -- "tcp dport { ports } redirect to :PORT" sends
# matching packets to a port nothing is listening on, and that's true
# equally for a request some profile would have routed and a request that
# was never going through SmartRoute's routing at all. That is a real,
# useful property for someone who explicitly wants "no Xray means no
# internet, period" -- but it was the ONLY behavior available, on by
# definition the moment redirect itself was on, with no way to turn it off
# short of disabling capture entirely (which also turns off every profile's
# routing, not just the fail-safe). rd_write_nft/rd_write_iptables below now
# only emit the actual capture rule at all when Xray is confirmed running OR
# this flag is explicitly on -- Xray down + this off means captured LAN
# traffic just isn't captured for as long as that lasts, i.e. plain direct
# internet access, same as if SmartRoute were never installed, instead of a
# blackout. True per-profile fail-closed (kill-switch specifically, not
# every request) needs its own domain->IP tracking independent of Xray being
# up at all (see lib/killswitch.sh's own header comment) -- a separate,
# larger piece of work; this flag is deliberately scoped to just "should
# ALL redirected traffic keep failing closed while Xray is down," the
# all-or-nothing behavior that already existed, now opt-in instead of
# unconditional.
FLAG_LEAK_PROTECT="$SR_STATE_DIR/redirect_leak_protect"
DEFAULT_PORTS="80,443"

rd_flag() { [ -s "$1" ] && cat "$1" || echo "$2"; }

# rd_xray_up: sr_xray_pids is common.sh's own robust check (matches the full
# command line through the su->exec transition, not just `pgrep -x xray`'s
# exact-name-only match -- see its own comment for why that distinction
# matters here specifically: right after a restart, exactly the boundary
# case this function needs to get right, is when that transition is still
# in flight).
rd_xray_up() { sr_xray_pids >/dev/null 2>&1; }

# rd_write_nft (OpenWrt) regenerates the whole managed .nft file from
# current flags and reloads the firewall. Single function, not incremental
# edits -- same reasoning as genroute.sh's sr_regen: the file is small,
# always fully regenerated, so there's no drift between what's on disk and
# what the flags say should be there.
rd_write_nft() {
	sr_ensure_dirs
	enabled="$(rd_flag "$FLAG_ENABLED" "0")"
	dns_protect="$(rd_flag "$FLAG_DNS" "0")"
	ipv6_protect="$(rd_flag "$FLAG_IPV6" "0")"
	quic_protect="$(rd_flag "$FLAG_QUIC" "0")"
	leak_protect="$(rd_flag "$FLAG_LEAK_PROTECT" "0")"
	ports="$(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS")"
	tcp_ports="$(printf '%s' "$ports" | tr ',' ' ')"
	# See FLAG_LEAK_PROTECT's own comment. capture_active=0 means: still
	# exclude private ranges (harmless, no reason to stop that), but omit
	# the actual "redirect to :PORT" line below -- a chain a packet falls
	# through with no matching rule just continues normal NAT/forwarding
	# unchanged, exactly the "behave as if SmartRoute weren't installed"
	# fallback this is for.
	capture_active=1
	rd_xray_up || [ "$leak_protect" = "1" ] || capture_active=0

	# Back up whatever was already live before overwriting it in place --
	# fw4 check (below) validates the *whole* /etc/nftables.d/ directory
	# together, not one isolated file, so there's no way to test the new
	# content without it actually being at $NFT_FILE first. Confirmed this
	# used to just delete $NFT_FILE outright on a failed check, despite the
	# log line right below claiming "leaving the previous firewall state
	# untouched" -- deleting it is not that: a previously-working redirect/
	# leak-protection config is gone until the next successful toggle,
	# silently, rather than staying armed.
	had_previous=0
	if [ -f "$NFT_FILE" ]; then
		cp "$NFT_FILE" "$NFT_FILE.bak"
		had_previous=1
	fi

	{
		echo "## Managed by XKeen SmartRoute (lib/redirect.sh) -- do not edit by hand,"
		echo "## changes get overwritten on the next enable/disable/regen."
		echo "## See lib/redirect.sh for why this exists instead of xkeen -ap."
		echo

		if [ "$enabled" = "1" ]; then
			echo "chain sr_smartroute_redirect {"
			echo "	type nat hook prerouting priority dstnat; policy accept;"
			echo
			echo "	# Only traffic actually coming from LAN devices, and never traffic"
			echo "	# headed for private/local address space -- redirecting LAN-to-LAN"
			echo "	# or LAN-to-router traffic through xray would just break it for no"
			echo "	# reason (xray has no route back to those destinations)."
			echo "	iifname != \"$LAN_DEVICE\" return"
			echo "	ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } return"
			echo

			if [ "$dns_protect" = "1" ]; then
				echo "	# DNS leak protection: force every LAN DNS query through this"
				echo "	# router's own dnsmasq, regardless of what server the client asked"
				echo "	# for -- a device hardcoded to 8.8.8.8 (or anything else) gets"
				echo "	# transparently redirected back to 127.0.0.1:53 instead. This is"
				echo "	# also what makes the kill-switch's dnsmasq-ipset mechanism"
				echo "	# (lib/killswitch.sh) actually see every query in the first place;"
				echo "	# without it, a client bypassing this router's DNS never populates"
				echo "	# the ipset kill-switch blocks on."
				echo "	tcp dport 53 redirect to :53"
				echo "	udp dport 53 redirect to :53"
				echo
			fi

			if [ -n "$tcp_ports" ] && [ "$capture_active" = "1" ]; then
				port_list="$(printf '%s' "$ports")"
				echo "	# Sniffed at the TLS/HTTP/QUIC layer by xray's own \"redirect\""
				echo "	# inbound (03_inbounds.json, destOverride) to recover the real"
				echo "	# domain regardless of how the client resolved the IP -- routing"
				echo "	# decisions don't depend on DNS having gone through the tunnel."
				echo "	tcp dport { $port_list } redirect to :$REDIRECT_PORT"
			elif [ -n "$tcp_ports" ]; then
				echo "	# Xray isn't running and \"fail closed for all redirected traffic\""
				echo "	# (leak-protect) is off -- see lib/redirect.sh's FLAG_LEAK_PROTECT"
				echo "	# comment. Deliberately no redirect rule here right now: falling"
				echo "	# through this chain with nothing matched means normal NAT/"
				echo "	# forwarding proceeds unchanged, i.e. plain direct internet access"
				echo "	# instead of every LAN device losing it. Re-synced automatically"
				echo "	# (via \`redirect.sh reapply\`) whenever Xray starts/stops/restarts,"
				echo "	# and by a periodic cron check for the rarer case of Xray dying"
				echo "	# completely unmanaged."
			fi
			echo "}"
		fi

		if [ "$ipv6_protect" = "1" ]; then
			echo
			echo "chain sr_smartroute_block_ipv6 {"
			echo "	type filter hook forward priority -1; policy accept;"
			echo
			echo "	# IPv6 leak protection: xray's redirect inbound above is IPv4-only,"
			echo "	# so without this, any IPv6-capable site would just reach a LAN"
			echo "	# client directly over WAN, invisible to every profile/kill-switch"
			echo "	# rule SmartRoute generates -- the classic \"VPN kill switch doesn't"
			echo "	# cover IPv6\" leak. Simplest reliable fix: don't let LAN->WAN IPv6"
			echo "	# forward at all, so those connections fail closed and fall back to"
			echo "	# IPv4 (which *is* covered) instead of leaking directly."
			echo "	iifname \"$LAN_DEVICE\" meta nfproto ipv6 counter drop"
			echo "}"
		fi

		if [ "$quic_protect" = "1" ] && [ -n "$ports" ]; then
			echo
			echo "chain sr_smartroute_block_quic {"
			echo "	type filter hook forward priority -1; policy accept;"
			echo
			echo "	# QUIC/HTTP3 leak protection: our redirect above only catches TCP"
			echo "	# (\"tcp dport { ... } redirect\") -- a site that advertises HTTP/3"
			echo "	# support (Alt-Svc: h3=\":443\") gets requested over QUIC, which runs"
			echo "	# on the *same* port number but over UDP, invisible to a TCP-only"
			echo "	# redirect and never reaching xray at all. Confirmed for real:"
			echo "	# 2ip.ru (advertises h3) never showed up in xray's access log despite"
			echo "	# loading fine in Safari -- it went out directly over UDP/443,"
			echo "	# leaking the real IP. Browsers fall back to plain TCP/TLS cleanly"
			echo "	# when the UDP attempt just doesn't get a response, so blocking it"
			echo "	# outright (rather than trying to redirect UDP into xray, which the"
			echo "	# redirect inbound isn't set up to speak) is the safe fix -- same"
			echo "	# ports as the TCP redirect, so it only touches traffic that would"
			echo "	# otherwise have bypassed it."
			echo "	iifname \"$LAN_DEVICE\" udp dport { $ports } counter drop"
			echo "}"
		fi
	} > "$NFT_FILE"

	if command -v fw4 >/dev/null 2>&1 && ! fw4 check >/dev/null 2>&1; then
		sr_log "ERROR: generated nftables redirect rules failed fw4's syntax check, restoring the previous firewall state"
		if [ "$had_previous" = "1" ]; then
			mv "$NFT_FILE.bak" "$NFT_FILE"
		else
			rm -f "$NFT_FILE"
		fi
		return 1
	fi
	rm -f "$NFT_FILE.bak"

	/etc/init.d/firewall reload >/dev/null 2>&1 || /sbin/fw4 reload >/dev/null 2>&1 || true
}

# ipt/ip6t: every KeeneticOS iptables/ip6tables call in this file goes
# through these instead of the bare binary. redirect.sh reapply now runs
# from cron every single minute (install.sh's CRON_REDIRECT_SYNC, added
# alongside FLAG_LEAK_PROTECT), on top of every interactive toggle and
# every sr_restart_xray/stop/start hook already calling rd_write -- so two
# invocations of rd_write_iptables racing each other for the legacy
# xtables lock is a real, observed case now (confirmed live: a plain
# `quic-protect off` hit "Another app is currently holding the xtables
# lock" from exactly this race), not a theoretical one. Under `set -eu` an
# unhandled lock failure aborts rd_write_iptables mid-rebuild, potentially
# leaving a chain flushed but not yet repopulated. This build's iptables
# (v1.4.21) only supports the bare `-w` (no numeric timeout, confirmed
# live: `-w 5` itself errors out) -- it blocks until the lock is free
# rather than failing outright, which is exactly what's wanted here; a
# real hold is measured in milliseconds, so blocking is never a
# perceptible delay in practice.
ipt() { iptables -w "$@"; }
ip6t() { ip6tables -w "$@"; }

# ipt_chain_reset: (re)create a chain empty, in either table -- idempotent,
# safe whether the chain already exists (from a previous enable) or not.
# `-N` fails harmlessly if it's already there; `-F` then guarantees empty
# regardless of which branch ran, so every call below is a fresh rebuild,
# same "always fully regenerated, never incrementally patched" reasoning as
# rd_write_nft's own comment.
ipt_chain_reset() {
	table_flag="$1"; chain="$2"
	if [ "$table_flag" = "nat" ]; then
		ipt -t nat -N "$chain" 2>/dev/null || true
		ipt -t nat -F "$chain"
	else
		ipt -N "$chain" 2>/dev/null || true
		ipt -F "$chain"
	fi
}

# ipt_hook: make sure exactly one jump to $chain exists in $hook_chain for
# packets arriving on $LAN_DEVICE -- delete-then-append instead of a
# check-then-maybe-append, so re-running this can't ever leave two copies of
# the same jump stacked up (confirmed live this matters: an early version
# without the delete step left a duplicate PREROUTING jump after a second
# `enable` call, which still worked but meant every matching packet paid
# for two chain traversals instead of one).
ipt_hook() {
	table_flag="$1"; hook_chain="$2"; chain="$3"
	if [ "$table_flag" = "nat" ]; then
		ipt -t nat -D "$hook_chain" -i "$LAN_DEVICE" -j "$chain" 2>/dev/null || true
		ipt -t nat -A "$hook_chain" -i "$LAN_DEVICE" -j "$chain"
	else
		ipt -D "$hook_chain" -i "$LAN_DEVICE" -j "$chain" 2>/dev/null || true
		ipt -A "$hook_chain" -i "$LAN_DEVICE" -j "$chain"
	fi
}

# ipt_unhook/ipt_chain_delete: the disable-side inverse of the two helpers
# above -- remove the jump first (a chain still referenced by a jump can't
# be deleted), then the now-unreferenced chain itself. `-X` on a chain that
# was never created is a harmless no-op error, same reasoning as the `||
# true` guards throughout.
ipt_unhook() {
	table_flag="$1"; hook_chain="$2"; chain="$3"
	if [ "$table_flag" = "nat" ]; then
		ipt -t nat -D "$hook_chain" -i "$LAN_DEVICE" -j "$chain" 2>/dev/null || true
	else
		ipt -D "$hook_chain" -i "$LAN_DEVICE" -j "$chain" 2>/dev/null || true
	fi
}
ipt_chain_delete() {
	table_flag="$1"; chain="$2"
	if [ "$table_flag" = "nat" ]; then
		ipt -t nat -F "$chain" 2>/dev/null || true
		ipt -t nat -X "$chain" 2>/dev/null || true
	else
		ipt -F "$chain" 2>/dev/null || true
		ipt -X "$chain" 2>/dev/null || true
	fi
}

# rd_write_iptables (KeeneticOS): same four toggles as rd_write_nft, same
# "always fully regenerated from the flag files, never incrementally
# patched" contract, but against legacy iptables/ip6tables instead of an
# nftables.d file -- see this file's own top-of-file comment for why that's
# the right target here (KeeneticOS's own NDM firewall management already
# lives in that exact table). Four dedicated chains (redirect/quic/dns in
# the "nat"/"filter" tables, one in ip6tables) instead of one, since
# iptables -- unlike the nft version's single managed file -- has no single
# atomic "replace this whole named block" operation; each toggle owns and
# rebuilds only its own chain, independent of the others.
rd_write_iptables() {
	sr_ensure_dirs
	enabled="$(rd_flag "$FLAG_ENABLED" "0")"
	dns_protect="$(rd_flag "$FLAG_DNS" "0")"
	ipv6_protect="$(rd_flag "$FLAG_IPV6" "0")"
	quic_protect="$(rd_flag "$FLAG_QUIC" "0")"
	leak_protect="$(rd_flag "$FLAG_LEAK_PROTECT" "0")"
	ports="$(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS")"
	# See FLAG_LEAK_PROTECT's own comment / rd_write_nft's identical check.
	capture_active=1
	rd_xray_up || [ "$leak_protect" = "1" ] || capture_active=0

	if [ "$enabled" = "1" ]; then
		ipt_chain_reset nat "$IPT_CHAIN_REDIRECT"
		# Same private/local exclusion as rd_write_nft's own -- redirecting
		# LAN-to-LAN or LAN-to-router traffic through xray would just break
		# it for no reason (xray has no route back to those destinations).
		ipt -t nat -A "$IPT_CHAIN_REDIRECT" -d 10.0.0.0/8 -j RETURN
		ipt -t nat -A "$IPT_CHAIN_REDIRECT" -d 172.16.0.0/12 -j RETURN
		ipt -t nat -A "$IPT_CHAIN_REDIRECT" -d 192.168.0.0/16 -j RETURN
		ipt -t nat -A "$IPT_CHAIN_REDIRECT" -d 127.0.0.0/8 -j RETURN
		if [ -n "$ports" ] && [ "$capture_active" = "1" ]; then
			# One rule per port, not `-m multiport --dports` -- confirmed
			# live on KeeneticOS: the xt_multiport match errors out
			# ("No chain/target/match by that name"), this kernel doesn't
			# have it built in and there's no modprobe to load it on
			# demand either. Plain single-port `--dport` and the REDIRECT
			# target itself both work fine individually, confirmed the
			# same way -- so just loop instead of depending on multiport.
			old_ifs="$IFS"; IFS=','
			for p in $ports; do
				ipt -t nat -A "$IPT_CHAIN_REDIRECT" -p tcp --dport "$p" -j REDIRECT --to-port "$REDIRECT_PORT"
			done
			IFS="$old_ifs"
		fi
		# capture_active=0: chain still exists (excludes above, harmless)
		# but with no REDIRECT rule -- a packet that reaches the end of a
		# jumped-to chain with nothing matched just returns to PREROUTING
		# and continues normal NAT/forwarding, same "acts like SmartRoute
		# isn't installed" fallback as rd_write_nft's own comment.
		ipt_hook nat PREROUTING "$IPT_CHAIN_REDIRECT"

		if [ "$dns_protect" = "1" ]; then
			# Same reasoning as rd_write_nft's dns-protect: force every LAN
			# DNS query through this router's own resolver regardless of
			# what server the client asked for, both to close the leak and
			# because kill-switch's dnsmasq-ipset mechanism needs to see
			# every query to populate its ipset in the first place.
			ipt_chain_reset nat "$IPT_CHAIN_DNS"
			ipt -t nat -A "$IPT_CHAIN_DNS" -p tcp --dport 53 -j REDIRECT --to-port 53
			ipt -t nat -A "$IPT_CHAIN_DNS" -p udp --dport 53 -j REDIRECT --to-port 53
			ipt_hook nat PREROUTING "$IPT_CHAIN_DNS"
		else
			ipt_unhook nat PREROUTING "$IPT_CHAIN_DNS"
			ipt_chain_delete nat "$IPT_CHAIN_DNS"
		fi

		if [ "$quic_protect" = "1" ] && [ -n "$ports" ]; then
			# Same reasoning as rd_write_nft's quic-protect -- see its own
			# comment (2ip.ru/h3 leak) for why this is needed at all.
			ipt_chain_reset filter "$IPT_CHAIN_QUIC"
			# Same multiport-unavailable reasoning as the redirect rule
			# above -- one rule per port instead.
			old_ifs="$IFS"; IFS=','
			for p in $ports; do
				ipt -A "$IPT_CHAIN_QUIC" -p udp --dport "$p" -j DROP
			done
			IFS="$old_ifs"
			ipt_hook filter FORWARD "$IPT_CHAIN_QUIC"
		else
			ipt_unhook filter FORWARD "$IPT_CHAIN_QUIC"
			ipt_chain_delete filter "$IPT_CHAIN_QUIC"
		fi
	else
		ipt_unhook nat PREROUTING "$IPT_CHAIN_REDIRECT"
		ipt_chain_delete nat "$IPT_CHAIN_REDIRECT"
		ipt_unhook nat PREROUTING "$IPT_CHAIN_DNS"
		ipt_chain_delete nat "$IPT_CHAIN_DNS"
		ipt_unhook filter FORWARD "$IPT_CHAIN_QUIC"
		ipt_chain_delete filter "$IPT_CHAIN_QUIC"
	fi

	if [ "$ipv6_protect" = "1" ]; then
		# Same reasoning as rd_write_nft's ipv6-protect: the redirect chain
		# above is IPv4-only, so without this, any IPv6-capable site would
		# just reach a LAN client directly over WAN -- the classic "kill
		# switch doesn't cover IPv6" leak. ip6tables, not iptables -- a
		# completely separate ruleset/binary on this platform too.
		if command -v ip6tables >/dev/null 2>&1; then
			ip6t -N "$IP6T_CHAIN_BLOCK" 2>/dev/null || true
			ip6t -F "$IP6T_CHAIN_BLOCK"
			ip6t -A "$IP6T_CHAIN_BLOCK" -j DROP
			ip6t -D FORWARD -i "$LAN_DEVICE" -j "$IP6T_CHAIN_BLOCK" 2>/dev/null || true
			ip6t -A FORWARD -i "$LAN_DEVICE" -j "$IP6T_CHAIN_BLOCK"
		fi
	elif command -v ip6tables >/dev/null 2>&1; then
		ip6t -D FORWARD -i "$LAN_DEVICE" -j "$IP6T_CHAIN_BLOCK" 2>/dev/null || true
		ip6t -F "$IP6T_CHAIN_BLOCK" 2>/dev/null || true
		ip6t -X "$IP6T_CHAIN_BLOCK" 2>/dev/null || true
	fi
}

rd_write() {
	if [ "$SR_PLATFORM" = "openwrt" ]; then
		rd_write_nft
	else
		rd_write_iptables
	fi
}

rd_enable() {
	sr_ensure_dirs
	echo 1 > "$FLAG_ENABLED"
	rd_write
	sr_log "LAN traffic redirect enabled (ports: $(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS"))"
}

rd_disable() {
	sr_ensure_dirs
	echo 0 > "$FLAG_ENABLED"
	rd_write
	sr_log "LAN traffic redirect disabled"
}

rd_set_ports() {
	sr_ensure_dirs
	ports="${1:?comma-separated port list required}"
	case "$ports" in *[!0-9,]*) sr_die "ports must be a comma-separated list of numbers (got: $ports)" ;; esac
	echo "$ports" > "$FLAG_PORTS"
	rd_write
	sr_log "redirect ports set to $ports"
}

rd_dns_protect() {
	sr_ensure_dirs
	case "${1:-}" in on) echo 1 > "$FLAG_DNS" ;; off) echo 0 > "$FLAG_DNS" ;; *) sr_die "usage: dns-protect on|off" ;; esac
	rd_write
	sr_log "DNS leak protection: ${1}"
}

rd_ipv6_protect() {
	sr_ensure_dirs
	case "${1:-}" in on) echo 1 > "$FLAG_IPV6" ;; off) echo 0 > "$FLAG_IPV6" ;; *) sr_die "usage: ipv6-protect on|off" ;; esac
	rd_write
	sr_log "IPv6 leak protection: ${1}"
}

rd_quic_protect() {
	sr_ensure_dirs
	case "${1:-}" in on) echo 1 > "$FLAG_QUIC" ;; off) echo 0 > "$FLAG_QUIC" ;; *) sr_die "usage: quic-protect on|off" ;; esac
	rd_write
	sr_log "QUIC/HTTP3 leak protection: ${1}"
}

rd_leak_protect() {
	sr_ensure_dirs
	case "${1:-}" in on) echo 1 > "$FLAG_LEAK_PROTECT" ;; off) echo 0 > "$FLAG_LEAK_PROTECT" ;; *) sr_die "usage: leak-protect on|off" ;; esac
	rd_write
	sr_log "Fail-closed on Xray down (leak protection): ${1}"
}

rd_status() {
	# "supported" used to be forced false on KeeneticOS, back when
	# rd_write_iptables didn't exist yet and every mutating action refused
	# outright (confirmed live at the time: rd_enable wrote the "enabled"
	# flag and logged success while the actual nftables-only write failed
	# partway through, `set -eu` not catching it early enough -- a stale "1"
	# that genuinely meant nothing). Both platforms have a real backend now
	# (rd_write_nft / rd_write_iptables), so this just reports the flags as
	# they are everywhere.
	#
	# "capture_active" reports whether the redirect rule is *actually*
	# sending traffic into Xray right now, as opposed to "enabled" (the
	# user's own on/off intent) -- these two genuinely differ whenever Xray
	# is down and leak_protect is off (see FLAG_LEAK_PROTECT's own comment):
	# "enabled" stays true (the user never turned redirect off), but nothing
	# is actually being captured right now. The panel surfaces this so it
	# can show something like "перехват временно приостановлен -- Xray не
	# отвечает" instead of just "enabled: true" while traffic is quietly
	# going direct.
	enabled="$(rd_flag "$FLAG_ENABLED" "0")"
	capture_active=1
	rd_xray_up || [ "$(rd_flag "$FLAG_LEAK_PROTECT" "0")" = "1" ] || capture_active=0
	xray_up=0
	rd_xray_up && xray_up=1
	jq -n \
		--argjson enabled "$enabled" \
		--argjson dns_protect "$(rd_flag "$FLAG_DNS" "0")" \
		--argjson ipv6_protect "$(rd_flag "$FLAG_IPV6" "0")" \
		--argjson quic_protect "$(rd_flag "$FLAG_QUIC" "0")" \
		--argjson leak_protect "$(rd_flag "$FLAG_LEAK_PROTECT" "0")" \
		--argjson xray_up "$xray_up" \
		--argjson capture_active "$([ "$enabled" = "1" ] && [ "$capture_active" = "1" ] && echo 1 || echo 0)" \
		--arg ports "$(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS")" \
		'{enabled: (($enabled|tostring)=="1"), dns_protect: (($dns_protect|tostring)=="1"), ipv6_protect: (($ipv6_protect|tostring)=="1"), quic_protect: (($quic_protect|tostring)=="1"), leak_protect: (($leak_protect|tostring)=="1"), xray_up: (($xray_up|tostring)=="1"), capture_active: (($capture_active|tostring)=="1"), ports: $ports, supported: true}'
}

case "${1:-}" in
	enable) rd_enable ;;
	disable) rd_disable ;;
	set-ports) rd_set_ports "${2:-}" ;;
	dns-protect) rd_dns_protect "${2:-}" ;;
	ipv6-protect) rd_ipv6_protect "${2:-}" ;;
	quic-protect) rd_quic_protect "${2:-}" ;;
	leak-protect) rd_leak_protect "${2:-}" ;;
	status) rd_status ;;
	# Re-applies the current on-disk flags without changing any of them --
	# the boot-time hook install.sh wires up on KeeneticOS (no fw4-style
	# auto-load-on-boot directory there, see this file's top-of-file
	# comment) calls this instead of "enable", since a router that
	# rebooted with redirect *disabled* must come back up disabled too, not
	# have this hook silently turn it on. Also the same verb common.sh's
	# xray start/stop/restart functions call afterward (success or failure)
	# to resync the capture rule with Xray's actual just-changed state, and
	# what a periodic cron entry calls to catch an unmanaged crash within a
	# bounded time -- see FLAG_LEAK_PROTECT's own comment.
	reapply) rd_write ;;
	*) echo "usage: $0 {enable|disable|set-ports <csv>|dns-protect on|off|ipv6-protect on|off|quic-protect on|off|leak-protect on|off|status|reapply}" >&2; exit 1 ;;
esac
