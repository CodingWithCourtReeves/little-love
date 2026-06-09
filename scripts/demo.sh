#!/usr/bin/env bash
# scripts/demo.sh — run a LittleLove desktop client wired to the dev stack.
#
# Usage:
#   ./scripts/demo.sh court     # uses your real ~/.littlelove/
#   ./scripts/demo.sh kaitlyn   # uses a fake $HOME under .dev/kaitlyn-home/
#
# First run generates a shared 32-byte key and persists it to .dev.demo.key
# (gitignored). Subsequent runs reuse the same key so the two clients can
# decrypt each other.
set -euo pipefail

if [ $# -ne 1 ] || { [ "$1" != "court" ] && [ "$1" != "kaitlyn" ]; }; then
  echo "usage: $0 court|kaitlyn" >&2
  exit 2
fi
WHO="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [ ! -f .dev.env ]; then
  echo "✗ .dev.env not found. Run ./scripts/dev-up.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .dev.env

KEY_FILE="$ROOT_DIR/.dev.demo.key"
if [ ! -f "$KEY_FILE" ]; then
  openssl rand -hex 32 > "$KEY_FILE"
  echo "▶ generated shared key → $KEY_FILE"
fi
SHARED_KEY="$(cat "$KEY_FILE")"

if [ "$WHO" = "court" ]; then
  DEMO_HOME="$HOME"
  ME_DISPLAY="Court"
  THEM_USER="kaitlyn"
  THEM_DISPLAY="Kaitlyn"
else
  DEMO_HOME="$ROOT_DIR/.dev/kaitlyn-home"
  ME_DISPLAY="Kaitlyn"
  THEM_USER="court"
  THEM_DISPLAY="Court"
fi

mkdir -p "$DEMO_HOME/.littlelove"
cat > "$DEMO_HOME/.littlelove/config.toml" <<EOF
username = "$WHO"
display_name = "$ME_DISPLAY"
server_url = "ws://127.0.0.1:${API_PORT}/ws"
shared_key = "$SHARED_KEY"

[contact]
username = "$THEM_USER"
display_name = "$THEM_DISPLAY"
EOF

echo "▶ user:    $WHO  (talking to $THEM_USER)"
echo "▶ home:    $DEMO_HOME"
echo "▶ server:  ws://127.0.0.1:${API_PORT}/ws"
echo "▶ launching flutter run -d macos…"

cd app
HOME="$DEMO_HOME" exec flutter run -d macos
