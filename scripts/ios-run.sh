#!/usr/bin/env bash
# scripts/ios-run.sh — launch LittleLove on an iOS simulator.
#
# Usage:
#   ./scripts/ios-run.sh                  # boots "iPhone 17" and runs
#   ./scripts/ios-run.sh "iPhone 17 Pro"  # specific simulator
#
# Optional env:
#   LLOVE_FIXTURES=demo  — seed the inbox with demo rooms
#   LLOVE_SERVER=…       — point at a dev API server
set -euo pipefail

DEVICE="${1:-iPhone 17}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

cd "$ROOT_DIR/app"
exec flutter run -d "$DEVICE" \
  ${LLOVE_FIXTURES:+--dart-define=LLOVE_FIXTURES="$LLOVE_FIXTURES"} \
  ${LLOVE_SERVER:+--dart-define=LLOVE_SERVER="$LLOVE_SERVER"}
