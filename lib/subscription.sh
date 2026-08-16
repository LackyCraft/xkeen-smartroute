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
	# The subscription's own "extra" query param (raw XHTTP tuning fields
	# some providers attach: session/seq placement, padding obfuscation,
	# etc.) is deliberately not merged in below. One provider's node was
	# observed sending a field combination this Xray build's config
	# validator hard-rejects at startup ("SeqPlacement must be path when
	# SessionPlacement is path"), which blocks every future restart until
	# someone notices -- and no imported server has ever needed any of
	# these fields just to connect, so it's not worth the risk.

	jq -n \
		--arg tag "$tag" --arg proto "$proto" --arg address "$host" --argjson port "$port" \
		--arg id "$secret" --arg net "$net" --arg security "$security" --arg sni "$sni" \
		--arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --arg spx "$spx" --arg alpn "$alpn" \
		--arg path "$path" --arg hosthdr "$hosthdr" --arg mode "$mode" --arg flow "$flow" \
		--arg svcname "$svcname" '
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
				elif $net=="xhttp" or $net=="splithttp" then {xhttpSettings: {path:$path, host:$hosthdr, mode:$mode}}
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
		# Tag is derived from the node's identity, not a sequential index -- a
		# subscription "refresh" re-fetches the same URL and gets the same
		# nodes back, usually in a different order or interleaved with
		# additions/removals elsewhere in the list. An index-based tag would
		# drift out from under any profile that already references it,
		# silently breaking the user's saved routing on the next refresh.
		# host+port+secret alone isn't quite enough, though: some providers
		# reuse the same endpoint+credential for several *different* nodes
		# that only differ in transport path/SNI (e.g. multiple CDN edges
		# fronting one VLESS server) -- seen for real, it collapsed 70
		# imported servers down to 56 via tag collisions. Folding the node's
		# own display name in fixes that (still stable across refreshes for
		# the same node, as long as the provider doesn't rename it) without
		# going back to a fragile sequential index.
		tag="sr_${label_slug}_$(slugify "$host")_${port}_$(printf '%s' "$secret" | cut -c1-8)_$(slugify "$name" | cut -c1-12)"

		ob="$(build_outbound "$proto" "$secret" "$host" "$port" "$query" "" "$tag")" || { skipped=$((skipped + 1)); continue; }
		ob="$(printf '%s' "$ob" | jq --arg sub "$label" '. + {subscription:$sub}')"
		jq --argjson ob "$ob" '. + [$ob]' "$tmp_outbounds" >"$tmp_outbounds.new" && mv "$tmp_outbounds.new" "$tmp_outbounds"
		jq -n --arg tag "$tag" --arg name "$name" --arg address "$host" --argjson port "$port" --arg proto "$proto" --arg sub "$label" \
			'{tag:$tag, name:$name, address:$address, port:$port, protocol:$proto, subscription:$sub}' \
			>"$tmp_servers.one"
		jq --argjson s "$(cat "$tmp_servers.one")" '. + [$s]' "$tmp_servers" >"$tmp_servers.new" && mv "$tmp_servers.new" "$tmp_servers"
	done

	# A fetch that "succeeds" (curl exit 0) but returns an empty body, an
	# error page, or a body with zero parseable vless://trojan:// lines
	# would otherwise fall straight into the replace-by-label merge below
	# and silently wipe out every server this label previously had --
	# turning one transient hiccup on a refresh cycle into total data loss.
	# Refuse to commit an empty result; leave existing state untouched.
	parsed_count="$(jq 'length' "$tmp_servers")"
	if [ "$parsed_count" -eq 0 ]; then
		sr_log "import '$label' fetched 0 usable server(s) (empty/invalid response?) -- keeping existing data untouched"
		rm -f "$tmp_outbounds" "$tmp_servers" "$tmp_servers.one" "$tmp_outbounds.new" "$tmp_servers.new" 2>/dev/null || true
		return 1
	fi

	# Replace (not accumulate) this label's own servers/outbounds, then merge
	# with whatever other subscriptions already contributed. Two bugs this
	# fixes together: (1) re-importing/refreshing the same label used to pile
	# up duplicate-ish entries under drifting tags instead of replacing the
	# old set; (2) 04_outbounds.smartroute.json used to be overwritten with
	# *only* the current import's outbounds, silently deleting every other
	# subscription's servers from the actual Xray config (servers.json stayed
	# multi-subscription-aware, the real proxy config quietly wasn't).
	sr_ensure_dirs
	# -s (non-empty), not -f (exists): jq silently produces zero output on a
	# 0-byte input file instead of erroring, so a merely-existing-but-empty
	# state file (e.g. left over from an interrupted previous write) would
	# pass an -f guard and then feed jq nothing, collapsing this and every
	# future merge down to an empty result forever.
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	[ -s "$SR_OUTBOUNDS_STATE_FILE" ] || echo '[]' >"$SR_OUTBOUNDS_STATE_FILE"

	jq --arg lbl "$label" '[.[] | select(.subscription != $lbl)]' "$SR_SERVERS_FILE" >"$SR_SERVERS_FILE.new"
	jq -s '.[0] + .[1] | unique_by(.tag)' "$SR_SERVERS_FILE.new" "$tmp_servers" >"$SR_SERVERS_FILE"
	rm -f "$SR_SERVERS_FILE.new"

	# Same full replace-by-label semantics as servers.json above, not a
	# keep-if-tag-still-present filter: a node that roams to a new IP
	# between fetches gets a new tag (the old one embeds the address), so
	# "still present" filtering never matches the old tag and never removes
	# it -- it just sits there forever as a dead outbound, silently
	# carrying whatever config it had at import time (including config
	# shapes later import fixes were meant to stop producing). Every
	# outbound here is tagged with its subscription label for exactly this
	# filter; the label itself is stripped back out below before this ever
	# reaches Xray's real config.
	jq --arg lbl "$label" '[.[] | select(.subscription != $lbl)]' "$SR_OUTBOUNDS_STATE_FILE" >"$SR_OUTBOUNDS_STATE_FILE.new"
	jq -s '.[0] + .[1] | unique_by(.tag)' "$SR_OUTBOUNDS_STATE_FILE.new" "$tmp_outbounds" >"$SR_OUTBOUNDS_STATE_FILE"
	rm -f "$SR_OUTBOUNDS_STATE_FILE.new"

	jq -n --argjson list "$(jq '[.[] | del(.subscription)]' "$SR_OUTBOUNDS_STATE_FILE")" '{outbounds:$list}' >"$SR_OUTBOUNDS_FILE"

	count="$(jq 'length' "$SR_SERVERS_FILE")"
	sr_log "imported subscription '$label': now $count server(s) known in total"
	rm -f "$tmp_outbounds" "$tmp_servers" "$tmp_servers.one" "$tmp_outbounds.new" "$tmp_servers.new" 2>/dev/null || true

	# remember how to refresh this subscription later without user input
	sr_save_subscription_meta "$url" "$label" "$client" "$os_ov" "$locale_ov" "$model_ov" "$ver_ov" "$hwid_ov"
}

# --- auto-refresh: remember subscription params, replay them on a schedule ---

SR_SUBS_META_FILE="$SR_STATE_DIR/subscriptions.json"
SR_REFRESH_STATE_FILE="$SR_STATE_DIR/refresh.json"
DEFAULT_REFRESH_HOURS=12

sr_save_subscription_meta() {
	url="$1"; label="$2"; client="$3"; os_ov="$4"; locale_ov="$5"; model_ov="$6"; ver_ov="$7"; hwid_ov="$8"
	sr_ensure_dirs
	[ -s "$SR_SUBS_META_FILE" ] || echo '[]' >"$SR_SUBS_META_FILE"
	entry="$(jq -n --arg url "$url" --arg label "$label" --arg client "$client" \
		--arg os "$os_ov" --arg locale "$locale_ov" --arg model "$model_ov" --arg ver "$ver_ov" --arg hwid "$hwid_ov" \
		'{url:$url, label:$label, client:$client, os:$os, locale:$locale, model:$model, ver:$ver, hwid:$hwid}')"
	jq --arg lbl "$label" --argjson e "$entry" '[.[] | select(.label != $lbl)] + [$e]' "$SR_SUBS_META_FILE" >"$SR_SUBS_META_FILE.new"
	mv "$SR_SUBS_META_FILE.new" "$SR_SUBS_META_FILE"
}

sr_get_refresh_hours() {
	[ -s "$SR_STATE_DIR/refresh_interval_hours" ] && cat "$SR_STATE_DIR/refresh_interval_hours" || echo "$DEFAULT_REFRESH_HOURS"
}

sr_set_refresh_hours() {
	sr_ensure_dirs
	case "$1" in *[!0-9]*|'') sr_die "refresh interval must be a whole number of hours" ;; esac
	echo "$1" > "$SR_STATE_DIR/refresh_interval_hours"
}

# Called hourly from cron; only actually refetches once the configured
# interval has elapsed, and only for subscriptions we've successfully
# imported at least once before (nothing to do on a fresh install).
sr_refresh_due() {
	sr_ensure_dirs
	[ -s "$SR_SUBS_META_FILE" ] || { sr_log "refresh: no saved subscriptions yet"; return 0; }
	hours="$(sr_get_refresh_hours)"
	last=0
	[ -s "$SR_REFRESH_STATE_FILE" ] && last="$(jq -r '.last // 0' "$SR_REFRESH_STATE_FILE" 2>/dev/null || echo 0)"
	now="$(date +%s)"
	due_at=$((last + hours * 3600))
	if [ "$now" -lt "$due_at" ]; then
		return 0
	fi
	sr_do_refresh
}

# Same as sr_refresh_due but ignores the schedule -- for a UI "refresh now" button.
sr_force_refresh() {
	sr_ensure_dirs
	[ -s "$SR_SUBS_META_FILE" ] || { sr_log "refresh: no saved subscriptions yet"; return 0; }
	sr_do_refresh
}

sr_do_refresh() {
	now="$(date +%s)"
	count="$(jq 'length' "$SR_SUBS_META_FILE")"
	sr_log "refresh: re-importing $count saved subscription(s)"
	jq -c '.[]' "$SR_SUBS_META_FILE" | while IFS= read -r entry; do
		u="$(printf '%s' "$entry" | jq -r '.url')"
		l="$(printf '%s' "$entry" | jq -r '.label')"
		c="$(printf '%s' "$entry" | jq -r '.client')"
		o="$(printf '%s' "$entry" | jq -r '.os')"
		lo="$(printf '%s' "$entry" | jq -r '.locale')"
		m="$(printf '%s' "$entry" | jq -r '.model')"
		v="$(printf '%s' "$entry" | jq -r '.ver')"
		h="$(printf '%s' "$entry" | jq -r '.hwid')"
		# subshell: sr_import calls sr_die (exit) on a fetch failure, which
		# would otherwise abort this whole while loop on the first bad
		# subscription instead of moving on to the next one
		( sr_import "$u" "$l" "$c" "$o" "$lo" "$m" "$v" "$h" ) || sr_log "refresh: failed to re-import '$l'"
	done
	sr_restart_xray
	jq -n --arg now "$now" '{last: ($now|tonumber)}' >"$SR_REFRESH_STATE_FILE"
}

# --- ping: TCP-connect latency per server, run in parallel ---
# Real usability signal without needing a raw-socket ICMP ping (which would
# need to run as root anyway and gets blocked by some networks/servers);
# curl's time_connect is just the TCP handshake, independent of whether TLS
# or the VPN handshake itself succeeds. Run in the background per server and
# wait, rather than one after another -- 70 servers at up to a few seconds
# each, sequentially, would make the button take minutes instead of ~3-4s.
SR_PING_FILE="$SR_STATE_DIR/ping.json"
SR_PING_TIMEOUT=3

sr_ping_one() {
	tag="$1"; host="$2"; port="$3"; out="$4"
	# curl legitimately exits non-zero here almost every time -- it's doing a
	# plain HTTPS request against a VLESS/Trojan endpoint that will never
	# complete a real TLS handshake for a bare GET; %{time_connect} (the TCP
	# handshake alone) is all we actually want. Under this script's `set -e`,
	# an unguarded `$(curl ...)` assignment propagates that non-zero status
	# and kills this backgrounded invocation on the spot, before it ever
	# reaches the write below -- silently, since it's a detached child with
	# no visible error. `|| true` neutralizes that; stdout is still captured.
	ms="$(curl -o /dev/null -s -m "$SR_PING_TIMEOUT" -w '%{time_connect}' "https://$host:$port/" 2>/dev/null)" || true
	case "$ms" in
		''|0.000000) ms="" ;;
	esac
	if [ -n "$ms" ]; then
		ms_int=$(awk -v t="$ms" 'BEGIN{printf "%d", t*1000}' 2>/dev/null || echo "")
	else
		ms_int=""
	fi
	jq -n --arg tag "$tag" --arg ms "$ms_int" '{tag:$tag, ping_ms: ($ms | if .=="" then null else tonumber end)}' > "$out"
}

sr_ping_all() {
	sr_require curl; sr_require jq
	sr_ensure_dirs
	[ -s "$SR_SERVERS_FILE" ] || { echo '{}'; return 0; }
	tmp_dir="$(mktemp -d)"
	tmp_list="$(mktemp)"
	jq -c '.[]' "$SR_SERVERS_FILE" > "$tmp_list"
	i=0
	# Read from a real file, not a `cmd | while read` pipe: piping into the
	# loop would run it (and every `&` job started inside it) in a subshell,
	# so the `wait` below -- in the parent shell -- would have no children to
	# wait for and return immediately, before any ping finished.
	while IFS= read -r s; do
		i=$((i + 1))
		tag="$(printf '%s' "$s" | jq -r '.tag')"
		host="$(printf '%s' "$s" | jq -r '.address')"
		port="$(printf '%s' "$s" | jq -r '.port // 443')"
		sr_ping_one "$tag" "$host" "$port" "$tmp_dir/$i.json" &
	done < "$tmp_list"
	wait
	rm -f "$tmp_list"

	jq -s '[.[]] | INDEX(.tag) | map_values(.ping_ms)' "$tmp_dir"/*.json 2>/dev/null > "$SR_PING_FILE" || echo '{}' > "$SR_PING_FILE"
	rm -rf "$tmp_dir"
	cat "$SR_PING_FILE"
}

case "${1:-}" in
	import) sr_import "$2" "${3:-sub}" "${4:-smartroute}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" ;;
	list) sr_ensure_dirs; [ -s "$SR_SERVERS_FILE" ] && cat "$SR_SERVERS_FILE" || echo '[]' ;;
	refresh) sr_refresh_due ;;
	refresh-now) sr_force_refresh ;;
	get-refresh-hours) sr_get_refresh_hours ;;
	set-refresh-hours) sr_set_refresh_hours "${2:-}" ;;
	ping) sr_ping_all ;;
	*) echo "usage: $0 {import <url> [label] [client] [os] [locale] [model] [ver] [hwid]|list|refresh|refresh-now|get-refresh-hours|set-refresh-hours <n>|ping}" >&2; exit 1 ;;
esac
