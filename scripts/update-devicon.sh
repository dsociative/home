#!/usr/bin/env bash
set -euo pipefail

# Update devicon CSS and fonts from GitHub
# Usage: ./scripts/update-devicon.sh [version]
# Example: ./scripts/update-devicon.sh v2.16.0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OUT_CSS="$ROOT/static/css"
OUT_FONTS="$OUT_CSS/fonts"
VERSION="${1:-latest}"

BASE="https://cdn.jsdelivr.net/gh/devicons/devicon@$VERSION"

echo "Downloading devicon@$VERSION..."

mkdir -p "$OUT_FONTS"

# Download CSS
curl -sL "$BASE/devicon.min.css" -o "$OUT_CSS/devicon.min.css"
echo "OK devicon.min.css ($(stat -c%s "$OUT_CSS/devicon.min.css") bytes)"

# Download fonts (woff + ttf only, skip legacy eot/svg)
for f in devicon.woff devicon.ttf; do
  curl -sL "$BASE/fonts/$f" -o "$OUT_FONTS/$f"
  echo "OK fonts/$f ($(stat -c%s "$OUT_FONTS/$f") bytes)"
done

# Clean up @font-face: keep only woff + ttf, strip query params
python3 -c "
import re
with open('$OUT_CSS/devicon.min.css', 'r') as f:
    css = f.read()
old_ff = re.search(r'@font-face\{[^}]+\}', css).group()
new_ff = \"@font-face{font-family:'devicon';src:url('fonts/devicon.woff') format('woff'),url('fonts/devicon.ttf') format('truetype');font-weight:normal;font-style:normal}\"
css = css.replace(old_ff, new_ff)
with open('$OUT_CSS/devicon.min.css', 'w') as f:
    f.write(css)
print('Cleaned @font-face (removed eot/svg)')
"

echo "Done."
