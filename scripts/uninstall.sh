#!/usr/bin/env bash
#
# Uninstall SymbolScan — the counterpart to scripts/install.sh (T36).
#
# Deleting /Applications/SymbolScan.app by hand leaves state behind: the symbol index cache and
# the local-LLM model under Application Support, the preferences domain, and possibly a login item.
# This removes those, with two deliberate exceptions so a reinstall is painless:
#   - the Accessibility (TCC) grant is never touched — re-authorizing on every reinstall is a chore;
#   - the model weights are kept by default (~2 GB, rarely change); pass --purge-model to remove them.
#
# Usage:  ./scripts/uninstall.sh [--purge-model] [--dry-run]
set -euo pipefail

# Mirrors of values defined in the app — keep in sync if those move.
BUNDLE_ID="promethiumventures.SymbolScan"                  # PRODUCT_BUNDLE_IDENTIFIER (project.pbxproj)
APP="/Applications/SymbolScan.app"                         # DEST in scripts/install.sh
SUPPORT="$HOME/Library/Application Support/SymbolScan"
INDEX_DIR="$SUPPORT/index"                                 # IndexCache.baseDirectory() (Index/SymbolIndex.swift)
MODEL_DIR="$SUPPORT/models"                                # LlamaServerLocator.defaultModelDirectory() (LLM/LlamaServer.swift)
LLAMA_SERVER="SymbolScan.app/Contents/Helpers/llama/llama-server"

PURGE_MODEL=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --purge-model) PURGE_MODEL=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

# Run a command, or just print it under --dry-run. The echo goes to fd 3 (the real stdout) so it
# still shows for call sites that silence the command's own output.
exec 3>&1
run() {
  if (( DRY_RUN )); then echo "    [dry-run] $*" >&3; else "$@"; fi
}

# Remove a path if present, reporting either way.
remove() {
  local path="$1" label="$2"
  if [[ -e "$path" ]]; then
    echo "▸ Removing ${label} ($(du -sh "$path" 2>/dev/null | awk "{print \$1}")): ${path}"
    run rm -rf "$path"
  else
    echo "▸ ${label}: already absent"
  fi
}

(( DRY_RUN )) && echo "(dry run — nothing will be changed)"

echo "▸ Quitting SymbolScan…"
run osascript -e 'quit app "SymbolScan"' >/dev/null 2>&1 || true
# The app stops its llama-server child on quit; this catches one orphaned by a crash.
run pkill -f "$LLAMA_SERVER" >/dev/null 2>&1 || true

# SMAppService login items can't be unregistered per-app from the shell (`sfltool resetbtm` wipes
# every app's), so detect a leftover one read-only and point at where to remove it.
if sfltool dumpbtm 2>/dev/null | grep -q "$BUNDLE_ID"; then
  echo "! A login item for SymbolScan is registered. Remove it in"
  echo "  System Settings → General → Login Items (or untick 'Open at Login' before uninstalling)."
fi

remove "$APP" "app bundle"
remove "$INDEX_DIR" "index cache"

if (( PURGE_MODEL )); then
  remove "$MODEL_DIR" "model weights"
  # Drop the now-empty parent; rmdir refuses if anything unexpected is left in it.
  [[ -d "$SUPPORT" ]] && { run rmdir "$SUPPORT" 2>/dev/null || echo "! Left ${SUPPORT} (not empty)"; }
elif [[ -d "$MODEL_DIR" ]]; then
  echo "▸ Keeping model weights ($(du -sh "$MODEL_DIR" 2>/dev/null | awk "{print \$1}")) — rerun with --purge-model to remove"
fi

echo "▸ Removing preferences (${BUNDLE_ID})…"
# A custom llm.modelPath override is only a pref here — the file it points at is never touched.
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  run defaults delete "$BUNDLE_ID"
else
  echo "    already absent"
fi

echo "✓ Uninstalled.$( (( PURGE_MODEL )) || echo ' Model weights kept for the next install.')"
