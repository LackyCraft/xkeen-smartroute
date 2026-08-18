#!/bin/sh
# lib/genroute.sh — turn saved "profiles" (domain source + chosen servers + mode)
# into Xray routing.rules / routing.balancers fragments consumed by xkeen, then
# ask xkeen to reload. This is the piece that actually implements "route domain
# list X only through server(s) Y, auto-pick the fastest one".
#
# Usage:
#   genroute.sh save <profile.json>   # write/overwrite one profile, then regen
#   genroute.sh delete <name>         # remove a profile, then regen
#   genroute.sh regen                 # rebuild routing+balancer from all profiles
#   genroute.sh list                  # print all profiles as a JSON array

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

domain_match_array() {
	# profile json on stdin -> jq array of Xray "domain" match strings.
	# "any" (or a profile with no domain_source at all -- device-only
	# profiles, see device_match_array below) means "don't restrict by
	# domain", so the caller omits the "domain" key from the rule entirely
	# rather than getting an empty array (an empty non-null "domain":[]
	# would match nothing at all, the opposite of "any").
	src_type="$(jq -r '.domain_source.type // "any"' "$1")"
	if [ "$src_type" = "any" ]; then
		jq -n '[]'
	elif [ "$src_type" = "geosite" ]; then
		val="$(jq -r '.domain_source.value' "$1")"
		jq -n --arg v "geosite:$val" '[$v]'
	else
		file="$SR_LISTS_DIR/$(jq -r '.domain_source.file' "$1")"
		if [ -f "$file" ]; then
			# `select(A) and (B)` is not "keep rows where A and B" -- select()
			# either passes its *input* through unchanged or drops it, and
			# `and` then reduces whatever it passed through (a real domain
			# string, i.e. truthy) plus B's boolean into a bare `true`/`false`,
			# replacing the actual domain text with a boolean in the output.
			# Every "custom" domain-list profile was silently generating
			# {"domain":[true]} instead of {"domain":["example.com"]} because
			# of this -- Xray never matches a real request's Host/SNI against
			# a JSON boolean, so traffic for every custom-list-only profile
			# fell straight through to the next rule (unnoticed until now
			# because every profile actually exercised was geosite-based,
			# which doesn't take this branch). Both conditions belong inside
			# the same select() so it evaluates a single boolean and, on
			# success, still emits the original line.
			jq -R -s 'split("\n") | map(select((length>0) and (startswith("#")|not)))' "$file" 2>/dev/null \
				|| jq -n '[]'
		else
			jq -n '[]'
		fi
	fi
}

# device_match_array: profile json -> jq array of Xray "source" match
# strings (IPv4 addresses or CIDR blocks) -- Policy-Based Routing by device
# ("only the TV goes through VPN") instead of by domain. Optional on every
# profile; a profile can match by domain only (existing behavior), by
# device only (empty/absent domain_source), or both at once ("only the TV,
# only for this streaming service").
device_match_array() {
	jq -c '[(.devices // [])[] | select(length > 0)]' "$1"
}

# build_rule_fields <profile.json> -> partial JSON object with "domain"
# and/or "source" keys, whichever the profile actually restricts by. Merged
# with {type:"field", outboundTag|balancerTag:...} by the caller. jq's `+`
# on objects unions keys, so accumulating like this cleanly omits whichever
# side is unrestricted instead of writing a key that matches nothing.
build_rule_fields() {
	domains="$(domain_match_array "$1")"
	devices="$(device_match_array "$1")"
	jq -n --argjson d "$domains" --argjson s "$devices" \
		'{} + (if ($d|length) > 0 then {domain:$d} else {} end) + (if ($s|length) > 0 then {source:$s} else {} end)'
}

# sr_pick_top1: profile json -> the single best server tag from its
# .servers pool. Two independent signals feed the ranking, and neither one
# alone is trustworthy:
#   - A *fresh* ping, scoped to just this profile's pool (via
#     subscription.sh's sr_ping_tags -- tens of servers, not the whole
#     subscription, so cheap enough to do on every regen). Confirms the
#     server is reachable *right now*, which health.json alone can't: it's
#     only refreshed as fast as observatory's own slow, one-at-a-time sweep
#     reaches each outbound (confirmed live: ~20-30s per server, so full
#     coverage of a large subscription takes the better part of an hour,
#     and resets to empty on every Xray restart -- see AGENTS.md).
#   - health.json (smartroute-gateway's failover.go polls
#     ObservatoryService.GetOutboundStatus every 20s and persists the full
#     tag->{alive,delay_ms} map). This is a *real* VLESS/REALITY connection
#     + HTTP GET through the outbound, not a bare TCP connect -- confirmed
#     live that a node with broken REALITY camouflage on the provider's
#     side answers a raw TCP connect instantly (passes the fresh ping
#     above) while every real proxied request fails with "REALITY:
#     received real certificate (potential MITM or redirection)". A plain
#     ping can never catch that; only observatory's real handshake can.
#     Used even when stale (up to however long since Xray's last restart)
#     since a broken REALITY config doesn't fix itself between probes.
#
# Ranking, best first:
#   0. Fresh ping succeeded AND health.json says alive -- both checks agree
#      the server actually works right now. Sorted by health.json's real
#      delay_ms (a truer speed signal than raw TCP-connect time).
#   1. Fresh ping succeeded, no health.json verdict yet (observatory hasn't
#      reached it this sweep) -- reachable, unconfirmed either way. Sorted
#      by the fresh ping's own ms.
#   2. Fresh ping succeeded but health.json says dead -- reachable at the
#      TCP level but observatory caught a real protocol failure (the exact
#      REALITY case above). Deliberately ranked below "unconfirmed": we
#      trust a real negative verdict over no verdict at all.
#   3. Fresh ping failed outright -- last resort only, reached if every
#      single candidate in the pool failed to even connect.
# Falls back to the pool's first entry if nothing has any data at all
# (fresh ping AND health.json both empty -- e.g. this router has no
# internet path to test with right now). Returns empty only if .servers is
# itself empty.
#
# This exists instead of an Xray `balancerTag`/`routing.balancers` entry
# because of a confirmed Xray-core 26.2.6 bug (see AGENTS.md, "Common
# failure modes" -- every routing rule stops matching, including itself and
# an unrelated catch-all, the instant *any* balancerTag rule exists anywhere
# in routing.rules; reproduced with both leastPing and random strategies,
# with the balancer alone/first/last, single- and multi-file confdir, and
# with a selector containing only outbounds referenced nowhere else --
# filed upstream: https://github.com/XTLS/Xray-core/issues/6642). Picking
# the fastest server ourselves and emitting a plain `outboundTag` rule --
# the exact same code path `mode: "fixed"` already uses and that's confirmed
# working -- sidesteps the bug entirely instead of waiting on it.
sr_pick_top1() {
	pf="$1"
	[ -s "$SR_PING_FILE" ] || echo '{}' >"$SR_PING_FILE"
	[ -s "$SR_HEALTH_FILE" ] || echo '{}' >"$SR_HEALTH_FILE"
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	# A profile's .servers pool is a tag list frozen at save time -- a
	# subscription refresh since then can retire any of those tags (a node
	# that roamed to a new IP gets an entirely new tag, see subscription.sh's
	# tag-stability comment). Picking a since-retired tag produces a rule
	# Xray logs as "non existing outTag" and silently can't route at all
	# (confirmed live: happened for real a few hours after a profile save,
	# once the hourly subscription refresh cron had run) -- so the pool gets
	# filtered down to currently-known tags (cross-referenced against
	# servers.json, the live subscription state) before picking.
	servers="$(jq -c --slurpfile known "$SR_SERVERS_FILE" '
		([$known[0][].tag]) as $valid |
		(.servers // [] | map(select(. as $t | $valid | index($t) != null)))
	' "$pf")"
	[ "$(echo "$servers" | jq 'length')" -gt 0 ] || return 0

	echo "$servers" | jq -r '.[]' | sh "$SCRIPT_DIR/subscription.sh" ping-tags >/dev/null 2>&1

	jq -rn --argjson servers "$servers" --slurpfile ping "$SR_PING_FILE" --slurpfile health "$SR_HEALTH_FILE" '
		($ping[0] // {}) as $p |
		($health[0] // {}) as $h |
		($servers | map(
			{
				tag: .,
				tier: (if ($p[.] != null and $h[.].alive == true) then 0
				       elif ($p[.] != null and $h[.] == null) then 1
				       elif ($p[.] != null) then 2
				       else 3 end),
				ms: (if ($h[.].alive == true) then $h[.].delay_ms else ($p[.] // 999999999) end)
			}
		) | sort_by(.tier, .ms) | .[0].tag) as $best |
		($best // $servers[0] // empty)
	'
}

sr_regen() {
	sr_ensure_dirs

	# sr_pick_top1 now does a real, network-bound ping pass per balancer-mode
	# profile (see its own comment) instead of pure local file processing,
	# so a regen can legitimately take a while with several such profiles.
	# The cron calling this runs every 3 minutes (install.sh); without a
	# lock, a slow run overlapping the next tick would mean two regens
	# racing to ping the same pools and write the same routing file at
	# once. mkdir is atomic on every filesystem this project runs on
	# (unlike a lockfile written with plain redirection), so it's a safe
	# mutex without needing flock (not on this busybox). A stale lock (this
	# process killed mid-run) would wedge every future regen forever, so a
	# lock older than 5 minutes -- comfortably more than one regen should
	# ever take -- is treated as abandoned and reclaimed rather than
	# trusted.
	lock_dir="$SR_STATE_DIR/.regen.lock"
	if ! mkdir "$lock_dir" 2>/dev/null; then
		lock_age=999999
		if [ -d "$lock_dir" ]; then
			lock_age=$(( $(date +%s) - $(date -r "$lock_dir" +%s 2>/dev/null || echo 0) ))
		fi
		if [ "$lock_age" -lt 300 ]; then
			sr_log "regen already in progress, skipping this run"
			return 0
		fi
		sr_log "reclaiming stale regen lock (${lock_age}s old)"
		rm -rf "$lock_dir"
		mkdir "$lock_dir" 2>/dev/null || return 0
	fi
	trap 'rm -rf "$lock_dir"' EXIT INT TERM

	rules="[]"
	current="{}"

	for pf in "$SR_PROFILES_DIR"/*.json; do
		[ -e "$pf" ] || continue
		name="$(jq -r '.name' "$pf")"
		mode="$(jq -r '.mode' "$pf")"
		fields="$(build_rule_fields "$pf")"

		if [ "$mode" = "fixed" ]; then
			target_tag="$(jq -r '.fixed_server' "$pf")"
		else
			target_tag="$(sr_pick_top1 "$pf")"
		fi
		[ -n "$target_tag" ] || { sr_log "profile '$name' has no servers, skipping"; continue; }
		rule="$(echo "$fields" | jq --arg tag "$target_tag" '. + {type:"field", outboundTag:$tag}')"
		rules="$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')"
		current="$(echo "$current" | jq --arg name "$name" --arg tag "$target_tag" '. + {($name): $tag}')"
	done

	# current.json (profile name -> the tag actually picked this regen) is
	# what lets the Profiles page show a real server name for balancer-mode
	# profiles instead of just "N servers", and lets it pair that name with
	# smartroute-gateway's live activity signal (GET /activity, see
	# gateway/activity.go) for the "this profile is passing traffic right
	# now" dot. Same unchanged-skip discipline as routing.smartroute.json
	# below -- only touch flash when the picked tag actually moved.
	new_current="$(echo "$current" | jq -S .)"
	if [ ! -s "$SR_CURRENT_FILE" ] || [ "$(cat "$SR_CURRENT_FILE")" != "$new_current" ]; then
		printf '%s' "$new_current" >"$SR_CURRENT_FILE"
	fi

	# Any domain not covered by one of our profiles needs an explicit
	# "everything else -> direct" rule, or unmatched traffic on the
	# redirect/tproxy inbound has nowhere defined to go.
	#
	# This used to also be justified as "makes it the effective final word
	# regardless of what xkeen's own 05_routing.json says", on the assumption
	# that Xray's confdir merge always evaluates this file's rules before
	# xkeen's own. That assumption was wrong -- proven by a real leak where
	# xkeen's own ".ru domains -> direct" rule (05_routing.json) won over an
	# explicit SmartRoute profile rule for the same domain. install.sh now
	# strips that domain-specific rule out of 05_routing.json entirely rather
	# than relying on load-order precedence (see its own comment + AGENTS.md,
	# "05_routing.json .ru precedence leak"), so this catch-all no longer
	# needs to out-race anything -- it's just the plain fallback for domains
	# genuinely outside every profile.
	catchall='{"type":"field","inboundTag":["redirect","tproxy"],"outboundTag":"direct"}'
	rules="$(echo "$rules" | jq --argjson r "$catchall" '. + [$r]')"

	new_routing="$(jq -n --argjson rules "$rules" '{routing:{domainStrategy:"IPIfNonMatch", rules:$rules}}')"

	# No routing.balancers anymore -- see sr_pick_top1's comment above for
	# why balancerTag is unused for now. Remove any stale file left over
	# from before this change (or from a pre-fix profile save) so it doesn't
	# reintroduce the bug next restart.
	rm -f "$SR_BALANCER_FILE"

	# The observatory block itself is independent of routing.balancers --
	# it's a standalone prober, and 00_api.smartroute.json's "services" list
	# always includes ObservatoryService (the Status page / gateway's own
	# failover.go health polling depend on it, not just leastPing balancers).
	# Xray fails to start ("not all dependencies are resolved") if
	# ObservatoryService is enabled in the API but no observatory block
	# exists at all, so this has to be written unconditionally now, not only
	# "while a balancer needs it" like before. Static content -- nothing
	# here ever changes between regens, so it plays no part in the
	# unchanged-skip check below.
	jq -n '{observatory:{subjectSelector:["sr_"], probeUrl:"https://www.gstatic.com/generate_204", probeInterval:"30s"}}' >"$SR_OBSERVATORY_FILE"

	# Restarting Xray resets observatory's in-memory probe progress back to
	# zero -- confirmed live: health.json (smartroute-gateway's persisted
	# copy of the same data) dropped from dozens of known outbounds to a
	# single one immediately after a restart. sr_pick_top1's own top-1
	# choice rarely changes between one regen and the next (same servers,
	# same health data most of the time), so restarting Xray on every single
	# regen -- which the 3-minute cron now calls far more often than the old
	# 30-minute one -- would keep observatory permanently stuck re-probing
	# from scratch, never accumulating enough coverage for sr_pick_top1 to
	# actually use it. Only restart when the rules content genuinely
	# changed; comparing to what's already on disk (not some remembered
	# in-script state) means a manual edit or an interrupted previous run
	# still gets picked up correctly on the next regen either way.
	if [ -s "$SR_ROUTING_FILE" ] && [ "$(cat "$SR_ROUTING_FILE")" = "$new_routing" ]; then
		sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s)), unchanged -- skipping restart"
		return 0
	fi
	printf '%s' "$new_routing" >"$SR_ROUTING_FILE"

	sr_restart_xray
	sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s))"
}

case "${1:-}" in
	save)
		sr_ensure_dirs
		[ -n "${2:-}" ] && [ -f "$2" ] || sr_die "profile json file required"
		name="$(jq -r '.name' "$2")"
		[ -n "$name" ] && [ "$name" != "null" ] || sr_die "profile json must have a .name"

		# A profile with neither a domain restriction nor a device
		# restriction would generate a rule matching every domain from
		# every device -- silently shadowing every other profile (rule
		# order = array order, first match wins) and our own catch-all.
		# Reject it at save time with a clear reason instead of letting it
		# through to become a confusing routing bug.
		src_type="$(jq -r '.domain_source.type // "any"' "$2")"
		n_devices="$(jq '[(.devices // [])[] | select(length > 0)] | length' "$2")"
		if [ "$src_type" = "any" ] && [ "$n_devices" -eq 0 ]; then
			sr_die "profile must match by domain, by device, or both -- got neither"
		fi

		# IPv4 address or CIDR only -- Xray's routing "source" field doesn't
		# accept anything else, and a malformed entry here would otherwise
		# only surface as an opaque Xray config-validation failure much
		# later, in sr_restart_xray, far from the actual mistake.
		for dev in $(jq -r '(.devices // [])[]' "$2" 2>/dev/null); do
			case "$dev" in
				*[!0-9./]*) sr_die "invalid device entry '$dev' -- expected an IPv4 address or CIDR (e.g. 192.168.1.50 or 192.168.1.0/24)" ;;
			esac
		done

		cp "$2" "$SR_PROFILES_DIR/$name.json"
		sr_regen
		;;
	delete)
		[ -n "${2:-}" ] || sr_die "profile name required"
		rm -f "$SR_PROFILES_DIR/$2.json"
		sr_regen
		;;
	regen) sr_regen ;;
	list)
		sr_ensure_dirs
		if ls "$SR_PROFILES_DIR"/*.json >/dev/null 2>&1; then
			jq -s '.' "$SR_PROFILES_DIR"/*.json
		else
			echo '[]'
		fi
		;;
	*) echo "usage: $0 {save <profile.json>|delete <name>|regen|list}" >&2; exit 1 ;;
esac
