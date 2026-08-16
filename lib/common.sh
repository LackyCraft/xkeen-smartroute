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

sr_restart_xray() {
	if command -v xkeen >/dev/null 2>&1; then
		xkeen -restart >/dev/null 2>&1
	else
		sr_log "xkeen binary not found, skipping restart"
	fi
}
