#!/usr/bin/env bash
#
# Build SymbolScan in Release and install it to /Applications (T24).
#
# SymbolScan is a menu-bar (.accessory) app, so "launching" it means running the built
# app — not opening it from Xcode every time. This produces a real SymbolScan.app in
# /Applications so you can start it from Spotlight/Finder and, once running, tick
# "Open at Login" in its menu-bar menu to have it start automatically.
#
# Signing comes from the project's normal config (DEVELOPMENT_TEAM via SymbolScan/Local.xcconfig);
# see DEVELOPMENT.md. A stable signing identity is what keeps the Accessibility grant alive across
# reinstalls — the same reason it matters for Xcode builds.
#
# Usage:  ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SymbolScan/SymbolScan.xcodeproj"
DEST="/Applications/SymbolScan.app"

echo "▸ Building SymbolScan (Release)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme SymbolScan \
  -configuration Release \
  build

# Locate the built app from the project's own build settings rather than assuming a path.
# This project pins SYMROOT to SymbolScan/build, so the products never land under a
# -derivedDataPath — ask xcodebuild where BUILT_PRODUCTS_DIR actually is.
PRODUCTS_DIR="$(xcodebuild \
  -project "$PROJECT" \
  -scheme SymbolScan \
  -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
APP="$PRODUCTS_DIR/SymbolScan.app"

if [[ -z "$PRODUCTS_DIR" || ! -d "$APP" ]]; then
  echo "✗ Build did not produce SymbolScan.app (looked in: ${PRODUCTS_DIR:-<unresolved>})" >&2
  exit 1
fi

echo "▸ Installing to $DEST…"
# Quit a running copy so the bundle isn't in use, then replace it in place.
osascript -e 'quit app "SymbolScan"' >/dev/null 2>&1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "▸ Launching…"
open "$DEST"

echo "✓ Installed. Grant Accessibility (System Settings → Privacy & Security → Accessibility)"
echo "  if prompted, then use the menu-bar icon → 'Open at Login' to start it automatically."
