#!/usr/bin/env bash
# install.sh - Set up active_time.py as a daily-at-8am launchd job.
#
# Puts each piece where a well-behaved macOS tool keeps it:
#   script        ~/bin/active_time.py
#   generated CSV ~/Library/Application Support/ActiveTime/active_time.csv
#   job log       ~/Library/Logs/ActiveTime/active_time.log
#   launch agent  ~/Library/LaunchAgents/com.activetime.agent.plist
#   credential    macOS Keychain (never written to disk as a plaintext file)
#
# Safe to re-run: re-installs the script/plist and reloads the job.
set -euo pipefail

# Run from a real checkout (cloned or tarball-extracted), with
# active_time.py/lib.sh/com.activetime.plist.template sitting right next to
# this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== active_time.py installer =="
echo

# Defaults if this is a first install, or the existing plist doesn't have
# a given value; read_existing_plist_config below overrides whichever of
# these an already-installed plist actually has, so re-running to change
# one setting doesn't silently reset every other one.
EXISTING_SHEET_ENABLED=0
EXISTING_SHEET_ID=""
EXISTING_SHEET_TAB="CSV"
read_existing_plist_config

# ---------------------------------------------------------------------------
# 1. Directories
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$AGENT_DIR"
echo "Directories ready:"
echo "  $BIN_DIR"
echo "  $DATA_DIR"
echo "  $LOG_DIR"
echo "  $AGENT_DIR"
echo

# ---------------------------------------------------------------------------
# 2. Script
# ---------------------------------------------------------------------------
# Pin the shebang to the same interpreter used below for `pip install`, so
# running the script directly (`./active_time.py`) can't land on a
# different python3 earlier in $PATH (e.g. a MacPorts/Homebrew one) that
# doesn't have gspread/google-auth installed.
{ printf '#!%s\n' "$PYTHON_BIN"; tail -n +2 "$SCRIPT_DIR/active_time.py"; } > "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "Installed script -> $SCRIPT_DST (shebang pinned to $PYTHON_BIN)"

# Migrate an existing CSV from the source folder on first install, so a
# prior manual run's history isn't stranded.
if [ -f "$SCRIPT_DIR/active_time.csv" ] && [ ! -f "$CSV_DST" ]; then
    cp "$SCRIPT_DIR/active_time.csv" "$CSV_DST"
    echo "Migrated existing active_time.csv -> $CSV_DST"
fi
echo

# ---------------------------------------------------------------------------
# 3. Google Sheet sync - optional
# ---------------------------------------------------------------------------
SHEET_ARGS=()
RECONFIGURE_SHEET=0

if [ "$EXISTING_SHEET_ENABLED" = "1" ]; then
    echo "Google Sheet sync is currently configured:"
    echo "  Sheet ID: $EXISTING_SHEET_ID"
    echo "  Tab:      $EXISTING_SHEET_TAB"
    if confirm "Keep it as-is?" "Y"; then
        SHEET_ID="$EXISTING_SHEET_ID"
        SHEET_TAB="$EXISTING_SHEET_TAB"
        SHEET_ARGS=(--push-sheet --sheet-id "$SHEET_ID" --sheet-tab "$SHEET_TAB")
        echo "Keeping existing Sheet sync configuration and Keychain credential."
    elif confirm "Reconfigure Google Sheet sync instead of disabling it?"; then
        RECONFIGURE_SHEET=1
    else
        echo "Google Sheet sync disabled - local CSV only. Re-run this installer anytime to re-enable it."
    fi
elif confirm "Set up Google Sheet sync now? (requires a Google Cloud service account - see README)"; then
    RECONFIGURE_SHEET=1
else
    echo "Skipping Google Sheet sync - local CSV only. Re-run this installer anytime to add it."
fi

if [ "$RECONFIGURE_SHEET" = "1" ]; then
    echo "Installing gspread/google-auth (for Google Sheets sync)..."
    "$PYTHON_BIN" -m pip install --user --quiet gspread google-auth
    echo "Done."
    echo

    NEED_KEY=1
    if keychain_item_exists; then
        echo "A '$KEYCHAIN_SERVICE' Keychain item already exists for $USER."
        confirm "Replace it with a new key?" || NEED_KEY=0
    fi

    if [ "$NEED_KEY" -eq 1 ]; then
        read -r -p "Path to your Google service-account JSON key file: " KEY_PATH
        KEY_PATH="${KEY_PATH/#\~/$HOME}"
        if [ ! -f "$KEY_PATH" ]; then
            echo "error: '$KEY_PATH' not found." >&2
            exit 1
        fi
        if ! SA_EMAIL="$("$PYTHON_BIN" -c "
import json, sys
print(json.load(open(sys.argv[1]))['client_email'])
" "$KEY_PATH" 2>/dev/null)"; then
            echo "error: '$KEY_PATH' is not valid service-account JSON (missing 'client_email')." >&2
            exit 1
        fi
        security add-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$(cat "$KEY_PATH")" -U
        echo "Stored service-account key in Keychain as '$KEYCHAIN_SERVICE'."
        echo
        echo "  IMPORTANT: share your target Google Sheet with this address as Editor:"
        echo "    $SA_EMAIL"
    else
        echo "Keeping existing Keychain item."
    fi
    echo

    if [ -n "$EXISTING_SHEET_ID" ]; then
        prompt_default SHEET_ID "Google Sheet ID to sync with" "$EXISTING_SHEET_ID"
    else
        read -r -p "Google Sheet ID to sync with (required): " SHEET_ID
    fi
    while [ -z "$SHEET_ID" ]; do
        read -r -p "Sheet ID can't be empty - Google Sheet ID to sync with: " SHEET_ID
    done
    prompt_default SHEET_TAB "Worksheet/tab name" "$EXISTING_SHEET_TAB"
    SHEET_ARGS=(--push-sheet --sheet-id "$SHEET_ID" --sheet-tab "$SHEET_TAB")
fi
echo

# ---------------------------------------------------------------------------
# 4. Render and install the launchd plist
# ---------------------------------------------------------------------------
sheet_args_xml=""
for arg in "${SHEET_ARGS[@]}"; do
    sheet_args_xml+="        <string>$arg</string>"$'\n'
done

plist="$(<"$SCRIPT_DIR/com.activetime.plist.template")"
plist="${plist//@SHEET_ARGS@/$sheet_args_xml}"
plist="${plist//@PYTHON@/$PYTHON_BIN}"
plist="${plist//@SCRIPT@/$SCRIPT_DST}"
plist="${plist//@CSV@/$CSV_DST}"
plist="${plist//@DATA_DIR@/$DATA_DIR}"
plist="${plist//@LOG@/$LOG_DST}"
printf '%s\n' "$plist" > "$PLIST_DST"
echo "Wrote launch agent -> $PLIST_DST"

unload_agent
launchctl load "$PLIST_DST"
echo "Loaded into launchd (runs daily at 08:00, or ASAP after wake if missed)."
echo

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo "== Install complete =="
echo "Script:   $SCRIPT_DST"
echo "CSV:      $CSV_DST"
echo "Log:      $LOG_DST"
echo "Plist:    $PLIST_DST"
if [ "${#SHEET_ARGS[@]}" -gt 0 ]; then
    echo "Sheet:    https://docs.google.com/spreadsheets/d/$SHEET_ID/edit (tab: $SHEET_TAB)"
else
    echo "Sheet:    (not configured - local CSV only; re-run this installer to add it)"
fi
echo
echo "Test it now with:"
echo "  \"$SCRIPT_DST\" --csv \"$CSV_DST\" ${SHEET_ARGS[*]}"
