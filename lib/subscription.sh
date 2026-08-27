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

# redact_url: scheme://host/path only -- strips everything from the first
# "?" onward. Subscription URLs carry their access secret as a query-string
# token (e.g. ?token=...); logging the URL verbatim on a fetch failure put
# that token in syslog (sr_die -> sr_log -> `logger`, readable by anyone
# with router access, and plausibly the exact thing a user pastes into a
# support request) and in the RPC error response's own .detail field
# (returned straight to the browser, see import_subscription in the rpcd
# script). Keeping host/path lets a failure still be diagnosed ("which
# subscription, which host") without the secret.
redact_url() {
	case "$1" in
		*\?*) printf '%s***' "${1%%\?*}" ;;
		*) printf '%s' "$1" ;;
	esac
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
	# The subscription's own "extra" query param -- raw XHTTP tuning fields
	# some providers attach: padding obfuscation (xPaddingBytes/Key/Header/
	# Placement/Method), connection reuse (xmux), upload chunking
	# (scMaxEachPostBytes/scMinPostsIntervalMs), etc. This isn't a made-up
	# convention -- it's Xray's own real xhttpSettings schema
	# (infra/conf/transport_method.go's SplitHTTPConfig has a matching
	# `Extra json.RawMessage` field, unmarshalled straight into the same
	# struct), so passing it through verbatim is exactly what a "real"
	# client (v2rayNG, Happ, ...) does too.
	#
	# Confirmed for real why this actually matters, not just theoretical
	# completeness: two nodes reported as "dead" by both Observatory and a
	# direct manual probe (same GET, same outbound, bypassing Observatory's
	# cache entirely) turned out to work fine through Happ on the same
	# network/subscription -- the only difference was this exact field.
	# xPaddingObfsMode:true means the provider's edge expects that specific
	# padding scheme just to recognize the request as real client traffic;
	# without it the TLS layer completes but the XHTTP request never gets a
	# response (observed live: "SSL - The connection indicated an EOF"
	# right after a successful TCP connect).
	#
	# This field used to be dropped on purpose: one provider's node once
	# sent an `extra` combination this Xray build's config validator
	# hard-rejects at startup. That's a real risk, but not an unsafe one --
	# _sr_xray_validate() already refuses to restart on any config that
	# fails `xray run -test`, old (working) config keeps running either
	# way -- so the actual failure mode is "this one regen's changes don't
	# take effect until the bad node is fixed/removed", not "internet
	# breaks". That's a better trade than silently breaking every node
	# whose provider genuinely requires this to connect at all.
	extra_raw="$(urldecode "$(qval "$query" extra)")"
	# `jq -c .` on completely empty input (the common case -- most nodes,
	# e.g. every REALITY one, have no "extra" param at all) exits 0 with no
	# output at all, not an error -- so `|| echo 'null'` never triggered and
	# extra_json ended up as an empty string. --argjson then rejects that
	# outright ("invalid JSON text"), which fails build_outbound's own jq
	# call entirely and silently drops the whole node. Confirmed live: this
	# dropped a 130-server subscription down to 26 -- every node without an
	# explicit "extra" param vanished. Checking the actual output for
	# emptiness (not just the exit code) catches both the "no input" and
	# the "malformed input" cases the same way.
	extra_json="$(printf '%s' "$extra_raw" | jq -c . 2>/dev/null)"
	[ -n "$extra_json" ] || extra_json='null'

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
				elif $net=="xhttp" or $net=="splithttp" then {xhttpSettings: ({path:$path, host:$hosthdr, mode:$mode} + (if $extra != null then {extra:$extra} else {} end))}
				else {} end)
			)
		}'
}

# _sr_compute_tag_remap: shared by sr_remap_profile_tags and
# sr_remap_doublevpn_tags -- given a subscription's server list from just
# before and just after a refresh, returns a JSON array of
# {old, name, new} for every tag that disappeared, `new` set to the tag's
# new identity if a matching .match_key was found elsewhere in the new
# list, or null if the node is genuinely gone.
#
# Entries imported before match_key existed at all (any install that
# refreshed between this feature landing and its predecessor) have no
# .match_key field -- accessing a missing key gives jq's `null`, and
# `$obj[null]` is itself a hard error ("Cannot index object with null"),
# not just a harmless miss. Confirmed live upgrading this exact router's
# own pre-match_key servers.json. Filtering match_key-less entries out of
# $by_key up front, and guarding the lookup on the old side, means such an
# entry is simply never remapped (falls through to "removed", same as a
# real miss) instead of crashing the whole import.
_sr_compute_tag_remap() {
	old_servers="$1"
	new_servers="$2"
	jq -cn --argjson old "$old_servers" --argjson new "$new_servers" '
		($new | map(.tag)) as $new_tags |
		($new | map(select(.match_key != null)) | map({key: .match_key, value: .tag}) | from_entries) as $by_key |
		[ $old[] | select(.tag as $t | ($new_tags | index($t)) | not) |
			{ old: .tag, name: .name, new: (if .match_key == null then null else ($by_key[.match_key] // null) end) }
		]
	'
}

# sr_remap_profile_tags: given a subscription label's server list from just
# before and just after a refresh, re-associate every profile that
# referenced a tag that disappeared -- to whatever new tag shares its
# match_key if one exists (the same logical node, provider just tweaked a
# query param), or moves it into that profile's .removed_servers if not
# (the node is genuinely gone). Never called with the *new* label's own
# list restricted to what changed -- it diffs old vs new itself, so
# passing the same list twice is always a safe no-op. See
# docs/subscription-update.md for the full design.
sr_remap_profile_tags() {
	old_servers="$1"
	new_servers="$2"

	remap="$(_sr_compute_tag_remap "$old_servers" "$new_servers")"
	remap_count="$(echo "$remap" | jq 'length')"
	[ "$remap_count" -gt 0 ] || return 0

	remapped_count="$(echo "$remap" | jq '[.[] | select(.new != null)] | length')"
	removed_count="$(echo "$remap" | jq '[.[] | select(.new == null)] | length')"
	sr_log "subscription refresh: $remapped_count tag(s) remapped to their new identity, $removed_count server(s) genuinely gone"

	for pf in "$SR_PROFILES_DIR"/*.json; do
		[ -e "$pf" ] || continue
		jq --argjson remap "$remap" '
			(reduce $remap[] as $r ({}; . + {($r.old): $r})) as $rmap |
			(.servers // []) as $orig |
			(.fixed_server // null) as $orig_fixed |
			(.removed_servers // []) as $existing_removed |
			(now | todate) as $now |
			(
				[range(0; ($orig | length)) as $i |
					($orig[$i]) as $t |
					($rmap[$t]) as $r |
					if $r == null then {kind: "keep", tag: $t}
					elif $r.new != null then {kind: "keep", tag: $r.new}
					else {kind: "removed", tag: $t, name: $r.name}
					end
				]
			) as $decisions |
			($decisions | map(select(.kind == "keep")) | map(.tag)) as $new_servers_list |
			($decisions | map(select(.kind == "removed")) | map({tag: .tag, name: .name, removed_at: $now})) as $removed_from_servers |
			(
				if $orig_fixed == null then {fixed: null, removed: []}
				elif $rmap[$orig_fixed] == null then {fixed: $orig_fixed, removed: []}
				elif $rmap[$orig_fixed].new != null then {fixed: $rmap[$orig_fixed].new, removed: []}
				else {fixed: $orig_fixed, removed: [{tag: $orig_fixed, name: $rmap[$orig_fixed].name, removed_at: $now}]}
				end
			) as $fixed_res |
			.servers = $new_servers_list
			| .fixed_server = $fixed_res.fixed
			| .removed_servers = ($existing_removed + $removed_from_servers + $fixed_res.removed)
		' "$pf" > "$pf.tmp" && mv "$pf.tmp" "$pf"
	done
}

# sr_remap_doublevpn_tags: same idea as sr_remap_profile_tags, but for the
# double-VPN gateway pool (SR_DOUBLEVPN_FILE, a single JSON file -- not a
# directory of profiles). Confirmed missing live: sr_apply_doublevpn
# (genroute.sh) already filters its pool down to currently-known tags
# before picking a gateway, so a disappeared server never breaks anything
# functionally -- but silently, with no remap to a node's new identity and
# no UI indication a server dropped out, unlike every profile. The pool
# stayed a comma-separated graveyard of dead tags forever, only ever
# growing, since nothing ever pruned .servers itself.
sr_remap_doublevpn_tags() {
	old_servers="$1"
	new_servers="$2"
	[ -s "$SR_DOUBLEVPN_FILE" ] || return 0

	remap="$(_sr_compute_tag_remap "$old_servers" "$new_servers")"
	[ "$(echo "$remap" | jq 'length')" -gt 0 ] || return 0

	# Only the tags actually in this pool matter for the log line -- $remap
	# itself covers every tag the whole subscription lost, most of which
	# were never in the double-VPN pool at all.
	decisions="$(jq -c --argjson remap "$remap" '
		(reduce $remap[] as $r ({}; . + {($r.old): $r})) as $rmap |
		[(.servers // [])[] as $t |
			($rmap[$t]) as $r |
			if $r == null then empty
			elif $r.new != null then {kind: "remapped", tag: $t, new: $r.new}
			else {kind: "removed", tag: $t, name: $r.name}
			end
		]
	' "$SR_DOUBLEVPN_FILE")"
	[ "$(echo "$decisions" | jq 'length')" -gt 0 ] || return 0

	remapped_count="$(echo "$decisions" | jq '[.[] | select(.kind == "remapped")] | length')"
	removed_count="$(echo "$decisions" | jq '[.[] | select(.kind == "removed")] | length')"
	sr_log "double VPN pool: $remapped_count tag(s) remapped to their new identity, $removed_count server(s) genuinely gone"

	jq --argjson remap "$remap" '
		(reduce $remap[] as $r ({}; . + {($r.old): $r})) as $rmap |
		(.servers // []) as $orig |
		(.removed_servers // []) as $existing_removed |
		(now | todate) as $now |
		(
			[range(0; ($orig | length)) as $i |
				($orig[$i]) as $t |
				($rmap[$t]) as $r |
				if $r == null then {kind: "keep", tag: $t}
				elif $r.new != null then {kind: "keep", tag: $r.new}
				else {kind: "removed", tag: $t, name: $r.name}
				end
			]
		) as $decisions |
		.servers = ($decisions | map(select(.kind == "keep")) | map(.tag))
		| .removed_servers = ($existing_removed +
			($decisions | map(select(.kind == "removed")) | map({tag: .tag, name: .name, removed_at: $now})))
	' "$SR_DOUBLEVPN_FILE" > "$SR_DOUBLEVPN_FILE.tmp" && mv "$SR_DOUBLEVPN_FILE.tmp" "$SR_DOUBLEVPN_FILE"
}

sr_import() {
	url="$1"; label="${2:-sub}"; client="${3:-smartroute}"
	os_ov="${4:-}"; locale_ov="${5:-}"; model_ov="${6:-}"; ver_ov="${7:-}"; hwid_ov="${8:-}"
	sr_require curl; sr_require jq
	sr_ensure_dirs

	# Concurrent imports raced on the same tmp_outbounds/tmp_servers files
	# for real: an SSH client-side timeout left a refresh-one running on the
	# router well past when the caller gave up and retried, and the two
	# interleaved writes corrupted the result down from 130 servers to 26.
	# mkdir is atomic on every filesystem this project runs on (same
	# technique genroute.sh's regen lock already uses). Unlike that lock,
	# this one *waits* instead of skipping on contention -- an explicit
	# "refresh now" click racing the hourly cron should still actually
	# import, not silently no-op just because something else got there
	# first.
	lock_dir="$SR_STATE_DIR/.import.lock"
	waited=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		lock_age=999999
		if [ -d "$lock_dir" ]; then
			lock_age=$(( $(date +%s) - $(date -r "$lock_dir" +%s 2>/dev/null || echo 0) ))
		fi
		if [ "$lock_age" -ge 300 ]; then
			sr_log "reclaiming stale import lock (${lock_age}s old)"
			rm -rf "$lock_dir"
			continue
		fi
		[ "$waited" -lt 120 ] || sr_die "another subscription import is already running and didn't finish within 120s"
		sleep 2
		waited=$((waited + 2))
	done
	trap 'rm -rf "$lock_dir"' EXIT INT TERM

	raw="$(sr_fetch_sub "$client" "$url" "$os_ov" "$locale_ov" "$model_ov" "$ver_ov" "$hwid_ov")" || sr_die "failed to fetch subscription: $(redact_url "$url")"
	decoded="$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)"
	case "$decoded" in
		*"://"*) body="$decoded" ;;
		*) body="$raw" ;;
	esac

	tmp_outbounds="$(mktemp)"
	tmp_servers="$(mktemp)"
	# One small file per parsed node below, merged in a single `jq -s` pass
	# after the loop -- not appended to a growing array on every single
	# line. The append-in-place version re-read, re-parsed, and rewrote the
	# *entire* accumulated array on every iteration (jq --argjson ob '. +
	# [$ob]' "$tmp_outbounds" > ...), real O(n^2) work for a subscription
	# in the 150-190 server range this project actually sees, on hardware
	# slow enough that it measurably added to import time. Writing one file
	# per node is O(1) each; the final slurp is one O(n) pass over all of
	# them.
	tmp_dir="$(mktemp -d)"

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
		# Bracketed IPv6 literal ("[2001:db8::1]:443", RFC 3986 -- how a URI
		# has to encode an IPv6 host, since a bare literal's own colons
		# would be indistinguishable from the ":port" separator). The %:*
		# split above correctly finds the port after the closing bracket
		# (shortest match from the end lands on the last colon either way),
		# but leaves the brackets themselves inside $host; Xray's own
		# outbound "address" field wants the bare literal, not URI bracket
		# syntax, so a real IPv6 server would silently fail to connect
		# (address "[2001:db8::1]" is not a valid address, just a mangled
		# one) without this.
		case "$host" in
			\[*\]) host="${host#\[}"; host="${host%\]}" ;;
		esac
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
		#
		# Several more real collision sources found live, all from this one
		# subscription: (1) `slugify` maps every non-ASCII character to `_`
		# and squeezes repeats, so a name that's entirely Cyrillic (common
		# for a RU-market subscription -- half this one's node names are)
		# can collapse down to just a trailing digit or nothing at all,
		# silently merging distinctly-named nodes onto one tag whenever
		# they happen to end the same way (e.g. both named "... 1"); (2)
		# truncating the secret to its first 8 characters isn't enough
		# either -- this subscription has multiple genuinely different
		# UUIDs that only diverge after that point (e.g.
		# "2d3fc8f5-a0ad-4935-..." vs "2d3fc8f5-a0ad-482b-..."); (3) some
		# nodes share host+port+secret+name entirely and only differ in an
		# XHTTP path/host/sni query param (multiple CDN edges fronting one
		# backend, same display name). Together these took a 151-server
		# subscription down to 140 imported. A short slug stays in the tag
		# purely for human readability when skimming the generated config,
		# but uniqueness itself now comes from hashing the *entire* raw
		# line -- secret, host, port, and every query param -- so two tags
		# can only collide if the source lines are truly byte-identical
		# (nothing left to distinguish them by, one tag is correct). Still
		# stable across refreshes: the same raw line always hashes the same.
		name_slug="$(slugify "$name" | cut -c1-12)"
		line_hash="$(printf '%s' "$line" | md5sum | cut -c1-10)"
		tag="sr_${label_slug}_$(slugify "$host")_${port}_${name_slug}_${line_hash}"

		# match_key: a coarser, more change-tolerant identity than the tag
		# itself -- used only to re-associate a node across a refresh where
		# its tag changed (see sr_remap_tags below), never for anything
		# that needs the tag's own full uniqueness. host+port+secret+the
		# camouflage domain (sni, falling back to host like build_outbound's
		# own default) is the combination that actually identifies "the
		# same logical node" to a provider -- confirmed live against this
		# project's own subscription: two nodes can share host+port+secret
		# and only differ in this domain (genuinely different edges), so
		# leaving it out would wrongly merge them; everything else (path,
		# padding/xmux tuning, alpn order, fp, display name) is the kind of
		# thing a provider tweaks on the *same* node without meaning to
		# replace it, so none of that belongs in the key.
		match_sni="$(urldecode "$(qval "$query" sni)")"; [ -n "$match_sni" ] || match_sni="$host"
		match_key="$(printf '%s|%s|%s|%s' "$host" "$port" "$secret" "$match_sni" | md5sum | cut -c1-16)"

		ob="$(build_outbound "$proto" "$secret" "$host" "$port" "$query" "" "$tag")" || { skipped=$((skipped + 1)); continue; }
		ob="$(printf '%s' "$ob" | jq --arg sub "$label" '. + {subscription:$sub}')"
		# Zero-padded, not "$i" bare: the merge below globs these filenames
		# and relies on shell glob expansion's lexicographic (string) sort to
		# reconstruct encounter order -- confirmed live as a real regression,
		# not hypothetical: with a bare counter, "sv_10.json" sorts before
		# "sv_2.json", so every subscription with 10+ servers (this project's
		# own test subscription runs 150-190) came out of a refresh with a
		# scrambled order instead of the original one, even though the
		# order-preserving dedup right below this loop (sort_by the original
		# index) was written assuming encounter order was already intact.
		# Users rely on this order to keep specific servers positioned first
		# in the list. 6 digits covers any subscription size this project
		# will plausibly ever see.
		i_padded="$(printf '%06d' "$i")"
		printf '%s' "$ob" >"$tmp_dir/ob_$i_padded.json"
		jq -n --arg tag "$tag" --arg name "$name" --arg address "$host" --argjson port "$port" --arg proto "$proto" --arg sub "$label" --arg mkey "$match_key" \
			'{tag:$tag, name:$name, address:$address, port:$port, protocol:$proto, subscription:$sub, match_key:$mkey}' \
			>"$tmp_dir/sv_$i_padded.json"
	done

	if ls "$tmp_dir"/ob_*.json >/dev/null 2>&1; then
		jq -s '.' "$tmp_dir"/ob_*.json >"$tmp_outbounds"
	else
		echo '[]' >"$tmp_outbounds"
	fi
	if ls "$tmp_dir"/sv_*.json >/dev/null 2>&1; then
		jq -s '.' "$tmp_dir"/sv_*.json >"$tmp_servers"
	else
		echo '[]' >"$tmp_servers"
	fi
	rm -rf "$tmp_dir"

	# A fetch that "succeeds" (curl exit 0) but returns an empty body, an
	# error page, or a body with zero parseable vless://trojan:// lines
	# would otherwise fall straight into the replace-by-label merge below
	# and silently wipe out every server this label previously had --
	# turning one transient hiccup on a refresh cycle into total data loss.
	# Refuse to commit an empty result; leave existing state untouched.
	parsed_count="$(jq 'length' "$tmp_servers")"
	if [ "$parsed_count" -eq 0 ]; then
		sr_log "import '$label' fetched 0 usable server(s) (empty/invalid response?) -- keeping existing data untouched"
		rm -f "$tmp_outbounds" "$tmp_servers" 2>/dev/null || true
		return 1
	fi

	# Snapshot this label's servers as they were *before* this refresh --
	# sr_remap_profile_tags (called after the replace below) needs to know
	# which old tags disappeared and what each one's match_key was, and
	# that information is gone the moment SR_SERVERS_FILE gets overwritten.
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	old_label_servers="$(jq --arg lbl "$label" '[.[] | select(.subscription == $lbl)]' "$SR_SERVERS_FILE")"

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
	# unique_by(.tag) used to sit here, but jq's unique/unique_by SORTS its
	# result by the extraction key -- it doesn't just dedup. That silently
	# reordered every subscription's server list alphabetically by tag on
	# every import/refresh, discarding the order the subscription server
	# itself sent (which the UI's "Ваши подписки" list is supposed to
	# mirror). This keeps first-seen order instead: tag the merged array
	# with its original index (to_entries), group duplicate tags together
	# (group_by is a stable sort, so each group's first element is the
	# first occurrence), keep just that first element per tag, then
	# sort_by the original index to restore the pre-dedup ordering.
	jq -s '
		(.[0] + .[1]) as $all |
		($all | to_entries | group_by(.value.tag) | map(.[0])) as $first |
		($first | sort_by(.key) | map(.value))
	' "$SR_SERVERS_FILE.new" "$tmp_servers" >"$SR_SERVERS_FILE"
	rm -f "$SR_SERVERS_FILE.new"

	# See docs/subscription-update.md for the full design and why this
	# exists: tags are derived from each raw subscription line's own
	# content (sr_import's tag= above), so any refresh where the provider
	# tweaks so much as one query param produces a *different* tag for what
	# is, to the provider, still the same node -- every profile that had
	# that server checked would otherwise silently lose it, with no
	# indication anything happened.
	sr_remap_profile_tags "$old_label_servers" "$(cat "$tmp_servers")"
	sr_remap_doublevpn_tags "$old_label_servers" "$(cat "$tmp_servers")"

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
	# Same order-preserving dedup as servers.json above, not unique_by(.tag)
	# (which sorts by tag).
	jq -s '
		(.[0] + .[1]) as $all |
		($all | to_entries | group_by(.value.tag) | map(.[0])) as $first |
		($first | sort_by(.key) | map(.value))
	' "$SR_OUTBOUNDS_STATE_FILE.new" "$tmp_outbounds" >"$SR_OUTBOUNDS_STATE_FILE"
	rm -f "$SR_OUTBOUNDS_STATE_FILE.new"

	# Not `jq -n --argjson list "$(jq ... "$SR_OUTBOUNDS_STATE_FILE")" ...` --
	# piping a large outbounds set (real subscriptions here run well past a
	# hundred servers) through the shell as a single command-line argument
	# hits the OS's ARG_MAX and fails outright ("Argument list too long"),
	# and since `>` truncates its target file before the command even runs,
	# that failure was silently leaving Xray's real outbounds config as a
	# 0-byte file -- confirmed for real on this project's own test router at
	# 192 servers. Reading the state file directly (no shell argument in the
	# middle) and writing to a temp file before the final `mv` avoids both
	# the size limit and ever leaving a truncated file if something does
	# still go wrong mid-write.
	jq '{outbounds: [.[] | del(.subscription)]}' "$SR_OUTBOUNDS_STATE_FILE" >"$SR_OUTBOUNDS_FILE.tmp" && mv "$SR_OUTBOUNDS_FILE.tmp" "$SR_OUTBOUNDS_FILE"

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
	# Contains each subscription's raw URL, secret token included -- same
	# tier as gateway_password_hash, which this project already stores
	# 0600. Re-asserted on every write since `mv` from a freshly-written
	# .new file doesn't inherit any prior chmod, just the default umask.
	chmod 600 "$SR_SUBS_META_FILE" 2>/dev/null || true
}

sr_get_refresh_hours() {
	[ -s "$SR_STATE_DIR/refresh_interval_hours" ] && cat "$SR_STATE_DIR/refresh_interval_hours" || echo "$DEFAULT_REFRESH_HOURS"
}

sr_set_refresh_hours() {
	sr_ensure_dirs
	case "$1" in *[!0-9]*|'') sr_die "refresh interval must be a whole number of hours" ;; esac
	echo "$1" > "$SR_STATE_DIR/refresh_interval_hours"
}

# Auto-refresh is on by default (existing installs keep their current
# behavior). Gates only the *scheduled* path (sr_refresh_due, called from
# cron) -- an explicit "refresh now" click (sr_force_refresh) always runs
# regardless, since that's a deliberate action, not the automatic one this
# toggle is about.
sr_get_auto_refresh_enabled() {
	[ -s "$SR_STATE_DIR/auto_refresh_enabled" ] && cat "$SR_STATE_DIR/auto_refresh_enabled" || echo "1"
}

sr_set_auto_refresh_enabled() {
	sr_ensure_dirs
	case "$1" in true|1) echo 1 > "$SR_STATE_DIR/auto_refresh_enabled" ;; false|0) echo 0 > "$SR_STATE_DIR/auto_refresh_enabled" ;; *) sr_die "expected true/false" ;; esac
}

# Called hourly from cron; only actually refetches once the configured
# interval has elapsed, and only for subscriptions we've successfully
# imported at least once before (nothing to do on a fresh install).
sr_refresh_due() {
	sr_ensure_dirs
	[ "$(sr_get_auto_refresh_enabled)" = "1" ] || { sr_log "refresh: auto-refresh disabled, skipping"; return 0; }
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
	# Marker file, not a plain shell variable -- ok_count="$((ok_count+1))"
	# set inside a `cmd | while read` pipeline lives in a subshell and never
	# survives back to this scope; a file write does.
	ok_marker="$(mktemp)"
	rm -f "$ok_marker"
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
		if ( sr_import "$u" "$l" "$c" "$o" "$lo" "$m" "$v" "$h" ); then
			: >"$ok_marker"
		else
			sr_log "refresh: failed to re-import '$l'"
		fi
	done
	# Restarting Xray is not free (drops the current connection briefly,
	# and resets Observatory's in-memory health data, which can take the
	# better part of an hour to fully re-cover for a large subscription --
	# see failover.go's persistHealth comment) -- doing it unconditionally
	# even when every single label failed to re-import (a transient outage
	# on the provider side, nothing about the router's own state actually
	# changed) traded a real, visible cost for zero benefit.
	if [ -f "$ok_marker" ]; then
		sr_restart_xray
	else
		sr_log "refresh: every subscription failed to re-import, skipping xray restart"
	fi
	rm -f "$ok_marker"
	jq -n --arg now "$now" '{last: ($now|tonumber)}' >"$SR_REFRESH_STATE_FILE"
}

# --- subscriptions as first-class entities: list/delete/refresh-one ---
# SR_SUBS_META_FILE (saved by sr_save_subscription_meta on every import)
# already has everything needed to treat a subscription as its own object
# instead of just a label string stamped on servers/outbounds.

sr_list_subscriptions() {
	sr_ensure_dirs
	[ -s "$SR_SUBS_META_FILE" ] || { echo '[]'; return 0; }
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	jq -n --slurpfile subs "$SR_SUBS_META_FILE" --slurpfile servers "$SR_SERVERS_FILE" '
		($servers[0] // []) as $srv |
		[$subs[0][] | . as $sub | $sub + {server_count: ([$srv[] | select(.subscription == $sub.label)] | length)}]
	'
}

# delete-subscription: removes every server/outbound this label ever
# contributed (same filter sr_import already uses to *replace* a label's
# entries on refresh -- deleting is just replacing with nothing) and drops
# its saved meta entry so it stops being auto-refreshed. Restarts Xray so
# the smaller outbound set actually takes effect; a profile that referenced
# one of the removed servers is left alone here (sr_restart_xray's own
# pre-restart validation is what catches that, same as any other stale-tag
# situation -- see AGENTS.md).
sr_delete_subscription() {
	label="${1:?subscription label required}"
	sr_ensure_dirs
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	[ -s "$SR_OUTBOUNDS_STATE_FILE" ] || echo '[]' >"$SR_OUTBOUNDS_STATE_FILE"

	jq --arg lbl "$label" '[.[] | select(.subscription != $lbl)]' "$SR_SERVERS_FILE" >"$SR_SERVERS_FILE.new"
	mv "$SR_SERVERS_FILE.new" "$SR_SERVERS_FILE"
	jq --arg lbl "$label" '[.[] | select(.subscription != $lbl)]' "$SR_OUTBOUNDS_STATE_FILE" >"$SR_OUTBOUNDS_STATE_FILE.new"
	mv "$SR_OUTBOUNDS_STATE_FILE.new" "$SR_OUTBOUNDS_STATE_FILE"
	# Not `jq -n --argjson list "$(jq ... "$SR_OUTBOUNDS_STATE_FILE")" ...` --
	# piping a large outbounds set (real subscriptions here run well past a
	# hundred servers) through the shell as a single command-line argument
	# hits the OS's ARG_MAX and fails outright ("Argument list too long"),
	# and since `>` truncates its target file before the command even runs,
	# that failure was silently leaving Xray's real outbounds config as a
	# 0-byte file -- confirmed for real on this project's own test router at
	# 192 servers. Reading the state file directly (no shell argument in the
	# middle) and writing to a temp file before the final `mv` avoids both
	# the size limit and ever leaving a truncated file if something does
	# still go wrong mid-write.
	jq '{outbounds: [.[] | del(.subscription)]}' "$SR_OUTBOUNDS_STATE_FILE" >"$SR_OUTBOUNDS_FILE.tmp" && mv "$SR_OUTBOUNDS_FILE.tmp" "$SR_OUTBOUNDS_FILE"

	[ -s "$SR_SUBS_META_FILE" ] || echo '[]' >"$SR_SUBS_META_FILE"
	jq --arg lbl "$label" '[.[] | select(.label != $lbl)]' "$SR_SUBS_META_FILE" >"$SR_SUBS_META_FILE.new"
	mv "$SR_SUBS_META_FILE.new" "$SR_SUBS_META_FILE"
	# Contains each subscription's raw URL, secret token included -- same
	# tier as gateway_password_hash, which this project already stores
	# 0600. Re-asserted on every write since `mv` from a freshly-written
	# .new file doesn't inherit any prior chmod, just the default umask.
	chmod 600 "$SR_SUBS_META_FILE" 2>/dev/null || true

	sr_restart_xray || true
	sr_log "subscription '$label' deleted"
}

# refresh-one: re-runs sr_import with exactly the saved params for one
# label, instead of sr_do_refresh's loop over every saved subscription --
# what the Subscriptions page's per-subscription "Обновить" button calls.
sr_refresh_one() {
	label="${1:?subscription label required}"
	sr_ensure_dirs
	[ -s "$SR_SUBS_META_FILE" ] || sr_die "no saved subscriptions"
	entry="$(jq -c --arg lbl "$label" '.[] | select(.label == $lbl)' "$SR_SUBS_META_FILE")"
	[ -n "$entry" ] || sr_die "unknown subscription '$label'"
	u="$(printf '%s' "$entry" | jq -r '.url')"
	c="$(printf '%s' "$entry" | jq -r '.client')"
	o="$(printf '%s' "$entry" | jq -r '.os')"
	lo="$(printf '%s' "$entry" | jq -r '.locale')"
	m="$(printf '%s' "$entry" | jq -r '.model')"
	v="$(printf '%s' "$entry" | jq -r '.ver')"
	h="$(printf '%s' "$entry" | jq -r '.hwid')"
	sr_import "$u" "$label" "$c" "$o" "$lo" "$m" "$v" "$h"
	sr_restart_xray
}

# --- ping: TCP-connect latency per server ---
# Real usability signal without needing a raw-socket ICMP ping (which would
# need to run as root anyway and gets blocked by some networks/servers);
# curl's time_connect is just the TCP handshake, independent of whether TLS
# or the VPN handshake itself succeeds. Sequential, not backgrounded/parallel
# -- confirmed on real hardware (this project's own test router, ~250MB RAM,
# no swap) that firing many concurrent probes at once (the same mistake
# observatory's enableConcurrency made, see AGENTS.md) spikes load and memory
# enough to produce false timeouts, or worse. Slower for a big subscription,
# but doesn't lie and doesn't risk another OOM.
# SR_PING_FILE now lives in common.sh (genroute.sh's sr_pick_top1 also needs it)
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
	while IFS= read -r s; do
		i=$((i + 1))
		tag="$(printf '%s' "$s" | jq -r '.tag')"
		host="$(printf '%s' "$s" | jq -r '.address')"
		port="$(printf '%s' "$s" | jq -r '.port // 443')"
		sr_ping_one "$tag" "$host" "$port" "$tmp_dir/$i.json"
	done < "$tmp_list"
	rm -f "$tmp_list"

	jq -s '[.[]] | INDEX(.tag) | map_values(.ping_ms)' "$tmp_dir"/*.json 2>/dev/null > "$SR_PING_FILE" || echo '{}' > "$SR_PING_FILE"
	rm -rf "$tmp_dir"
	cat "$SR_PING_FILE"
}

# ping-subscription: same one-at-a-time probing as sr_ping_all, but scoped
# to a single label's servers -- what the Subscriptions page's
# per-subscription "Проверить пинг" button calls. Results are merged into
# the same SR_PING_FILE other subscriptions' cached values already live in,
# not a separate file, so the UI reads ping data from one place regardless
# of which button (per-subscription or "ping everything") last ran.
sr_ping_subscription() {
	label="${1:?subscription label required}"
	sr_require curl; sr_require jq
	sr_ensure_dirs
	[ -s "$SR_SERVERS_FILE" ] || { echo '{}'; return 0; }
	tmp_dir="$(mktemp -d)"
	tmp_list="$(mktemp)"
	jq -c --arg lbl "$label" '.[] | select(.subscription == $lbl)' "$SR_SERVERS_FILE" > "$tmp_list"
	i=0
	while IFS= read -r s; do
		i=$((i + 1))
		tag="$(printf '%s' "$s" | jq -r '.tag')"
		host="$(printf '%s' "$s" | jq -r '.address')"
		port="$(printf '%s' "$s" | jq -r '.port // 443')"
		sr_ping_one "$tag" "$host" "$port" "$tmp_dir/$i.json"
	done < "$tmp_list"
	rm -f "$tmp_list"

	[ -s "$SR_PING_FILE" ] || echo '{}' >"$SR_PING_FILE"
	tmp_new="$(mktemp)"
	jq -s '[.[]] | INDEX(.tag) | map_values(.ping_ms)' "$tmp_dir"/*.json 2>/dev/null > "$tmp_new" || echo '{}' > "$tmp_new"
	# Merge into the existing ping cache (this subscription's tags overwrite
	# their old values, every other subscription's cached pings pass through
	# untouched) rather than replacing the whole file -- POSIX sh has no
	# process substitution, so both inputs to jq -s have to be real files.
	jq -s '.[0] * .[1]' "$SR_PING_FILE" "$tmp_new" > "$SR_PING_FILE.new" && mv "$SR_PING_FILE.new" "$SR_PING_FILE"
	rm -f "$tmp_new"
	rm -rf "$tmp_dir"
	cat "$SR_PING_FILE"
}

# ping-tags: reads server tags one per line from stdin and pings just
# those, sequentially, merging into the same shared ping cache
# sr_ping_all/sr_ping_subscription write to. Scoped to an arbitrary tag
# list rather than a whole subscription -- what genroute.sh's sr_pick_top1
# uses to get a *fresh* reachability check against one profile's own server
# pool (tens of servers) on every regen, instead of relying on
# sr_ping_all's whole-subscription sweep (hundreds of servers, only run
# every couple hours -- see install.sh's cron) which could be stale by the
# time a specific profile's pick actually matters.
sr_ping_tags() {
	sr_require curl; sr_require jq
	sr_ensure_dirs
	[ -s "$SR_SERVERS_FILE" ] || { echo '{}'; return 0; }
	tags_file="$(mktemp)"
	cat > "$tags_file"
	if [ ! -s "$tags_file" ]; then
		rm -f "$tags_file"
		[ -s "$SR_PING_FILE" ] && cat "$SR_PING_FILE" || echo '{}'
		return 0
	fi

	tmp_dir="$(mktemp -d)"
	i=0
	while IFS= read -r tag; do
		[ -n "$tag" ] || continue
		i=$((i + 1))
		entry="$(jq -c --arg t "$tag" '[.[] | select(.tag == $t)][0] // empty' "$SR_SERVERS_FILE")"
		[ -n "$entry" ] || continue
		host="$(printf '%s' "$entry" | jq -r '.address')"
		port="$(printf '%s' "$entry" | jq -r '.port // 443')"
		sr_ping_one "$tag" "$host" "$port" "$tmp_dir/$i.json"
	done < "$tags_file"
	rm -f "$tags_file"

	[ -s "$SR_PING_FILE" ] || echo '{}' >"$SR_PING_FILE"
	tmp_new="$(mktemp)"
	jq -s '[.[]] | INDEX(.tag) | map_values(.ping_ms)' "$tmp_dir"/*.json 2>/dev/null > "$tmp_new" || echo '{}' > "$tmp_new"
	jq -s '.[0] * .[1]' "$SR_PING_FILE" "$tmp_new" > "$SR_PING_FILE.new" && mv "$SR_PING_FILE.new" "$SR_PING_FILE"
	rm -f "$tmp_new"
	rm -rf "$tmp_dir"
	cat "$SR_PING_FILE"
}

case "${1:-}" in
	import) sr_import "$2" "${3:-sub}" "${4:-smartroute}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" ;;
	list) sr_ensure_dirs; [ -s "$SR_SERVERS_FILE" ] && cat "$SR_SERVERS_FILE" || echo '[]' ;;
	list-subscriptions) sr_list_subscriptions ;;
	delete-subscription) sr_delete_subscription "${2:-}" ;;
	refresh) sr_refresh_due ;;
	refresh-now) sr_force_refresh ;;
	refresh-one) sr_refresh_one "${2:-}" ;;
	get-refresh-hours) sr_get_refresh_hours ;;
	set-refresh-hours) sr_set_refresh_hours "${2:-}" ;;
	get-auto-refresh-enabled) sr_get_auto_refresh_enabled ;;
	set-auto-refresh-enabled) sr_set_auto_refresh_enabled "${2:-}" ;;
	ping) sr_ping_all ;;
	ping-subscription) sr_ping_subscription "${2:-}" ;;
	ping-tags) sr_ping_tags ;;
	*) echo "usage: $0 {import <url> [label] [client] [os] [locale] [model] [ver] [hwid]|list|list-subscriptions|delete-subscription <label>|refresh|refresh-now|refresh-one <label>|get-refresh-hours|set-refresh-hours <n>|get-auto-refresh-enabled|set-auto-refresh-enabled <true|false>|ping|ping-subscription <label>|ping-tags (tags on stdin)}" >&2; exit 1 ;;
esac
