#!/usr/bin/env bash
set -euo pipefail

# Update Zed Mono Extended web fonts from local system fonts
# Requires: fonttools (pip), woff2_compress (woff2 package)
#
# Usage: ./scripts/update-fonts.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OUT="$ROOT/static/fonts"
SRC_DIR="${FONT_SRC_DIR:-$HOME/.local/share/fonts}"

FONTS=(
  "zed-mono-extended:400"
  "zed-mono-extendedbold:700"
)

for entry in "${FONTS[@]}"; do
  name="${entry%%:*}"
  weight="${entry##*:}"
  src="$SRC_DIR/$name.ttf"

  if [[ ! -f "$src" ]]; then
    echo "SKIP $name.ttf — not found in $SRC_DIR"
    continue
  fi

  tmp="/tmp/$name-fixed.ttf"

  # Fix maxZones for Firefox OTS sanitizer
  python3 -c "
from fontTools.ttLib import TTFont
font = TTFont('$src')
if font['maxp'].maxZones == 0:
    font['maxp'].maxZones = 1
    print('  Fixed maxZones: 0 -> 1')
font.save('$tmp')
"

  woff2_compress "$tmp"
  mv "/tmp/$name-fixed.woff2" "$OUT/$name.woff2"
  rm "$tmp"

  size=$(stat -c%s "$OUT/$name.woff2")
  echo "OK $name.woff2 (weight $weight, $size bytes)"
done

echo "Done."
