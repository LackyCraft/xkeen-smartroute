#!/bin/sh
# lib/subscription.sh — fetch a VLESS/Trojan subscription link (base64 blob of
# vless://... / trojan://... URIs, the common V2rayNG/V2Box format) and turn
# it into an Xray outbounds fragment that xkeen picks up.
#
# Usage:
#   subscription.sh import <url> [label] [client] [os] [locale] [model] [ver] [hwid]
#   subscription.sh list                             # print servers.json (for the UI)
#
# Some subscription panels (3x-ui-style "collection" pages, seen in the wild)
# serve a human-facing HTML page by default and only return the actual
# machine-readable subscription body to requests whose headers look like a
# known VPN app. [client] picks a User-Agent preset (see CLIENT_PRESET below
# for the full list); the default "smartroute" identifies honestly as this
# project and works with panels that don't gate on client identity. The five
# trailing args (device OS / locale / model / OS version / hardware id) let
# you override any individual header regardless of preset -- pass "" to keep
# the preset's own default for that field. An unrecognized [client] value is
# sent verbatim as the literal User-Agent string.
#
# Requires: curl, jq, sed, base64 (all present once Entware is installed).

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

gen_random_id() {
	# Not every busybox build here ships `od`/`hexdump` (observed missing on
	# real hardware) -- the kernel's own UUID generator needs no extra tools
	# and is the most portable source of randomness available.
	if [ -r /proc/sys/kernel/random/uuid ]; then
		cat /proc/sys/kernel/random/uuid | tr -d '\n'
	elif command -v od >/dev/null 2>&1; then
		head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
	else
		printf 'sr%s%s' "$(date +%s)" "$$"
	fi
}

client_hwid() {
	# stable-per-router pseudo-device-id, used whenever no explicit hwid override is given
	hwid_file="$SR_STATE_DIR/hwid"
	if [ ! -s "$hwid_file" ]; then
		mkdir -p "$SR_STATE_DIR"
		gen_random_id > "$hwid_file" 2>/dev/null
	fi
	cat "$hwid_file"
}

# CLIENT_PRESET <key> -> "User-Agent|OS|Locale|Model|VerOs" (defaults; each
# field can be overridden individually at call time). Keep this in sync with
# the <select> in subscriptions.js.
client_preset() {
	case "$1" in
		smartroute|"") echo "XKeen-SmartRoute/1.0 (+https://github.com/LackyCraft/xkeen-smartroute)|XKeen SmartRoute|ru||" ;;
		happ)          echo "Happ|iOS|ru|iPhone 15 Pro|17.5" ;;
		happ-ios)      echo "Happ|iOS|ru|iPhone 15 Pro|17.5" ;;
		happ-android)  echo "Happ|Android|ru|Pixel 8|15" ;;
		v2rayng)       echo "v2rayNG/1.9.22|Android|ru||" ;;
		v2ray)         echo "v2ray/5.16.1|Linux|ru||" ;;
		v2box)         echo "V2Box/1.4.1|iOS|ru|iPhone 15 Pro|17.5" ;;
		clash)         echo "Clash/v1.18.0|Windows|ru||" ;;
		clash-meta)    echo "ClashMetaForAndroid/2.11.10|Android|ru||" ;;
		mihomo)        echo "clash.meta|Android|ru|ELP-NX1|15" ;;
		sing-box)      echo "sing-box/1.9.0|Linux|ru||" ;;
		singbox)       echo "sing-box/1.9.0|Linux|ru||" ;;
		nekobox)       echo "NekoBox/1.3.7|Android|ru||" ;;
		shadowrocket)  echo "Shadowrocket|iOS|ru|iPhone16,1|17.0" ;;
		stash)         echo "Stash/2.6.1|iOS|ru|iPhone 15 Pro|17.5" ;;
		surge)         echo "Surge/1391|iOS|ru|iPhone 15 Pro|17.5" ;;
		loon)          echo "Loon/636|iOS|ru|iPhone 15 Pro|17.5" ;;
		flclash)       echo "FlClash/1.0.0|Windows|ru||" ;;
		incy)          echo "Incy/1.0|Android|ru||" ;;
		*)             echo "$1|XKeen SmartRoute|ru||" ;;
	esac
}

sr_fetch_sub() {
	# $1=client $2=url $3=os_override $4=locale_override $5=model_override $6=ver_override $7=hwid_override
	client="$1"; url="$2"; os_ov="${3:-}"; locale_ov="${4:-}"; model_ov="${5:-}"; ver_ov="${6:-}"; hwid_ov="${7:-}"

	preset="$(client_preset "$client")"
	ua="${preset%%|*}"; rest="${preset#*|}"
	dos="${rest%%|*}"; rest="${rest#*|}"
	dlocale="${rest%%|*}"; rest="${rest#*|}"
	dmodel="${rest%%|*}"; dver="${rest#*|}"

	[ -z "$os_ov" ] || dos="$os_ov"
	[ -z "$locale_ov" ] || dlocale="$locale_ov"
	[ -z "$model_ov" ] || dmodel="$model_ov"
	[ -z "$ver_ov" ] || dver="$ver_ov"
	hwid="${hwid_ov:-$(client_hwid)}"

	set -- -fsSL --max-time 20 -H "User-Agent: $ua"
	[ -z "$dos" ]     || set -- "$@" -H "X-Device-Os: $dos"
	[ -z "$dlocale" ] || set -- "$@" -H "X-Device-Locale: $dlocale"
	[ -z "$dmodel" ]  || set -- "$@" -H "X-Device-Model: $dmodel"
	[ -z "$dver" ]    || set -- "$@" -H "X-Ver-Os: $dver"
	[ -z "$hwid" ]    || set -- "$@" -H "X-Hwid: $hwid"
	curl "$@" "$url"
}

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
	# most servers have no `extra` param at all (only xhttp/splithttp ones do).
	# On empty input this jq build exits 0 with empty output instead of
	# erroring, so `|| echo '{}'` never fires on exit status alone -- check
	# the actual output too, or every non-xhttp server fails to import with
	# "invalid JSON text passed to --argjson" (empty string isn't valid JSON).
	extra_json="$(printf '%s' "$extra_raw" | jq -c '.' 2>/dev/null)"
	[ -n "$extra_json" ] || extra_json='{}'

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
	url="$1"; label="${2:-sub}"; client="${3:-smartroute}"
	os_ov="${4:-}"; locale_ov="${5:-}"; model_ov="${6:-}"; ver_ov="${7:-}"; hwid_ov="${8:-}"
	sr_require curl; sr_require jq
	sr_ensure_dirs

	raw="$(sr_fetch_sub "$client" "$url" "$os_ov" "$locale_ov" "$model_ov" "$ver_ov" "$hwid_ov")" || sr_die "failed to fetch subscription: $url"
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
	import) sr_import "$2" "${3:-sub}" "${4:-smartroute}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" ;;
	list) sr_ensure_dirs; [ -f "$SR_SERVERS_FILE" ] && cat "$SR_SERVERS_FILE" || echo '[]' ;;
	*) echo "usage: $0 {import <url> [label] [client] [os] [locale] [model] [ver] [hwid]|list}" >&2; exit 1 ;;
esac
