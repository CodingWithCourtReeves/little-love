#!/usr/bin/env bash
# scripts/ios-deploy.sh — build, sign, and install LittleLove on a connected iPhone.
#
# Prerequisites (one-time):
#   - Xcode installed; Apple ID added in Xcode → Settings → Accounts
#   - iPhone connected via USB, unlocked, "Trust This Computer" tapped
#   - On first install: open Settings → General → VPN & Device Management on
#     the iPhone and trust the developer profile (one tap)
#
# Usage:
#   ./scripts/ios-deploy.sh                       # release build, auto-detect device
#   ./scripts/ios-deploy.sh --debug               # debug build (7-day signing limit)
#   ./scripts/ios-deploy.sh --device <udid>       # target a specific device
#   ./scripts/ios-deploy.sh --server <url>        # override LLOVE_SERVER for this build
#
# Optional env:
#   LLOVE_SERVER=…       — point at a dev API server. Use a public URL (ngrok,
#                          Tailscale Funnel, etc.) — the phone cannot reach
#                          your Mac's loopback. Equivalent to --server.
#   LLOVE_FIXTURES=demo  — seed the inbox with demo rooms.
#
# Release-build note: app/ios/Flutter/Release.xcconfig bakes a default
# LLOVE_SERVER (production) into DART_DEFINES. When --server or LLOVE_SERVER
# is supplied for a release build, this script rewrites that line for the
# duration of the build and restores the original on exit. Debug builds
# leave the xcconfig alone and rely on --dart-define on the build command.

set -euo pipefail

MODE="release"
DEVICE_ID=""
SERVER_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)   MODE="debug"; shift ;;
    --release) MODE="release"; shift ;;
    --device)  DEVICE_ID="${2:?--device requires a value}"; shift 2 ;;
    --server)  SERVER_URL="${2:?--server requires a URL}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --server wins; LLOVE_SERVER env is the fallback for back-compat.
if [[ -z "$SERVER_URL" && -n "${LLOVE_SERVER:-}" ]]; then
  SERVER_URL="$LLOVE_SERVER"
fi
export LLOVE_SERVER="${SERVER_URL:-${LLOVE_SERVER:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR/app"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(
    flutter devices --machine 2>/dev/null | python3 -c '
import json, sys
devices = json.load(sys.stdin)
phys = [
    d for d in devices
    if d.get("platform", "").startswith("ios")
    and not d.get("emulator", False)
]
if not phys:
    sys.stderr.write(
        "no physical iOS device detected\n"
        "  check: iPhone connected via USB, unlocked, Trust This Computer tapped\n"
        "  list:  flutter devices\n"
    )
    sys.exit(1)
if len(phys) > 1:
    sys.stderr.write(
        f"multiple physical iOS devices found ({len(phys)}); use --device <id>:\n"
    )
    for d in phys:
        sys.stderr.write(f"  {d[\"id\"]}  {d[\"name\"]}\n")
    sys.exit(1)
print(phys[0]["id"])
'
  )"
fi

echo "→ building LittleLove ($MODE) for $DEVICE_ID"
if [[ -n "$LLOVE_SERVER" ]]; then
  echo "→ LLOVE_SERVER=$LLOVE_SERVER"
fi

# For release builds, Release.xcconfig's DART_DEFINES wins over --dart-define
# on the command line. When the caller asked for a non-default server, rewrite
# the xcconfig in place for the build and restore it on exit (including ^C).
XCCONFIG="$ROOT_DIR/app/ios/Flutter/Release.xcconfig"
XCCONFIG_BACKUP=""
restore_xcconfig() {
  if [[ -n "$XCCONFIG_BACKUP" && -f "$XCCONFIG_BACKUP" ]]; then
    mv "$XCCONFIG_BACKUP" "$XCCONFIG"
    XCCONFIG_BACKUP=""
  fi
}
trap restore_xcconfig EXIT INT TERM

if [[ "$MODE" == "release" && -n "$LLOVE_SERVER" ]]; then
  XCCONFIG_BACKUP="$(mktemp)"
  cp "$XCCONFIG" "$XCCONFIG_BACKUP"
  encoded="$(printf '%s' "LLOVE_SERVER=$LLOVE_SERVER" | base64)"
  # macOS BSD sed: -i needs an empty extension arg.
  sed -i '' -E "s|^DART_DEFINES=.*|DART_DEFINES=${encoded}|" "$XCCONFIG"
  echo "→ Release.xcconfig DART_DEFINES rewritten (will restore on exit)"
fi

flutter build ios --"$MODE" \
  ${LLOVE_FIXTURES:+--dart-define=LLOVE_FIXTURES="$LLOVE_FIXTURES"} \
  ${LLOVE_SERVER:+--dart-define=LLOVE_SERVER="$LLOVE_SERVER"}

restore_xcconfig

echo "→ installing on $DEVICE_ID"
flutter install -d "$DEVICE_ID"

echo "✓ installed. Find LittleLove on your home screen."
