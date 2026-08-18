#!/bin/sh
# Shared helpers for XKeen SmartRoute shell scripts.
# Expects POSIX sh (ash/busybox) + jq (from Entware).

# rpcd (the ubus backend that runs these scripts whenever the LuCI panel
# itself saves/deletes a profile or toggles a setting) execs its script
# handlers with a bare system PATH -- /usr/sbin:/usr/bin:/sbin:/bin, no
# /opt/anything -- confirmed on real hardware via /proc/<rpcd-pid>/environ.
# Every binary this project actually depends on (xray, jq, curl, ...) lives
# under Entware's /opt/sbin or /opt/bin, so without this, `command -v xray`
# in sr_restart_xray silently fails and profile changes made through the
# real web UI never actually reach the running Xray process -- the JSON
# gets written, but nothing restarts to pick it up until something else
# (cron, a manual SSH session with the right PATH) happens to do it later.
# Every other entry point (cron, manual SSH) already has a workable PATH,
# so this is a no-op for them and only matters for the rpcd path.
export PATH="/opt/sbin:/opt/bin:$PATH"

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
SR_PING_FILE="$SR_STATE_DIR/ping.json"
SR_HEALTH_FILE="$SR_STATE_DIR/health.json"

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

# _sr_xray_validate: config must pass `xray run -test` before we touch the
# running process either way (start or restart). A single malformed outbound
# (e.g. a subscription node whose provider sent an XHTTP field combination
# this Xray build rejects, or a leastPing balancer with no matching
# observatory) would otherwise take down the whole proxy -- and since
# refreshes run unattended from cron, nobody would be watching when it
# happens. Better to log it loudly and leave whatever was already running
# (or leave Xray stopped, for a start) than silently brick internet access.
# The assignment is the `if` condition itself, not a separate statement:
# under `set -e`, a failing command substitution used as a plain statement
# aborts the script right there, before a later `if [ $? ]` ever gets a
# chance to check it and log why. Conditions of if/while are exempt from
# errexit.
_sr_xray_validate() {
	if test_out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" xray run -test -confdir "$XKEEN_CONFIGS_DIR" 2>&1)"; then
		return 0
	fi
	sr_log "ERROR: refusing to $1 xray, the merged config failed validation: $(printf '%s' "$test_out" | tail -1)"
	return 1
}

# _sr_xray_launch: backgrounded, HUP-detached launch -- shared by
# sr_start_xray and sr_restart_xray (the only difference between them is
# whether a running process gets killed first). This busybox has neither
# `nohup` nor `setsid`, hence the subshell + `trap '' HUP` to survive the
# launching shell exiting.
_sr_xray_launch() {
	(
		trap '' HUP
		ulimit -SHn 1000000
		# XRAY_LOCATION_CONFDIR is not a real Xray environment variable --
		# confirmed for real on this project's own test router: a process
		# launched this way (env var only, no -confdir flag) starts up fine
		# and serves traffic, but silently never actually loads the routing
		# rules or balancers (xray api lsrules/bi report them as simply not
		# existing), while outbounds/inbounds/api DO load correctly. It's a
		# genuinely confusing partial failure -- nothing crashes, nothing
		# logs an error, Xray just quietly runs with an empty rule table and
		# falls back to its documented "no rule matched -> first outbound"
		# behavior for every single connection. _sr_xray_validate below
		# already uses the real mechanism (the -confdir flag) for its dry
		# run; this only ever differed for the actual launch. Passing the
		# flag through `su -c` as part of the command string (not a
		# separately-exported env var, which some `su` implementations don't
		# forward to the child shell at all) is what actually works.
		exec su -c "XRAY_LOCATION_ASSET='$XRAY_ASSET_DIR' xray run -confdir '$XKEEN_CONFIGS_DIR'" "$XRAY_RUN_USER" >"$SR_STATE_DIR/xray-launch.log" 2>&1 </dev/null
	) &
	i=0
	while ! pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
}

sr_restart_xray() {
	command -v xray >/dev/null 2>&1 || { sr_log "xray binary not found, skipping restart"; return 1; }
	_sr_xray_validate restart || return 1

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

	_sr_xray_launch
	if pgrep -x xray >/dev/null 2>&1; then
		sr_log "xray restarted (pid $(pgrep -x xray | head -1))"
	else
		sr_log "ERROR: xray did not come back up after restart -- check $SR_STATE_DIR/xray-launch.log"
		return 1
	fi
}

# sr_stop_xray / sr_start_xray: explicit start/stop, not just the
# always-restart sr_restart_xray above -- for the Status page's per-service
# controls. Confirmed safe on real hardware to call these independently of
# xkeen-UI/smartroute-gateway in any order: neither of those two crashes or
# hangs when Xray is down, they just show it as stopped.
sr_stop_xray() {
	for pid in $(pgrep -x xray 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
	i=0
	while pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
	if pgrep -x xray >/dev/null 2>&1; then
		sr_log "ERROR: xray did not stop"
		return 1
	fi
	sr_log "xray stopped"
}

sr_start_xray() {
	command -v xray >/dev/null 2>&1 || { sr_log "xray binary not found, skipping start"; return 1; }
	if pgrep -x xray >/dev/null 2>&1; then
		sr_log "xray already running"
		return 0
	fi
	_sr_xray_validate start || return 1
	_sr_xray_launch
	if pgrep -x xray >/dev/null 2>&1; then
		sr_log "xray started (pid $(pgrep -x xray | head -1))"
	else
		sr_log "ERROR: xray did not come up -- check $SR_STATE_DIR/xray-launch.log"
		return 1
	fi
}
