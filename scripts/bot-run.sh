#!/usr/bin/env bash
# scripts/bot-run.sh — run littlelove-bot in a restart loop.
#
# v0.2 of the bot has no built-in WebSocket reconnect; on any network blip
# or server hiccup it exits. This script wraps it in a forever loop so the
# bot stays online while you sleep / work.
#
# Usage:
#   ./scripts/bot-run.sh                           # uses env / defaults
#   LITTLELOVE_BOT_SERVER=wss://... \
#     LITTLELOVE_BOT_LLM_URL=http://127.0.0.1:1234/v1 \
#     LITTLELOVE_BOT_MODEL=your-model-id \
#     ./scripts/bot-run.sh
#   ./scripts/bot-run.sh --character-card path/to/card.png
#
# All extra arguments are passed through to `littlelove-bot run`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOT="$ROOT_DIR/target/release/littlelove-bot"

if [[ ! -x "$BOT" ]]; then
  echo "littlelove-bot not built. Run:" >&2
  echo "  cargo build -p littlelove-bot --release" >&2
  exit 1
fi

if [[ -z "${LITTLELOVE_BOT_SERVER:-}" ]]; then
  echo "LITTLELOVE_BOT_SERVER is required (e.g. wss://your.littlelove.server)" >&2
  exit 1
fi

# Quick liveness check on the LLM endpoint so we don't loop forever
# against a server that hasn't started.
LLM_URL="${LITTLELOVE_BOT_LLM_URL:-http://localhost:8080/v1}"
if ! curl -fsS --max-time 3 "${LLM_URL%/}/models" >/dev/null 2>&1; then
  echo "warn: $LLM_URL not reachable. Make sure your local LLM server is running." >&2
  echo "      LM Studio: Developer tab → Start Server (defaults to :1234)." >&2
  # Keep going — the run command will surface the actual error.
fi

echo "Starting littlelove-bot restart loop. Ctrl-C to stop."
while true; do
  printf '\n--- bot starting at %s ---\n' "$(date)"
  "$BOT" run "$@" || true
  printf '\n--- bot exited at %s, restarting in 2s ---\n' "$(date)"
  sleep 2
done
