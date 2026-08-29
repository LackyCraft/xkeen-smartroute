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
SR_CURRENT_FILE="$SR_STATE_DIR/current.json"
SR_DOUBLEVPN_FILE="$SR_STATE_DIR/doublevpn.json"
SR_DOUBLEVPN_CURRENT_FILE="$SR_STATE_DIR/doublevpn_current.json"

# ---------------------------------------------------------------------------
# Double VPN: an optional extra hop in front of every profile's own outbound.
# The idea (see docs/functionality_doc/doublevpn.md): an ISP frequently
# blocks individual destination servers directly while leaving at least one
# other server in the subscription reachable -- so instead of dialing every
# server straight from the router, everything (real traffic *and*
# Observatory's own health probes) gets relayed through one chosen "gateway"
# server first. The gateway itself is picked the exact same way a
# balancer-mode profile picks its target (sr_pick_top1, see genroute.sh) from
# a user-chosen pool of candidate servers -- doublevpn.json just stores that
# pool plus the on/off switch; sr_apply_doublevpn (genroute.sh) is what
# actually wires the chosen gateway into every other outbound on each regen.
sr_get_doublevpn() {
	[ -s "$SR_DOUBLEVPN_FILE" ] && cat "$SR_DOUBLEVPN_FILE" || echo '{"enabled":false,"servers":[]}'
}

sr_set_doublevpn_enabled() {
	sr_ensure_dirs
	case "$1" in true|1) val=true ;; false|0) val=false ;; *) sr_die "expected true/false" ;; esac
	new="$(sr_get_doublevpn | jq --argjson e "$val" '.enabled = $e')"
	printf '%s' "$new" >"$SR_DOUBLEVPN_FILE"
}

sr_set_doublevpn_servers() {
	# $1 = JSON array of server tags (the candidate gateway pool)
	sr_ensure_dirs
	echo "$1" | jq -e 'type == "array"' >/dev/null 2>&1 || sr_die "servers must be a JSON array of tags"
	# .removed_servers is cleared here, not merged -- a manual save from the
	# UI always sends the pool the user actually wants right now, so any
	# previously-flagged "disappeared" warning no longer applies (mirrors
	# genroute.sh's "save" case for profiles: cp-ing the whole file over
	# implicitly drops removed_servers the same way).
	new="$(sr_get_doublevpn | jq --argjson s "$1" '.servers = $s | .removed_servers = []')"
	printf '%s' "$new" >"$SR_DOUBLEVPN_FILE"
}

# How stale a health.json entry has to be (minutes since its checked_at)
# before genroute.sh's observatory subjectSelector considers it due for a
# re-probe -- see sr_stale_tags/sr_regen in genroute.sh. Configurable from
# the Subscriptions page. 20 minutes: short enough that a server's real
# status doesn't drift far from reality, long enough that a full pass over
# a few hundred servers (confirmed live: ~1s avg per probe once
# probeInterval isn't the bottleneck) comfortably finishes within one
# period even when regens interrupt it.
DEFAULT_OBSERVATORY_PERIOD_MIN=20

sr_get_observatory_period_min() {
	[ -s "$SR_STATE_DIR/observatory_period_min" ] && cat "$SR_STATE_DIR/observatory_period_min" || echo "$DEFAULT_OBSERVATORY_PERIOD_MIN"
}

sr_set_observatory_period_min() {
	sr_ensure_dirs
	case "$1" in *[!0-9]*|'') sr_die "observatory period must be a whole number of minutes" ;; esac
	[ "$1" -ge 1 ] || sr_die "observatory period must be at least 1 minute"
	echo "$1" > "$SR_STATE_DIR/observatory_period_min"
}

# ---------------------------------------------------------------------------
# Xray access/error logging -- off by default. Xray's top-level "loglevel"
# is not a severity filter on top of always-on logging: setting it to "none"
# (our shipped default, see 01_log.json below) makes Xray set BOTH
# AccessLogType and ErrorLogType to LogType_None internally (confirmed
# against app/log's real Build() switch in Xray-core's own source) -- no
# access log line is ever produced, not even a suppressed/dropped one. This
# is why the log viewer was empty everywhere (smartroute-gateway, xkeen-UI)
# that tails those files: nothing was ever writing to them, permissions were
# never the issue.
#
# Logs are written to tmpfs ($XRAY_LOG_DIR, /tmp) rather than /opt (flash)
# specifically so leaving this on doesn't wear the flash -- the tradeoff is
# that the file is capped in size (sr_get_log_cap_mb, enforced continuously
# by smartroute-gateway's own log tailer, not just at input time) and
# doesn't survive a reboot, both fine for a live-debugging viewer this is
# meant to be, not an audit trail.
XRAY_LOG_DIR="/tmp/xray-logs"
DEFAULT_LOG_CAP_MB=10

sr_get_log_enabled() {
	[ -s "$SR_STATE_DIR/log_enabled" ] && cat "$SR_STATE_DIR/log_enabled" || echo "0"
}

sr_get_log_level() {
	[ -s "$SR_STATE_DIR/log_level" ] && cat "$SR_STATE_DIR/log_level" || echo "warning"
}

sr_get_log_cap_mb() {
	[ -s "$SR_STATE_DIR/log_cap_mb" ] && cat "$SR_STATE_DIR/log_cap_mb" || echo "$DEFAULT_LOG_CAP_MB"
}

# sr_log_free_mb: MemAvailable (kernel's own "safe to hand out" estimate,
# not bare MemFree) from /proc/meminfo, in MB. Used both to validate a
# requested cap and to report the ceiling back to the UI.
sr_log_free_mb() {
	avail_kb="$(awk '/MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
	case "$avail_kb" in '' | *[!0-9]*) echo 0; return ;; esac
	echo $((avail_kb / 1024))
}

# sr_apply_log_config: (re)writes 01_log.json from the current enabled/level
# state and restarts xray to pick it up (Xray has no hot-reload for its own
# log config). Called after every toggle/level change, and should also run
# once at install time so a fresh install's file matches this function's
# idea of "off" byte-for-byte -- see install.sh.
sr_apply_log_config() {
	mkdir -p "$XRAY_LOG_DIR"
	if [ "$(sr_get_log_enabled)" = "1" ]; then
		level="$(sr_get_log_level)"
	else
		level="none"
	fi
	cat > "$XKEEN_CONFIGS_DIR/01_log.json" <<EOF
{
  "log": {
    "access": "$XRAY_LOG_DIR/access.log",
    "error": "$XRAY_LOG_DIR/error.log",
    "loglevel": "$level",
    "dnsLog": false
  }
}
EOF
	command -v xray >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1 && sr_restart_xray
}

sr_set_log_enabled() {
	sr_ensure_dirs
	case "$1" in true|1) val=1 ;; false|0) val=0 ;; *) sr_die "expected true/false" ;; esac
	echo "$val" > "$SR_STATE_DIR/log_enabled"
	sr_apply_log_config
}

sr_set_log_level() {
	case "$1" in debug|info|warning|error) : ;; *) sr_die "expected debug|info|warning|error" ;; esac
	sr_ensure_dirs
	echo "$1" > "$SR_STATE_DIR/log_level"
	[ "$(sr_get_log_enabled)" = "1" ] && sr_apply_log_config
	return 0
}

# sr_set_log_cap_mb: rejects a cap over half of currently-free memory --
# this is a small home router (tens to low hundreds of MB free is typical),
# not a log server, and the whole point of the cap is to survive an operator
# leaving logging on and forgetting about it, not to promise the full free
# amount is safe to commit to one tmpfs mount.
sr_set_log_cap_mb() {
	case "$1" in '' | *[!0-9]*) sr_die "cap must be a whole number of MB" ;; esac
	[ "$1" -ge 1 ] || sr_die "cap must be at least 1 MB"
	free_mb="$(sr_log_free_mb)"
	max_allowed=$((free_mb / 2))
	[ "$max_allowed" -ge 1 ] || max_allowed=1
	if [ "$1" -gt "$max_allowed" ]; then
		sr_die "cap ${1}MB exceeds half of currently free memory (${free_mb}MB free, max ${max_allowed}MB) -- pick a smaller value"
	fi
	sr_ensure_dirs
	echo "$1" > "$SR_STATE_DIR/log_cap_mb"
}

# sr_clear_logs: truncate in place (not unlink) so Xray's already-open file
# handle keeps writing to the same inode -- deleting the file instead would
# leave Xray happily appending into a now-nameless inode, invisible to any
# viewer re-opening the path, until the next restart.
sr_clear_logs() {
	: > "$XRAY_LOG_DIR/access.log" 2>/dev/null || true
	: > "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
}

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
# (e.g. a leastPing balancer with no matching observatory) would otherwise
# take down the whole proxy -- and since refreshes run unattended from cron,
# nobody would be watching when it happens. Better to log it loudly and leave
# whatever was already running (or leave Xray stopped, for a start) than
# silently brick internet access.
#
# One specific, recurring failure gets a real fix instead of just being
# refused: a subscription node whose provider's XHTTP "extra" field (padding/
# obfuscation/session tuning -- see build_outbound in subscription.sh for why
# this is included at all now, it's not optional decoration, some nodes only
# actually connect with it) combines two sub-fields Xray's own config
# validator hard-rejects, e.g. "SeqPlacement must be path when
# SessionPlacement is path" -- confirmed live. Without handling it, that one
# bad node's extra field would block *every* future regen (routing changes,
# profile saves, cron, all of it) until a human noticed and fixed it by
# hand, since the same broken node stays in outbounds.json until the next
# subscription refresh. Instead: on a validation failure that names a
# specific outbound tag, strip just that one outbound's `extra` field (not
# the whole node, not the whole subscription) and retry -- bounded so a truly
# broken confdir still fails loudly rather than looping forever.
_sr_xray_validate() {
	# xkeen's own 02_transport.json template uses the old top-level
	# "transport" config style Xray-core has since removed ("Global
	# transport config has been removed and migrated to streamSettings in
	# inbounds and outbounds") -- install.sh already neutralizes this file
	# once, right after installing Entware's xray-core, but confirmed live
	# on a fresh install: xkeen's own install wizard can (re)write the
	# incompatible template *after* that one-time check already ran,
	# leaving the original content in place with no further chance to fix
	# it -- every start/restart from then on fails validation outright,
	# xray never comes up. Re-assert defensively on every validate instead
	# of trusting a single point-in-time check against another project's
	# install ordering. We don't need this file: every outbound we
	# generate carries its own streamSettings.
	if [ -f "$XKEEN_CONFIGS_DIR/02_transport.json" ] && grep -q '"transport"' "$XKEEN_CONFIGS_DIR/02_transport.json" 2>/dev/null; then
		echo '{}' >"$XKEEN_CONFIGS_DIR/02_transport.json"
	fi

	# Same self-heal, same reason: install.sh creates the unprivileged
	# "$XRAY_RUN_USER" account (_sr_xray_launch below does `su -c ... "$XRAY_RUN_USER"`)
	# once, in the "xkeen not yet installed" branch -- confirmed live, on the
	# same router as the transport.json bug above, that branch can be skipped
	# on a run where xkeen's binary is already present but an earlier attempt
	# died before reaching that step, leaving no account at all. `su` then
	# fails outright with "No passwd entry for user '$XRAY_RUN_USER'", xray
	# never launches, and the resulting confdir-read failure looks like the
	# unrelated known Xray-core confdir race (_sr_xray_launch retries below)
	# instead of the real, non-transient cause.
	if ! id "$XRAY_RUN_USER" >/dev/null 2>&1; then
		for f in /etc/passwd /etc/group /opt/etc/passwd /opt/etc/group; do
			case "$f" in
				*group) grep -q "^$XRAY_RUN_USER:" "$f" 2>/dev/null || echo "$XRAY_RUN_USER:x:11111:" >>"$f" ;;
				*passwd) grep -q "^$XRAY_RUN_USER:" "$f" 2>/dev/null || echo "$XRAY_RUN_USER:x:0:11111:::/bin/sh" >>"$f" ;;
			esac
		done
	fi

	attempts=0
	while [ "$attempts" -lt 20 ]; do
		if test_out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" xray run -test -confdir "$XKEEN_CONFIGS_DIR" 2>&1)"; then
			return 0
		fi
		bad_tag="$(printf '%s' "$test_out" | sed -n 's/.*failed to build outbound config with tag \([^ ]*\).*/\1/p' | head -n1)"
		if [ -z "$bad_tag" ] || [ ! -s "$SR_OUTBOUNDS_FILE" ] || ! grep -q "\"$bad_tag\"" "$SR_OUTBOUNDS_FILE" 2>/dev/null; then
			break
		fi
		sr_log "WARNING: outbound '$bad_tag' has an XHTTP 'extra' field combination Xray's validator rejects -- dropping just that field for this one node so it doesn't block every other server: $(printf '%s' "$test_out" | tail -1)"
		jq --arg tag "$bad_tag" '(.outbounds[] | select(.tag==$tag) | .streamSettings.xhttpSettings) |= (if . then del(.extra) else . end)' \
			"$SR_OUTBOUNDS_FILE" > "$SR_OUTBOUNDS_FILE.tmp" && mv "$SR_OUTBOUNDS_FILE.tmp" "$SR_OUTBOUNDS_FILE"
		attempts=$((attempts + 1))
	done
	sr_log "ERROR: refusing to $1 xray, the merged config failed validation: $(printf '%s' "$test_out" | tail -1)"
	return 1
}

# _sr_xray_launch: backgrounded, HUP-detached launch -- shared by
# sr_start_xray and sr_restart_xray (the only difference between them is
# whether a running process gets killed first). This busybox has neither
# `nohup` nor `setsid`, hence the subshell + `trap '' HUP` to survive the
# launching shell exiting.
_sr_xray_launch() {
	attempt=1
	while :; do
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

		# A second, different confdir problem from the env-var mixup above --
		# confirmed live, reproduced on demand, on Xray-core 26.2.6 on this
		# hardware: `xray run -confdir` silently drops exactly one file from
		# its own merge, no error or warning logged anywhere, "Reading
		# config" just never appears for it. Which file gets dropped varies,
		# but losing 05_routing.smartroute.json (profile routing) or
		# 00_api.smartroute.json's own internal API-service routing rule are
		# the two that actually bite: the first sends every profile's traffic
		# through Xray's documented "no rule matched -> first outbound"
		# fallback instead of the intended server; the second breaks the
		# gateway panel's entire gRPC connection to Xray (health/Observatory/
		# traffic graph all silently stop updating) until someone restarts
		# the gateway too and still gets the same broken Xray underneath.
		# This is a genuine race inside Xray's own directory read, not
		# something a config change on our side can prevent -- but retrying
		# the launch (a fresh process, fresh directory read) does resolve it.
		# The bad news from live testing: it's not the rare ~1-in-2 shot it
		# first looked like -- back-to-back restarts here needed anywhere
		# from 1 to 5 attempts to land clean, i.e. comfortably above 50%
		# failure per single attempt some of the time. 10 attempts (below)
		# is deliberately generous, not just enough to cover the average
		# case -- each retry only costs a few seconds, and the failure mode
		# being guarded against is "silently no working routing/gRPC until
		# someone happens to notice days later," so it's worth overpaying in
		# restart time for a very low residual failure chance. Cheap to
		# check for: every *.json file actually sitting in the confdir right
		# now should show up as its own "Reading config" line in this
		# launch's own log.
		expected="$(find "$XKEEN_CONFIGS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
		# pgrep seeing the process doesn't mean it's done reading confdir yet
		# (confirmed live: checking right away read "0" every time, before
		# any log line had been flushed) -- give it a few short beats to
		# actually get there before concluding a file was really dropped.
		#
		# Every check below is a plain `if`, deliberately not a `[ cond ] &&
		# cmd` one-liner: this whole function runs under callers' `set -eu`
		# (genroute.sh sources common.sh), and confirmed live on this
		# router's busybox ash, a failing left-hand side of a bare `&&`
		# outside an `if`/`while` condition aborted the function right there
		# -- silently turning a normal "not ready yet, keep polling" check
		# into "genroute.sh delete/save just failed outright" for the
		# caller, with no error message at all. `if`'s condition is exempt
		# from `set -e` in every POSIX shell, no ambiguity.
		got=0
		j=0
		while [ "$j" -lt 5 ]; do
			got=0
			# Not `grep -c ... || echo 0`: grep -c prints "0" (correctly) and
			# still exits 1 on zero matches, which would append a second "0"
			# from the fallback and leave $got as the two-line string "0\n0"
			# -- confirmed live, that broke the numeric comparison below
			# outright ("bad number") rather than just misjudging the count.
			# `|| true` INSIDE the substitution, not `got="$(...)" || echo 0`
			# outside it (that shape is what caused the "0\n0" bug the
			# comment above describes). This one guards a different, worse
			# trap: confirmed live with `sh -x` that `got="$(grep -c ...)"`
			# on its own -- even sitting inside this `if`'s *body* -- still
			# aborted the whole function the moment grep -c found zero
			# matches. `if` only exempts its own *condition* from `set -e`;
			# a plain assignment inside the then-branch is just another
			# simple command, and `var="$(cmd)"` takes on cmd's exit status
			# like any other. This is what was actually behind the
			# intermittent, silent save_profile/delete_profile failures (no
			# log line at all -- the abort happened before any sr_log call
			# downstream could run), not the `&&`-chain issue above; a
			# second, worse instance of the same underlying trap.
			if [ -f "$SR_STATE_DIR/xray-launch.log" ]; then
				got="$(grep -c 'Reading config' "$SR_STATE_DIR/xray-launch.log" 2>/dev/null || true)"
			fi
			if [ "$got" -ge "$expected" ]; then
				return 0
			fi
			sleep 1
			j=$((j + 1))
		done
		if [ "$attempt" -ge 10 ]; then
			sr_log "WARNING: xray's -confdir merge only read $got/$expected config files after $attempt attempts -- routing may be incomplete, check $SR_STATE_DIR/xray-launch.log"
			return 0
		fi
		sr_log "xray's -confdir merge only read $got/$expected config files (known Xray-core confdir race), retrying ($attempt/10)"
		for pid in $(pgrep -x xray 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
		i=0
		while pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
		attempt=$((attempt + 1))
	done
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
