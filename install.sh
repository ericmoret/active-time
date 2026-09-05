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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== active_time.py installer =="
echo

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

if confirm "Set up Google Sheet sync now? (requires a Google Cloud service account - see README)"; then
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

    read -r -p "Google Sheet ID to sync with (required): " SHEET_ID
    while [ -z "$SHEET_ID" ]; do
        read -r -p "Sheet ID can't be empty - Google Sheet ID to sync with: " SHEET_ID
    done
    prompt_default SHEET_TAB "Worksheet/tab name" "CSV"
    SHEET_ARGS=(--push-sheet --sheet-id "$SHEET_ID" --sheet-tab "$SHEET_TAB")
else
    echo "Skipping Google Sheet sync - local CSV only. Re-run this installer anytime to add it."
fi
echo

# ---------------------------------------------------------------------------
# 4. Office days/hours
# ---------------------------------------------------------------------------
prompt_default OFFICE_DAYS "Days considered office days (comma-separated, e.g. Tue,Wed,Thu)" "Tue,Wed,Thu"
prompt_default OFFICE_START "Office hours start time" "9:00"
prompt_default OFFICE_END "Office hours end time" "18:00"

if ! OFFICE_DAYS="$OFFICE_DAYS" OFFICE_START="$OFFICE_START" OFFICE_END="$OFFICE_END" BIN_DIR="$BIN_DIR" "$PYTHON_BIN" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["BIN_DIR"])
from active_time import parse_office_days, parse_time_of_day
try:
    parse_office_days(os.environ["OFFICE_DAYS"])
    parse_time_of_day(os.environ["OFFICE_START"])
    parse_time_of_day(os.environ["OFFICE_END"])
except ValueError as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
then
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# 5. Render and install the launchd plist
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
plist="${plist//@OFFICE_DAYS@/$OFFICE_DAYS}"
plist="${plist//@OFFICE_START@/$OFFICE_START}"
plist="${plist//@OFFICE_END@/$OFFICE_END}"
plist="${plist//@DATA_DIR@/$DATA_DIR}"
plist="${plist//@LOG@/$LOG_DST}"
printf '%s\n' "$plist" > "$PLIST_DST"
echo "Wrote launch agent -> $PLIST_DST"

unload_agent
launchctl load "$PLIST_DST"
echo "Loaded into launchd (runs daily at 08:00, or ASAP after wake if missed)."
echo

# ---------------------------------------------------------------------------
# 6. Summary
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
echo "Office:   $OFFICE_DAYS, $OFFICE_START-$OFFICE_END"
echo
echo "Test it now with:"
echo "  \"$SCRIPT_DST\" --csv \"$CSV_DST\" ${SHEET_ARGS[*]}"
