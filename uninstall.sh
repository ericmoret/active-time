#!/usr/bin/env bash
# uninstall.sh - Tear down what install.sh set up.
# Leaves the data directory (your tracked history) and the Google Sheet
# untouched unless you explicitly say to remove the local CSV copy too.
set -euo pipefail

# Run from a real checkout (cloned or tarball-extracted), with lib.sh
# sitting right next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== active_time.py uninstaller =="
echo

if [ -f "$PLIST_DST" ]; then
    unload_agent
    rm -f "$PLIST_DST"
    echo "Removed launch agent: $PLIST_DST"
else
    echo "No launch agent found at $PLIST_DST"
fi

if [ -f "$SCRIPT_DST" ]; then
    rm -f "$SCRIPT_DST"
    echo "Removed script: $SCRIPT_DST"
fi

if security delete-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    echo "Removed Keychain item: $KEYCHAIN_SERVICE"
fi

echo
if [ -d "$DATA_DIR" ]; then
    if confirm "Also delete local data at '$DATA_DIR' (your CSV history)?"; then
        rm -rf "$DATA_DIR"
        echo "Removed $DATA_DIR"
    else
        echo "Kept $DATA_DIR (your Google Sheet still has this history too)."
    fi
fi

if [ -d "$LOG_DIR" ]; then
    if confirm "Also delete logs at '$LOG_DIR'?"; then
        rm -rf "$LOG_DIR"
        echo "Removed $LOG_DIR"
    fi
fi

echo
echo "Uninstall complete."
