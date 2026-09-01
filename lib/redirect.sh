#!/bin/sh
# lib/redirect.sh — the actual LAN traffic capture SmartRoute's domain-based
# routing depends on: without it, every profile/balancer/kill-switch we
# generate is JSON that nothing ever hands real packets to.
#
# xkeen ships its own version of this (port-based inclusion, `xkeen -ap`),
# but it writes rules through Entware's *legacy* iptables (xtables-multi),
# which is a completely separate ruleset from the one this router's kernel
# actually consults for packet forwarding on OpenWrt 21.02+ (nftables/fw4 by
# default, via the xtables-nft compat binary). `xkeen -ap 443,80` reports
# success and silently does nothing -- confirmed on real hardware: zero
# fwmark, zero conntrack entries through xray's redirect inbound, real
# devices' traffic flagged as ordinary NAT'd forwarding, `mark=0` throughout,
# even after xkeen itself claims the ports were added. On genuine KeeneticOS
# (xkeen's native platform) this legacy/nftables split doesn't exist -- this
# file is what makes SmartRoute (and, transitively, xkeen's own domain
# routing) actually work with real LAN devices on plain OpenWrt.
#
# fw4 (OpenWrt's nftables front end) loads every *.nft file under
# /etc/nftables.d/ into the `inet fw4` table on every start/reload -- the
# officially supported way to add custom rules that survive reboots and
# `/etc/init.d/firewall restart` without hand-editing fw4's own generated
# ruleset. See /etc/nftables.d/README on the router itself.
#
# Usage:
#   redirect.sh enable                 # turn on TCP 80/443 -> xray redirect
#   redirect.sh disable
#   redirect.sh dns-protect on|off      # force LAN DNS(53) through this router
#   redirect.sh ipv6-protect on|off     # drop LAN->WAN IPv6 forwarding
#   redirect.sh quic-protect on|off     # block outbound UDP on the redirected ports
#   redirect.sh status                  # print current flags as JSON

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

NFT_FILE="/etc/nftables.d/20-xkeen-smartroute-redirect.nft"
LAN_DEVICE="$(uci get network.lan.device 2>/dev/null || echo br-lan)"
REDIRECT_PORT=61219
FLAG_ENABLED="$SR_STATE_DIR/redirect_enabled"
FLAG_DNS="$SR_STATE_DIR/redirect_dns_protect"
FLAG_IPV6="$SR_STATE_DIR/redirect_ipv6_protect"
FLAG_QUIC="$SR_STATE_DIR/redirect_quic_protect"
FLAG_PORTS="$SR_STATE_DIR/redirect_ports"
DEFAULT_PORTS="80,443"

rd_flag() { [ -s "$1" ] && cat "$1" || echo "$2"; }

# rd_write regenerates the whole managed .nft file from current flags and
# reloads the firewall. Single function, not incremental edits -- same
# reasoning as genroute.sh's sr_regen: the file is small, always fully
# regenerated, so there's no drift between what's on disk and what the flags
# say should be there.
rd_write() {
	sr_ensure_dirs
	enabled="$(rd_flag "$FLAG_ENABLED" "0")"
	dns_protect="$(rd_flag "$FLAG_DNS" "0")"
	ipv6_protect="$(rd_flag "$FLAG_IPV6" "0")"
	quic_protect="$(rd_flag "$FLAG_QUIC" "0")"
	ports="$(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS")"
	tcp_ports="$(printf '%s' "$ports" | tr ',' ' ')"

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

			if [ -n "$tcp_ports" ]; then
				port_list="$(printf '%s' "$ports")"
				echo "	# Sniffed at the TLS/HTTP/QUIC layer by xray's own \"redirect\""
				echo "	# inbound (03_inbounds.json, destOverride) to recover the real"
				echo "	# domain regardless of how the client resolved the IP -- routing"
				echo "	# decisions don't depend on DNS having gone through the tunnel."
				echo "	tcp dport { $port_list } redirect to :$REDIRECT_PORT"
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

rd_status() {
	# "supported" lets the panel/LuCI UI show this feature as genuinely
	# unavailable on KeeneticOS instead of a toggle that looks like every
	# other one but silently does nothing when flipped. "enabled" is forced
	# false there regardless of $FLAG_ENABLED's on-disk value -- confirmed
	# live this flag can already be stuck at "1" from before this platform
	# check existed (rd_enable used to write it, then fail past that point
	# once it hit the first OpenWrt-only command, with set -eu never
	# reverting the flag it had already written): reporting that stale "1"
	# back as "enabled": true would just be a second copy of the same lie.
	if [ "$SR_PLATFORM" != "openwrt" ]; then
		jq -n '{enabled: false, dns_protect: false, ipv6_protect: false, quic_protect: false, ports: "80,443", supported: false}'
		return 0
	fi
	jq -n \
		--argjson enabled "$(rd_flag "$FLAG_ENABLED" "0")" \
		--argjson dns_protect "$(rd_flag "$FLAG_DNS" "0")" \
		--argjson ipv6_protect "$(rd_flag "$FLAG_IPV6" "0")" \
		--argjson quic_protect "$(rd_flag "$FLAG_QUIC" "0")" \
		--arg ports "$(rd_flag "$FLAG_PORTS" "$DEFAULT_PORTS")" \
		'{enabled: (($enabled|tostring)=="1"), dns_protect: (($dns_protect|tostring)=="1"), ipv6_protect: (($ipv6_protect|tostring)=="1"), quic_protect: (($quic_protect|tostring)=="1"), ports: $ports, supported: true}'
}

# Every mutating action below (enable/disable/set-ports/*-protect) depends
# on fw4/nftables.d, which only exists on OpenWrt -- confirmed live on
# KeeneticOS: rd_enable used to report success and log "LAN traffic redirect
# enabled" while never actually writing a working rule, because `set -eu`
# didn't stop it early enough (the flag file write and several early steps
# all succeed before the first OpenWrt-only command actually fails). `status`
# stays available everywhere (see the "supported" field above) so the panel
# can always ask, but every action that would change real firewall state is
# refused outright here instead of silently doing nothing.
if [ "$SR_PLATFORM" != "openwrt" ] && [ "${1:-}" != "status" ]; then
	sr_die "прозрачный редирект трафика (LAN -> Xray) пока поддержан только на OpenWrt -- на KeeneticOS нет аналога fw4/nftables.d, на котором построен этот механизм. / transparent LAN traffic redirect is OpenWrt-only for now -- KeeneticOS has no fw4/nftables.d equivalent this relies on."
fi

case "${1:-}" in
	enable) rd_enable ;;
	disable) rd_disable ;;
	set-ports) rd_set_ports "${2:-}" ;;
	dns-protect) rd_dns_protect "${2:-}" ;;
	ipv6-protect) rd_ipv6_protect "${2:-}" ;;
	quic-protect) rd_quic_protect "${2:-}" ;;
	status) rd_status ;;
	*) echo "usage: $0 {enable|disable|set-ports <csv>|dns-protect on|off|ipv6-protect on|off|quic-protect on|off|status}" >&2; exit 1 ;;
esac
