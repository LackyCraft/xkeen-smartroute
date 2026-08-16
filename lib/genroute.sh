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
	# profile json on stdin -> jq array of Xray "domain" match strings
	src_type="$(jq -r '.domain_source.type' "$1")"
	if [ "$src_type" = "geosite" ]; then
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

sr_regen() {
	sr_ensure_dirs
	rules="[]"
	balancers="[]"

	for pf in "$SR_PROFILES_DIR"/*.json; do
		[ -e "$pf" ] || continue
		name="$(jq -r '.name' "$pf")"
		mode="$(jq -r '.mode' "$pf")"
		domains="$(domain_match_array "$pf")"

		if [ "$mode" = "fixed" ]; then
			target_tag="$(jq -r '.fixed_server' "$pf")"
			rule="$(jq -n --argjson d "$domains" --arg tag "$target_tag" \
				'{type:"field", domain:$d, outboundTag:$tag}')"
			rules="$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')"
		else
			bal_tag="bal_$name"
			servers="$(jq -c '.servers' "$pf")"
			balancer="$(jq -n --arg tag "$bal_tag" --argjson sel "$servers" \
				'{tag:$tag, selector:$sel, strategy:{type:"leastPing"}}')"
			balancers="$(echo "$balancers" | jq --argjson b "$balancer" '. + [$b]')"
			rule="$(jq -n --argjson d "$domains" --arg tag "$bal_tag" \
				'{type:"field", domain:$d, balancerTag:$tag}')"
			rules="$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')"
		fi
	done

	jq -n --argjson rules "$rules" '{routing:{domainStrategy:"IPIfNonMatch", rules:$rules}}' >"$SR_ROUTING_FILE"
	jq -n --argjson bal "$balancers" '{routing:{balancers:$bal}}' >"$SR_BALANCER_FILE"

	sr_restart_xray
	sr_log "regenerated routing ($(echo "$rules" | jq 'length') rule(s)) and balancer ($(echo "$balancers" | jq 'length') group(s))"
}

case "${1:-}" in
	save)
		sr_ensure_dirs
		[ -n "${2:-}" ] && [ -f "$2" ] || sr_die "profile json file required"
		name="$(jq -r '.name' "$2")"
		[ -n "$name" ] && [ "$name" != "null" ] || sr_die "profile json must have a .name"
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
