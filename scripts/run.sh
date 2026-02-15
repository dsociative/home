#!/usr/bin/env bash
set -euo pipefail

# Build and run font/devicon update scripts inside Docker
# Usage: ./scripts/run.sh [devicon-version]
# Example: ./scripts/run.sh v2.16.0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
DEVICON_VERSION="${1:-v2.16.0}"

# Copy source TTFs into fonts-src/ for Docker context
FONT_SRC="$ROOT/fonts-src"
mkdir -p "$FONT_SRC"

for f in zed-mono-extended.ttf zed-mono-extendedbold.ttf; do
  src="$HOME/.local/share/fonts/$f"
  if [[ -f "$src" ]]; then
    cp "$src" "$FONT_SRC/"
  else
    echo "WARNING: $src not found, skipping"
  fi
done

# Build the tools image
docker build -t geektech-tools -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

# Run both update scripts, mounting the project directory
docker run --rm \
  -v "$ROOT:/site" \
  -e FONT_SRC_DIR=/site/fonts-src \
  geektech-tools \
  bash -c "./scripts/update-fonts.sh && ./scripts/update-devicon.sh $DEVICON_VERSION"

# Clean up fonts-src
rm -rf "$FONT_SRC"

echo "All done."
