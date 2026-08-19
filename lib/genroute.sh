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

# ip_match_array: profile json -> jq array of Xray "ip" match strings
# (IPv4/IPv6 addresses or CIDR blocks). Optional, separate from domain
# matching entirely -- see build_rule_list's own comment for why.
ip_match_array() {
	jq -c '[(.ip_ranges // [])[] | select(length > 0)]' "$1"
}

# build_rule_list <profile.json> -> jq array of partial JSON objects, one
# per Xray routing rule this profile needs (usually one, sometimes two).
# Each has "domain" and/or "source", or "ip" and/or "source" -- never
# "domain" and "ip" on the *same* rule object, and that split is the whole
# point of this function: Xray ANDs every field present on one rule
# together, so a single {domain:[...], ip:[...]} rule would mean "matches
# this domain list AND is this destination IP" (matches almost nothing),
# not the "matches this domain list OR is this destination IP" a profile
# actually wants. Emitting them as separate rule objects -- both pointing at
# the same outboundTag by the caller -- gets OR semantics for free from
# Xray's own "first matching rule in the array wins" behavior instead.
#
# ip_ranges exists because plenty of real apps' *native* clients don't route
# by domain at all: Telegram's desktop/mobile apps talk MTProto, which
# mostly dials known datacenter IP ranges directly with no DNS lookup or TLS
# SNI for Xray's sniffer to see -- confirmed for real: web.telegram.org
# (ordinary HTTPS, a real SNI, matched fine by geosite:telegram) worked
# while the native apps on phone/desktop didn't, on the exact same profile.
# A domain-only rule can never catch that traffic; only an IP/CIDR-based one
# can. Each entry is Telegram's/whatever app's own published datacenter
# ranges, pasted in by the user -- SmartRoute doesn't hardcode any app's IP
# list itself (they drift over time and aren't something to bit-rot in this
# repo).
build_rule_list() {
	domains="$(domain_match_array "$1")"
	devices="$(device_match_array "$1")"
	ips="$(ip_match_array "$1")"
	jq -n --argjson d "$domains" --argjson s "$devices" --argjson i "$ips" '
		[
			(if ($d|length) > 0 or ($i|length) == 0 then
				{} + (if ($d|length) > 0 then {domain:$d} else {} end) + (if ($s|length) > 0 then {source:$s} else {} end)
			else empty end),
			(if ($i|length) > 0 then
				{ip:$i} + (if ($s|length) > 0 then {source:$s} else {} end)
			else empty end)
		]
	'
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
	skip_fresh_ping="${2:-}"
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

	# A fresh pool-scoped ping is a real network operation (one TCP connect
	# per server, sequential) -- fine for the 3-minute cron's own background
	# regen, but interactive callers (the Profiles page's Save/Delete
	# buttons, via genroute.sh's "save"/"delete" cases) can't afford to block
	# on it: measured 71s for just 3 profiles' pools on this hardware, well
	# past both ubus/rpcd's own call timeout and the browser's XHR timeout.
	# Confirmed live -- Save "worked" (the profile file and routing did get
	# written) but the UI never got the response back, leaving the button
	# stuck on "Сохраняю..." until a manual page reload. Callers that pass a
	# truthy $2 skip the fresh probe entirely and rank purely on whatever
	# ping.json/health.json already have -- at most a few minutes stale
	# (kept fresh by the cron's own regen + subscription.sh's periodic ping
	# sweep), which sr_pick_top1's tiering already treats as a perfectly
	# valid signal, not an error case.
	[ -n "$skip_fresh_ping" ] || echo "$servers" | jq -r '.[]' | sh "$SCRIPT_DIR/subscription.sh" ping-tags >/dev/null 2>&1

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
	skip_fresh_ping="${1:-}"
	sr_ensure_dirs

	# sr_pick_top1 now does a real, network-bound ping pass per balancer-mode
	# profile (see its own comment) instead of pure local file processing,
	# so a regen can legitimately take a while with several such profiles --
	# unless the caller passed skip_fresh_ping (see sr_pick_top1's own
	# comment on why "save"/"delete" below always do).
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
	profile_tags="[]"

	for pf in "$SR_PROFILES_DIR"/*.json; do
		[ -e "$pf" ] || continue
		name="$(jq -r '.name' "$pf")"
		mode="$(jq -r '.mode' "$pf")"
		field_list="$(build_rule_list "$pf")"

		if [ "$mode" = "fixed" ]; then
			target_tag="$(jq -r '.fixed_server' "$pf")"
			# sr_pick_top1 already filters a balancer profile's pool down to
			# tags that still exist in servers.json (a subscription refresh
			# can rename/remove a tag out from under a saved profile -- see
			# docs/subscription-update.md); a fixed profile's single tag
			# never went through that check at all. Emitting a rule with a
			# nonexistent outboundTag doesn't just break this one profile --
			# Xray's config validator rejects the *entire* merged routing
			# file over it, which _sr_xray_validate() then correctly refuses
			# to apply, silently freezing every profile's routing updates
			# (not just this one) until a human notices and fixes it by
			# hand. Confirmed reachable for real: sr_remap_profile_tags
			# deliberately leaves a removed fixed_server's stale tag in
			# place (for the UI to show what disappeared) rather than
			# nulling it out.
			if [ -n "$target_tag" ] && [ "$target_tag" != "null" ] && ! jq -e --arg t "$target_tag" '.[] | select(.tag == $t)' "$SR_SERVERS_FILE" >/dev/null 2>&1; then
				sr_log "profile '$name' has fixed_server '$target_tag' which no longer exists (removed by a subscription refresh?), skipping"
				target_tag=""
			fi
		else
			target_tag="$(sr_pick_top1 "$pf" "$skip_fresh_ping")"
		fi
		[ -n "$target_tag" ] || { sr_log "profile '$name' has no servers, skipping"; continue; }
		# build_rule_list can return more than one rule fragment (a plain
		# domain rule plus a separate ip_ranges rule -- see its own comment
		# for why they can't be merged into one) -- all of them route to the
		# same target_tag, so they're just appended as independent entries.
		new_rules="$(echo "$field_list" | jq --arg tag "$target_tag" 'map(. + {type:"field", outboundTag:$tag})')"
		rules="$(echo "$rules" | jq --argjson r "$new_rules" '. + $r')"
		current="$(echo "$current" | jq --arg name "$name" --arg tag "$target_tag" '. + {($name): $tag}')"
		# The whole candidate pool (not just target_tag, the one currently
		# picked) -- sr_observatory_selector below needs every server this
		# profile *could* switch to ranked and fresh, not only today's winner.
		pool="$(jq -c '(.servers // []) + [.fixed_server // empty] | map(select(length > 0))' "$pf")"
		profile_tags="$(echo "$profile_tags" | jq -c --argjson p "$pool" '(. + $p) | unique')"
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
	# "while a balancer needs it" like before.
	#
	# subjectSelector used to be a blanket ["sr_"] -- every server in the
	# subscription. That doesn't work in practice: this project restarts
	# Xray whenever a balancer profile's top pick changes (routing.json
	# content changed, which can happen every few minutes as fresh pings
	# come in close to tied), and *any* Xray restart resets Observatory's
	# in-memory probe progress back to zero -- confirmed live: health.json
	# coverage got stuck around 60-80 of 130 servers, never converging,
	# because each restart made it start over from the alphabetically-first
	# tag again. Xray's own engine has no concept of "priority" or "resume
	# where I left off" either -- background() in observer.go just marches
	# through subjectSelector alphabetically, every time, from scratch.
	#
	# Instead of asking Xray to cover everything every time, subjectSelector
	# is recomputed on every regen to hold only what's actually *stale*
	# right now (missing from health.json, or older than the configurable
	# observatory_period_min -- see sr_get_observatory_period_min in
	# common.sh) -- and if any profile-referenced server is stale, *only*
	# those, so profile servers always win the priority Xray itself can't be
	# told to give them. Once every profile tag is fresh, the selector falls
	# back to whatever else in the subscription is stale, so the rest still
	# eventually gets covered, just never at the expense of what's actually
	# routing traffic right now. If nothing anywhere is stale, the selector
	# is empty and Observer.Start() simply doesn't spawn its background loop
	# at all until the next regen finds something due again.
	#
	# This also makes "don't start a new full pass until the last one
	# finished" automatic rather than a separate flag to track: health.json's
	# own checked_at timestamps (merged across restarts, never wholesale
	# overwritten -- see gateway/failover.go's persistHealth) are the single
	# source of truth for what still needs doing. A tag drops out of the
	# selector the moment it's freshly reprobed and stays out until it goes
	# stale again, so a restart can never cause redundant rework -- at worst
	# it loses whatever single probe was in flight at that exact moment
	# (up to smartroute-gateway's own 20s poll granularity), never a whole
	# pass's worth of progress.
	period_min="$(sr_get_observatory_period_min)"
	period_sec=$((period_min * 60))
	[ -s "$SR_HEALTH_FILE" ] || echo '{}' >"$SR_HEALTH_FILE"
	[ -s "$SR_SERVERS_FILE" ] || echo '[]' >"$SR_SERVERS_FILE"
	all_tags="$(jq -c '[.[].tag]' "$SR_SERVERS_FILE")"
	profile_tags_known="$(jq -cn --argjson all "$all_tags" --argjson p "$profile_tags" '$all - ($all - $p)')"
	other_tags="$(jq -cn --argjson all "$all_tags" --argjson p "$profile_tags" '$all - $p')"
	stale_of() {
		# candidate tag array (arg) -> jq array of the stale subset per
		# health.json's checked_at + the configured period. probeInterval
		# is the pause AFTER each probe, not a rate limit on concurrency
		# (that's enableConcurrency, deliberately left off -- see AGENTS.md
		# on why concurrent probing OOMs this hardware); a real "0s" can't
		# be used to remove it though -- observer.go checks `!= 0` to
		# decide whether a value was configured at all, so a literal zero
		# silently falls back to Xray's own 10s default. "1ms" is the
		# practical zero.
		jq -cn --argjson tags "$1" --slurpfile health "$SR_HEALTH_FILE" --argjson period_sec "$period_sec" '
			($health[0] // {}) as $h |
			(now) as $n |
			[$tags[] | select(
				($h[.] == null) or
				( (($h[.].checked_at // "1970-01-01T00:00:00Z") | rtrimstr("Z") | split(".")[0] + "Z" | fromdateiso8601) as $c |
					($n - $c) > $period_sec )
			)]
		'
	}
	stale_profile="$(stale_of "$profile_tags_known")"
	if [ "$(echo "$stale_profile" | jq 'length')" -gt 0 ]; then
		selector="$stale_profile"
	else
		selector="$(stale_of "$other_tags")"
	fi
	new_observatory="$(jq -n --argjson sel "$selector" '{observatory:{subjectSelector:$sel, probeUrl:"https://www.gstatic.com/generate_204", probeInterval:"1ms"}}')"

	# Restarting Xray is the only way to apply either a new routing pick or
	# a new observatory selector -- so a restart is needed whenever *either*
	# genuinely changed, not just routing. Comparing to what's already on
	# disk (not some remembered in-script state) means a manual edit or an
	# interrupted previous run still gets picked up correctly either way.
	routing_changed=1
	[ -s "$SR_ROUTING_FILE" ] && [ "$(cat "$SR_ROUTING_FILE")" = "$new_routing" ] && routing_changed=0
	observatory_changed=1
	[ -s "$SR_OBSERVATORY_FILE" ] && [ "$(cat "$SR_OBSERVATORY_FILE")" = "$new_observatory" ] && observatory_changed=0

	printf '%s' "$new_routing" >"$SR_ROUTING_FILE"
	printf '%s' "$new_observatory" >"$SR_OBSERVATORY_FILE"

	if [ "$routing_changed" -eq 0 ] && [ "$observatory_changed" -eq 0 ]; then
		sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s)), unchanged -- skipping restart"
		return 0
	fi

	sr_restart_xray
	sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s)), observatory watching $(echo "$selector" | jq 'length') stale tag(s)"
}

case "${1:-}" in
	save)
		sr_ensure_dirs
		[ -n "${2:-}" ] && [ -f "$2" ] || sr_die "profile json file required"
		name="$(jq -r '.name' "$2")"
		[ -n "$name" ] && [ "$name" != "null" ] || sr_die "profile json must have a .name"

		# A profile matching by none of domain, device, or ip_ranges would
		# generate a rule matching every domain from every device --
		# silently shadowing every other profile (rule order = array order,
		# first match wins) and our own catch-all. Reject it at save time
		# with a clear reason instead of letting it through to become a
		# confusing routing bug.
		src_type="$(jq -r '.domain_source.type // "any"' "$2")"
		n_devices="$(jq '[(.devices // [])[] | select(length > 0)] | length' "$2")"
		n_ip_ranges="$(jq '[(.ip_ranges // [])[] | select(length > 0)] | length' "$2")"
		if [ "$src_type" = "any" ] && [ "$n_devices" -eq 0 ] && [ "$n_ip_ranges" -eq 0 ]; then
			sr_die "profile must match by domain, device, or IP range -- got none"
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

		# IPv4/IPv6 address or CIDR only, same reasoning as devices above --
		# Xray's "ip" routing field rejects anything else outright.
		for ipr in $(jq -r '(.ip_ranges // [])[]' "$2" 2>/dev/null); do
			case "$ipr" in
				*[!0-9a-fA-F.:/]*) sr_die "invalid IP range '$ipr' -- expected an IPv4/IPv6 address or CIDR (e.g. 91.108.56.0/22)" ;;
			esac
		done

		cp "$2" "$SR_PROFILES_DIR/$name.json"
		# skip_fresh_ping=1: an interactive Save can't block on a network
		# probe of every balancer-mode profile's pool (see sr_pick_top1's
		# comment) -- rank on whatever ping.json/health.json already have,
		# the next cron regen (<=3min) fills in anything genuinely new.
		sr_regen 1
		;;
	delete)
		[ -n "${2:-}" ] || sr_die "profile name required"
		rm -f "$SR_PROFILES_DIR/$2.json"
		sr_regen 1
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
	get-observatory-period) sr_get_observatory_period_min ;;
	set-observatory-period) sr_set_observatory_period_min "${2:-}" ;;
	*) echo "usage: $0 {save <profile.json>|delete <name>|regen|list|get-observatory-period|set-observatory-period <minutes>}" >&2; exit 1 ;;
esac
