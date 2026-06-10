#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT/app/assets/app-icon/littlelove-app-icon-master.png"
MAC_ICONSET="$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_ICON="$ROOT/app/windows/runner/resources/app_icon.ico"
IOS_ICONSET="$ROOT/app/ios/Runner/Assets.xcassets/AppIcon.appiconset"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required: brew install imagemagick" >&2
  exit 1
fi

if [[ ! -f "$MASTER" ]]; then
  echo "Missing master icon: $MASTER" >&2
  exit 1
fi

# macOS
for size in 16 32 64 128 256 512 1024; do
  magick "$MASTER" -resize "${size}x${size}" "PNG32:$MAC_ICONSET/app_icon_${size}.png"
done
echo "Generated macOS icons in $MAC_ICONSET"

# Windows
magick "$MASTER" \
  -define icon:auto-resize=256,128,64,48,32,24,16 \
  "$WIN_ICON"
echo "Generated Windows icon at $WIN_ICON"

# iOS — filenames/sizes per the AppIcon.appiconset/Contents.json scaffolded
# by `flutter create --platforms=ios`. Apple rejects PNGs with an alpha
# channel on the App Store marketing icon, so flatten on white.
if [[ -d "$IOS_ICONSET" ]]; then
  IOS_ICONS=(
    "Icon-App-20x20@1x.png:20"
    "Icon-App-20x20@2x.png:40"
    "Icon-App-20x20@3x.png:60"
    "Icon-App-29x29@1x.png:29"
    "Icon-App-29x29@2x.png:58"
    "Icon-App-29x29@3x.png:87"
    "Icon-App-40x40@1x.png:40"
    "Icon-App-40x40@2x.png:80"
    "Icon-App-40x40@3x.png:120"
    "Icon-App-60x60@2x.png:120"
    "Icon-App-60x60@3x.png:180"
    "Icon-App-76x76@1x.png:76"
    "Icon-App-76x76@2x.png:152"
    "Icon-App-83.5x83.5@2x.png:167"
    "Icon-App-1024x1024@1x.png:1024"
  )
  for entry in "${IOS_ICONS[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    magick "$MASTER" -resize "${size}x${size}" \
      -background white -alpha remove -alpha off \
      "PNG24:$IOS_ICONSET/$name"
  done
  echo "Generated iOS icons in $IOS_ICONSET"
else
  echo "Skipped iOS icons — $IOS_ICONSET does not exist (run flutter create --platforms=ios .)"
fi
