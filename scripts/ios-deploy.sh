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
#
# Optional env:
#   LLOVE_SERVER=…       — point at a dev API server. Use the Mac's LAN IP
#                          (e.g. http://192.168.1.42:7739), not localhost — the
#                          phone cannot reach your Mac's loopback.
#   LLOVE_FIXTURES=demo  — seed the inbox with demo rooms.

set -euo pipefail

MODE="release"
DEVICE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)   MODE="debug"; shift ;;
    --release) MODE="release"; shift ;;
    --device)  DEVICE_ID="${2:?--device requires a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

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

flutter build ios --"$MODE" \
  ${LLOVE_FIXTURES:+--dart-define=LLOVE_FIXTURES="$LLOVE_FIXTURES"} \
  ${LLOVE_SERVER:+--dart-define=LLOVE_SERVER="$LLOVE_SERVER"}

echo "→ installing on $DEVICE_ID"
flutter install -d "$DEVICE_ID"

echo "✓ installed. Find LittleLove on your home screen."
