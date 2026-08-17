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
			jq -R -s 'split("\n") | map(select(length>0) and (startswith("#")|not))' "$file" 2>/dev/null \
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

sr_regen() {
	sr_ensure_dirs
	rules="[]"
	balancers="[]"

	for pf in "$SR_PROFILES_DIR"/*.json; do
		[ -e "$pf" ] || continue
		name="$(jq -r '.name' "$pf")"
		mode="$(jq -r '.mode' "$pf")"
		fields="$(build_rule_fields "$pf")"

		if [ "$mode" = "fixed" ]; then
			target_tag="$(jq -r '.fixed_server' "$pf")"
			rule="$(echo "$fields" | jq --arg tag "$target_tag" '. + {type:"field", outboundTag:$tag}')"
			rules="$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')"
		else
			bal_tag="bal_$name"
			servers="$(jq -c '.servers' "$pf")"
			balancer="$(jq -n --arg tag "$bal_tag" --argjson sel "$servers" \
				'{tag:$tag, selector:$sel, strategy:{type:"leastPing"}}')"
			balancers="$(echo "$balancers" | jq --argjson b "$balancer" '. + [$b]')"
			rule="$(echo "$fields" | jq --arg tag "$bal_tag" '. + {type:"field", balancerTag:$tag}')"
			rules="$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')"
		fi
	done

	# xkeen's own base 05_routing.json ends with an unconditional catch-all
	# ("everything else on the redirect/tproxy inbound") pointing at
	# outboundTag "vless-reality" -- the placeholder outbound install.sh
	# deliberately removes (it ships with empty address/id/publicKey and
	# would stop Xray from starting at all). Once real LAN traffic actually
	# flows through the redirect (lib/redirect.sh, not xkeen's own broken
	# -ap), any domain that isn't covered by one of our profiles hits that
	# dead tag and just hangs instead of going out directly. Config-file
	# load order means our rules already run before xkeen's own, so
	# appending an explicit "anything else -> direct" rule here both fixes
	# that and makes it the effective final word regardless of what xkeen's
	# own file says.
	catchall='{"type":"field","inboundTag":["redirect","tproxy"],"outboundTag":"direct"}'
	rules="$(echo "$rules" | jq --argjson r "$catchall" '. + [$r]')"

	jq -n --argjson rules "$rules" '{routing:{domainStrategy:"IPIfNonMatch", rules:$rules}}' >"$SR_ROUTING_FILE"
	jq -n --argjson bal "$balancers" '{routing:{balancers:$bal}}' >"$SR_BALANCER_FILE"

	# The "leastPing" strategy used by every balancer above depends on Xray's
	# observatory feature to actually measure ping and pick a winner --
	# without an observatory block whose subjectSelector matches at least
	# the balanced outbounds, Xray fails to start at all ("not all
	# dependencies are resolved", with no further detail pointing at why).
	# Only write it while it's actually needed so a fixed-server-only setup
	# doesn't carry a dangling probe config.
	#
	# enableConcurrency (probe every candidate in parallel instead of one at
	# a time) was tried and reverted: on real hardware (a ~250MB-RAM router,
	# no swap) a 166-server subscription under concurrent probing spiked
	# load average to 3.2+ and free memory from ~110MB to ~30MB within a
	# single probe cycle -- xray's own RSS jumped from ~37MB to 114MB almost
	# immediately, and most probes then failed from local resource
	# starvation (timeouts), not from the servers actually being down. That
	# produced a *worse* signal than sequential probing (166/166 reported
	# dead, most falsely) while risking a repeat of the OOM-kill this
	# project already hit once during testing. Sequential probing is slower
	# to reach full coverage on a large subscription, but it's the only mode
	# that doesn't lie about server health on hardware this constrained.
	if [ "$(echo "$balancers" | jq 'length')" -gt 0 ]; then
		jq -n '{observatory:{subjectSelector:["sr_"], probeUrl:"https://www.gstatic.com/generate_204", probeInterval:"30s"}}' >"$SR_OBSERVATORY_FILE"
	else
		rm -f "$SR_OBSERVATORY_FILE"
	fi

	sr_restart_xray
	sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s)) and balancer ($(echo "$balancers" | jq 'length') group(s))"
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
