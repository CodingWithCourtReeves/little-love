#!/usr/bin/env bash
# scripts/demo.sh — launch a LittleLove desktop client against the dev stack.
#
# Usage:
#   ./scripts/demo.sh court     # uses your real $HOME
#   ./scripts/demo.sh kaitlyn   # uses .dev/kaitlyn-home/ as $HOME so a
#                               # separate ~/.littlelove/account.json
#                               # gets created
#
# Reads .dev.env for API_PORT (run ./scripts/dev-up.sh first to create it).
# Launches with LLOVE_FIXTURES=demo so the inbox is pre-seeded with two
# demo rooms (Kaitlyn + Sage) while WT-D's real pairing flow lands.
#
# Day-1 behavior (writing config.toml with a pre-shared key) is gone: spec
# §10.3 removed the config.toml reader, and WT-C's signup flow now derives
# identity from a 12-word recovery phrase persisted in the OS keystore.
set -euo pipefail

WHO="${1:-}"
if [[ "$WHO" != "court" && "$WHO" != "kaitlyn" ]]; then
  echo "usage: $0 court|kaitlyn" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .dev.env ]]; then
  echo "✗ .dev.env not found. Run ./scripts/dev-up.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .dev.env

if [[ "$WHO" == "court" ]]; then
  DEMO_HOME="$HOME"
else
  DEMO_HOME="$ROOT_DIR/.dev/kaitlyn-home"
  mkdir -p "$DEMO_HOME"
fi

echo "▶ user:    $WHO"
echo "▶ home:    $DEMO_HOME"
echo "▶ server:  http://127.0.0.1:${API_PORT}"
echo "▶ launching flutter run -d macos with demo fixtures…"

cd app
HOME="$DEMO_HOME" exec flutter run -d macos \
  --dart-define=LLOVE_FIXTURES=demo \
  --dart-define=LLOVE_SERVER="http://127.0.0.1:${API_PORT}"
