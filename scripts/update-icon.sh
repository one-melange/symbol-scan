#!/usr/bin/env bash
#
# Replace the app icon from a source image.
#
# The AppIcon asset catalog expects a single 1024×1024 (512×512 @2x) PNG at
# SymbolScan/SymbolScan/Assets.xcassets/AppIcon.appiconset/icon.png. Provide a
# square PNG that is at least 1024×1024 and this downsizes it to exactly that,
# preserving transparency, and drops it into place.
#
# It only touches the artwork — Contents.json already points at icon.png, so no
# catalog changes are needed. Rebuild/reinstall (./scripts/install.sh) to pick it up.
#
# Usage:  ./scripts/update-icon.sh path/to/new-icon.png
set -euo pipefail

readonly MIN_DIM=1024
readonly DEST="SymbolScan/SymbolScan/Assets.xcassets/AppIcon.appiconset/icon.png"

cd "$(dirname "$0")/.."

fail() { echo "✗ $1" >&2; exit 1; }

# --- Argument -----------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 path/to/new-icon.png" >&2
  exit 2
fi
SRC="$1"

[[ -f "$SRC" ]] || fail "No such file: $SRC"
[[ -r "$SRC" ]] || fail "File is not readable: $SRC"

# --- Verify it's an image sips can read --------------------------------------
if ! DIMS="$(sips -g pixelWidth -g pixelHeight -g format "$SRC" 2>/dev/null)"; then
  fail "Not a readable image: $SRC"
fi

WIDTH="$(sed -n 's/.*pixelWidth: *//p' <<<"$DIMS")"
HEIGHT="$(sed -n 's/.*pixelHeight: *//p' <<<"$DIMS")"
FORMAT="$(sed -n 's/.*format: *//p' <<<"$DIMS")"

[[ -n "$WIDTH" && -n "$HEIGHT" ]] || fail "Could not read image dimensions from $SRC"

# --- Verify requirements ------------------------------------------------------
echo "▸ Source: $SRC  (${WIDTH}×${HEIGHT}, format: ${FORMAT})"

[[ "$FORMAT" == "png" ]] || fail "Icon must be a PNG (got: ${FORMAT}). Export to PNG and retry."

if [[ "$WIDTH" -ne "$HEIGHT" ]]; then
  fail "Icon must be square (got ${WIDTH}×${HEIGHT})."
fi

if [[ "$WIDTH" -lt "$MIN_DIM" ]]; then
  fail "Icon must be at least ${MIN_DIM}×${MIN_DIM} (got ${WIDTH}×${HEIGHT}). Upscaling would look blurry."
fi

# Alpha is expected for a rounded-rect macOS icon; warn but don't block.
if ! sips -g hasAlpha "$SRC" 2>/dev/null | grep -q "hasAlpha: yes"; then
  echo "⚠ Source has no alpha channel — the icon will render with an opaque background."
fi

# --- Install ------------------------------------------------------------------
if [[ "$WIDTH" -eq "$MIN_DIM" ]]; then
  echo "▸ Already ${MIN_DIM}×${MIN_DIM}; copying into place…"
  cp "$SRC" "$DEST"
else
  echo "▸ Resizing ${WIDTH}×${HEIGHT} → ${MIN_DIM}×${MIN_DIM}…"
  # sips writes the resized copy directly to the destination.
  sips -z "$MIN_DIM" "$MIN_DIM" "$SRC" --out "$DEST" >/dev/null
fi

# --- Verify the result --------------------------------------------------------
RESULT="$(sips -g pixelWidth -g pixelHeight "$DEST" 2>/dev/null)"
RW="$(sed -n 's/.*pixelWidth: *//p' <<<"$RESULT")"
RH="$(sed -n 's/.*pixelHeight: *//p' <<<"$RESULT")"
[[ "$RW" -eq "$MIN_DIM" && "$RH" -eq "$MIN_DIM" ]] \
  || fail "Post-write check failed: $DEST is ${RW}×${RH}, expected ${MIN_DIM}×${MIN_DIM}."

echo "✓ Updated $DEST (${RW}×${RH})."
echo "  Run ./scripts/install.sh to rebuild and reinstall with the new icon."
