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

# confirm "prompt text" ["Y"] -> 0 (yes) or 1 (no). Defaults to no unless
# "Y" is passed as the second argument, in which case pressing Enter (or
# anything but an explicit n/N) counts as yes.
confirm() {
    local default="${2:-N}" hint="y/N" reply
    [ "$default" = "Y" ] && hint="Y/n"
    read -r -p "$1 [$hint] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
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

# read_existing_plist_config -> sets EXISTING_SHEET_ENABLED (0/1),
# EXISTING_SHEET_ID, EXISTING_SHEET_TAB, EXISTING_OFFICE_DAYS,
# EXISTING_OFFICE_START, EXISTING_OFFICE_END from whatever's already
# installed at $PLIST_DST, so a re-run can offer to keep it instead of
# silently reverting to hardcoded defaults. No-op (keeps the caller's
# existing values) if there's no plist there yet.
read_existing_plist_config() {
    [ -f "$PLIST_DST" ] || return 0
    eval "$("$PYTHON_BIN" - "$PLIST_DST" <<'PYEOF'
import plistlib, shlex, sys

with open(sys.argv[1], "rb") as f:
    args = plistlib.load(f).get("ProgramArguments", [])

flag_to_var = {
    "--sheet-id": "EXISTING_SHEET_ID",
    "--sheet-tab": "EXISTING_SHEET_TAB",
    "--office-days": "EXISTING_OFFICE_DAYS",
    "--office-start": "EXISTING_OFFICE_START",
    "--office-end": "EXISTING_OFFICE_END",
}
out = {}
for i, arg in enumerate(args):
    var = flag_to_var.get(arg)
    if var and i + 1 < len(args):
        out[var] = args[i + 1]
if "--push-sheet" in args:
    out["EXISTING_SHEET_ENABLED"] = "1"

for key, value in out.items():
    print(f"{key}={shlex.quote(value)}")
PYEOF
)"
}

unload_agent() {
    launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
}
