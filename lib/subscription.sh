#!/bin/sh
# lib/subscription.sh — fetch a VLESS/Trojan subscription link (base64 blob of
# vless://... / trojan://... URIs, the common V2rayNG/V2Box format) and turn
# it into an Xray outbounds fragment that xkeen picks up.
#
# Usage:
#   subscription.sh import <url> [label]   # fetch + write outbounds + servers.json
#   subscription.sh list                    # print servers.json (for the UI)
#
# Requires: curl, jq, sed, base64 (all present once Entware is installed).

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

urldecode() {
	# percent-decode + turn '+' into space, POSIX-portable (no bash-isms)
	printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')"
}

qval() {
	# qval <query-string> <key>  -> raw (still percent-encoded) value or ""
	printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -n1
}

slugify() {
	printf '%s' "$1" | tr -cs 'A-Za-z0-9' '_' | tr 'A-Z' 'a-z' | sed 's/^_*//; s/_*$//'
	[ -n "$1" ] || printf 'server'
}

build_outbound() {
	# $1=proto $2=id/password $3=host $4=port $5=query(raw, still % encoded) $6=fragment(decoded) $7=tag
	proto="$1"; secret="$2"; host="$3"; port="$4"; query="$5"; tag="$7"

	security="$(qval "$query" security)"; security="${security:-none}"
	net="$(qval "$query" type)"; net="${net:-tcp}"
	sni_raw="$(qval "$query" sni)"; sni="$(urldecode "${sni_raw:-$host}")"
	fp="$(urldecode "$(qval "$query" fp)")"
	pbk="$(qval "$query" pbk)"
	sid="$(qval "$query" sid)"
	spx="$(urldecode "$(qval "$query" spx)")"
	alpn="$(urldecode "$(qval "$query" alpn)")"
	path="$(urldecode "$(qval "$query" path)")"; [ -n "$path" ] || path="/"
	hosthdr="$(urldecode "$(qval "$query" host)")"
	mode="$(qval "$query" mode)"; mode="${mode:-auto}"
	flow="$(qval "$query" flow)"
	svcname="$(urldecode "$(qval "$query" serviceName)")"
	extra_raw="$(urldecode "$(qval "$query" extra)")"
	extra_json="$(printf '%s' "$extra_raw" | jq -c '.' 2>/dev/null || echo '{}')"

	jq -n \
		--arg tag "$tag" --arg proto "$proto" --arg address "$host" --argjson port "$port" \
		--arg id "$secret" --arg net "$net" --arg security "$security" --arg sni "$sni" \
		--arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --arg spx "$spx" --arg alpn "$alpn" \
		--arg path "$path" --arg hosthdr "$hosthdr" --arg mode "$mode" --arg flow "$flow" \
		--arg svcname "$svcname" --argjson extra "$extra_json" '
		def alpnArr: if $alpn=="" then null else ($alpn|split(",")) end;
		{
			tag: $tag,
			protocol: $proto,
			settings: (
				if $proto=="vless" then
					{vnext: [{address:$address, port:$port, users:[{id:$id, encryption:"none", flow:$flow}]}]}
				else
					{servers: [{address:$address, port:$port, password:$id}]}
				end
			),
			streamSettings: (
				{network: $net}
				+ (if $security=="tls" then
					{security:"tls", tlsSettings: ({serverName:$sni} + (if $fp!="" then {fingerprint:$fp} else {} end) + (if alpnArr then {alpn:alpnArr} else {} end))}
				elif $security=="reality" then
					{security:"reality", realitySettings: ({serverName:$sni, publicKey:$pbk} + (if $fp!="" then {fingerprint:$fp} else {} end) + (if $sid!="" then {shortId:$sid} else {} end) + (if $spx!="" then {spiderX:$spx} else {} end))}
				else {security:"none"} end)
				+ (if $net=="ws" then {wsSettings: ({path:$path} + (if $hosthdr!="" then {headers:{Host:$hosthdr}} else {} end))}
				elif $net=="grpc" then {grpcSettings: {serviceName:$svcname}}
				elif $net=="xhttp" or $net=="splithttp" then {xhttpSettings: ({path:$path, host:$hosthdr, mode:$mode} + $extra)}
				else {} end)
			)
		}'
}

sr_import() {
	url="$1"; label="${2:-sub}"
	sr_require curl; sr_require jq
	sr_ensure_dirs

	raw="$(curl -fsSL --max-time 20 "$url")" || sr_die "failed to fetch subscription: $url"
	decoded="$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)"
	case "$decoded" in
		*"://"*) body="$decoded" ;;
		*) body="$raw" ;;
	esac

	tmp_outbounds="$(mktemp)"
	tmp_servers="$(mktemp)"
	echo '[]' >"$tmp_outbounds"
	echo '[]' >"$tmp_servers"

	label_slug="$(slugify "$label")"
	i=0
	skipped=0
	echo "$body" | while IFS= read -r line || [ -n "$line" ]; do
		line="$(printf '%s' "$line" | tr -d '\r')"
		[ -n "$line" ] || continue
		case "$line" in
			vless://*) proto=vless ;;
			trojan://*) proto=trojan ;;
			*) skipped=$((skipped + 1)); continue ;;
		esac

		rest="${line#*://}"
		case "$rest" in
			*"#"*) frag_raw="${rest#*#}"; rest_nofrag="${rest%%#*}" ;;
			*) frag_raw=""; rest_nofrag="$rest" ;;
		esac
		case "$rest_nofrag" in
			*"?"*) query="${rest_nofrag#*\?}"; userhostport="${rest_nofrag%%\?*}" ;;
			*) query=""; userhostport="$rest_nofrag" ;;
		esac
		secret="${userhostport%%@*}"
		hostport="${userhostport#*@}"
		host="${hostport%:*}"
		port="${hostport##*:}"
		name="$(urldecode "$frag_raw")"; [ -n "$name" ] || name="$host:$port"

		i=$((i + 1))
		tag="sr_${label_slug}_$(printf '%03d' "$i")_$(slugify "$name" | cut -c1-16)"

		ob="$(build_outbound "$proto" "$secret" "$host" "$port" "$query" "" "$tag")" || { skipped=$((skipped + 1)); continue; }
		jq --argjson ob "$ob" '. + [$ob]' "$tmp_outbounds" >"$tmp_outbounds.new" && mv "$tmp_outbounds.new" "$tmp_outbounds"
		jq -n --arg tag "$tag" --arg name "$name" --arg address "$host" --arg proto "$proto" --arg sub "$label" \
			'{tag:$tag, name:$name, address:$address, protocol:$proto, subscription:$sub}' \
			>"$tmp_servers.one"
		jq --argjson s "$(cat "$tmp_servers.one")" '. + [$s]' "$tmp_servers" >"$tmp_servers.new" && mv "$tmp_servers.new" "$tmp_servers"
	done

	jq -n --argjson list "$(cat "$tmp_outbounds")" '{outbounds:$list}' >"$SR_OUTBOUNDS_FILE"

	# merge with any servers already imported from other subscriptions
	if [ -f "$SR_SERVERS_FILE" ]; then
		jq -s '.[0] + .[1] | unique_by(.tag)' "$SR_SERVERS_FILE" "$tmp_servers" >"$SR_SERVERS_FILE.new"
		mv "$SR_SERVERS_FILE.new" "$SR_SERVERS_FILE"
	else
		cp "$tmp_servers" "$SR_SERVERS_FILE"
	fi

	count="$(jq 'length' "$SR_SERVERS_FILE")"
	sr_log "imported subscription '$label': now $count server(s) known in total"
	rm -f "$tmp_outbounds" "$tmp_servers" "$tmp_servers.one" "$tmp_outbounds.new" "$tmp_servers.new" 2>/dev/null || true
}

case "${1:-}" in
	import) sr_import "$2" "${3:-sub}" ;;
	list) sr_ensure_dirs; [ -f "$SR_SERVERS_FILE" ] && cat "$SR_SERVERS_FILE" || echo '[]' ;;
	*) echo "usage: $0 {import <url> [label]|list}" >&2; exit 1 ;;
esac
