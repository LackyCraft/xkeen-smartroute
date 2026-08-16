#!/bin/sh
# Shared helpers for XKeen SmartRoute shell scripts.
# Expects POSIX sh (ash/busybox) + jq (from Entware).

SR_ETC_DIR="/etc/xkeen-smartroute"
SR_LISTS_DIR="$SR_ETC_DIR/lists"
SR_STATE_DIR="$SR_ETC_DIR/state"
SR_PROFILES_DIR="$SR_ETC_DIR/profiles"
XKEEN_CONFIGS_DIR="/opt/etc/xray/configs"
SR_OUTBOUNDS_FILE="$XKEEN_CONFIGS_DIR/04_outbounds.smartroute.json"
SR_ROUTING_FILE="$XKEEN_CONFIGS_DIR/05_routing.smartroute.json"
SR_OBSERVATORY_FILE="$XKEEN_CONFIGS_DIR/07_observatory.smartroute.json"
SR_BALANCER_FILE="$XKEEN_CONFIGS_DIR/09_balancer.smartroute.json"
SR_SERVERS_FILE="$SR_STATE_DIR/servers.json"
SR_OUTBOUNDS_STATE_FILE="$SR_STATE_DIR/outbounds.json"

sr_log() {
	logger -t xkeen-smartroute "$*" 2>/dev/null
	echo "[xkeen-smartroute] $*" >&2
}

sr_die() {
	sr_log "ERROR: $*"
	exit 1
}

sr_require() {
	command -v "$1" >/dev/null 2>&1 || sr_die "required binary '$1' not found (is Entware installed and in PATH?)"
}

sr_ensure_dirs() {
	mkdir -p "$SR_LISTS_DIR" "$SR_STATE_DIR" "$SR_PROFILES_DIR" "$XKEEN_CONFIGS_DIR"
}

XRAY_ASSET_DIR="/opt/etc/xray/dat"
XRAY_RUN_USER="xkeen"

sr_restart_xray() {
	command -v xray >/dev/null 2>&1 || { sr_log "xray binary not found, skipping restart"; return 1; }

	# Validate the merged config *before* touching the running process. A
	# single malformed outbound (e.g. a subscription node whose provider
	# sent an XHTTP field combination this Xray build rejects, or a
	# leastPing balancer with no matching observatory) would otherwise take
	# down the whole proxy on the next restart -- and since refreshes run
	# unattended from cron, nobody would be watching when it happens.
	# Better to log it loudly and keep the old (working) process running
	# than to silently brick internet access.
	# The assignment is the `if` condition itself, not a separate statement:
	# under `set -e`, a failing command substitution used as a plain
	# statement aborts the script right there, before a later `if [ $? ]`
	# ever gets a chance to check it and log why -- silently leaving
	# whatever process was already running in place, with no error anywhere
	# to explain it. Conditions of if/while are exempt from errexit.
	if test_out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" xray run -test -confdir "$XKEEN_CONFIGS_DIR" 2>&1)"; then
		:
	else
		sr_log "ERROR: refusing to restart xray, the merged config failed validation (leaving the current process running): $(printf '%s' "$test_out" | tail -1)"
		return 1
	fi

	# Not xkeen -restart: on real OpenWrt (as opposed to the KeeneticOS
	# xkeen primarily targets) it hangs indefinitely trying to write a
	# Keenetic NDM netfilter hook file and clean up iptables rules that
	# don't apply here, taking the proxy down with no way back up short of
	# a manual kill+relaunch. Managing the process directly is what xkeen's
	# own start routine does under the hood anyway (same user, same env,
	# same ulimit) -- just without the KeeneticOS-specific detour.
	for pid in $(pgrep -x xray 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
	i=0
	while pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done

	(
		trap '' HUP
		export XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR"
		export XRAY_LOCATION_CONFDIR="$XKEEN_CONFIGS_DIR"
		ulimit -SHn 1000000
		exec su -c "xray run" "$XRAY_RUN_USER" >"$SR_STATE_DIR/xray-launch.log" 2>&1 </dev/null
	) &

	i=0
	while ! pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
	if pgrep -x xray >/dev/null 2>&1; then
		sr_log "xray restarted (pid $(pgrep -x xray | head -1))"
	else
		sr_log "ERROR: xray did not come back up after restart -- check $SR_STATE_DIR/xray-launch.log"
		return 1
	fi
}
