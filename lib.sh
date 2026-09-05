#!/usr/bin/env bash
# lib.sh - Shared layout/constants and helpers for install.sh and uninstall.sh.
# Not meant to be run directly; sourced by the other two scripts.

BIN_DIR="$HOME/bin"
DATA_DIR="$HOME/Library/Application Support/ActiveTime"
LOG_DIR="$HOME/Library/Logs/ActiveTime"
AGENT_DIR="$HOME/Library/LaunchAgents"

PYTHON_BIN="/usr/bin/python3"
SCRIPT_DST="$BIN_DIR/active_time.py"
CSV_DST="$DATA_DIR/active_time.csv"
LOG_DST="$LOG_DIR/active_time.log"
PLIST_DST="$AGENT_DIR/com.activetime.agent.plist"

# Must match KEYCHAIN_SERVICE in active_time.py.
KEYCHAIN_SERVICE="ActiveTimeServiceAccount"

# confirm "prompt text" -> 0 (yes) or 1 (no/default)
confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "${reply:-N}" =~ ^[Yy]$ ]]
}

# prompt_default VAR_NAME "prompt text" "default value" -> sets VAR_NAME
prompt_default() {
    local __var="$1" __prompt="$2" __default="$3" __reply
    read -r -p "$__prompt [$__default]: " __reply
    printf -v "$__var" '%s' "${__reply:-$__default}"
}

keychain_item_exists() {
    security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
}

unload_agent() {
    launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
}
