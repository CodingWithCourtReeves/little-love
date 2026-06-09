#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT/app/assets/app-icon/littlelove-app-icon-master.png"
MAC_ICONSET="$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_ICON="$ROOT/app/windows/runner/resources/app_icon.ico"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required: brew install imagemagick" >&2
  exit 1
fi

if [[ ! -f "$MASTER" ]]; then
  echo "Missing master icon: $MASTER" >&2
  exit 1
fi

for size in 16 32 64 128 256 512 1024; do
  magick "$MASTER" -resize "${size}x${size}" "PNG32:$MAC_ICONSET/app_icon_${size}.png"
done

magick "$MASTER" \
  -define icon:auto-resize=256,128,64,48,32,24,16 \
  "$WIN_ICON"

echo "Generated macOS icons in $MAC_ICONSET"
echo "Generated Windows icon at $WIN_ICON"
