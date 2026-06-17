#!/usr/bin/env bash
# scripts/dev-phones.sh
#
# Bring up the full attachment backend and expose it to physical phones via two
# ngrok https tunnels (API + MinIO blob store), then print the LLOVE_SERVER to
# build the app with. Uses the project-local ngrok.yml; the authtoken is read
# from your global ngrok config.
#
#   ./scripts/dev-phones.sh
#   # …then, in another shell, build to a phone:
#   cd app && flutter run --release -d <device-id> \
#     --dart-define=LLOVE_SERVER=<printed api url>
#
# Stop everything with:  ./scripts/dev-phones.sh down
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

GLOBAL_NGROK="$HOME/Library/Application Support/ngrok/ngrok.yml"
API_LOCAL_PORT=7707
RUN_DIR="$ROOT_DIR/.dev"
mkdir -p "$RUN_DIR"
NGROK_LOG="$RUN_DIR/ngrok.log"
SERVER_LOG="$RUN_DIR/server.log"
PIDS_FILE="$RUN_DIR/dev-phones.pids"

stop_all() {
  echo "▶ stopping ngrok + server…"
  [[ -f "$PIDS_FILE" ]] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDS_FILE"
  rm -f "$PIDS_FILE"
  pkill -f "ngrok start llove-" 2>/dev/null || true
  echo "  (postgres + minio left running; ./scripts/dev-down.sh to stop them)"
}

if [[ "${1:-}" == "down" ]]; then
  stop_all
  exit 0
fi

tunnel_url() { # $1 = tunnel name → its public https url
  curl -s http://localhost:4040/api/tunnels \
    | python3 -c "import sys,json;[print(t['public_url']) for t in json.load(sys.stdin)['tunnels'] if t['name'].startswith('$1') and t['public_url'].startswith('https')]" \
    | head -1
}

echo "▶ 1/4 postgres + minio (docker)…"
docker compose -f docker-compose.yml -f docker-compose.minio.yml up -d postgres minio minio-init >/dev/null

echo "▶ 2/4 ngrok tunnels (llove-api:${API_LOCAL_PORT}, llove-minio:9000)…"
pkill -f "ngrok start llove-" 2>/dev/null || true
nohup ngrok start llove-api llove-minio \
  --config ngrok.yml --config "$GLOBAL_NGROK" --log=stdout > "$NGROK_LOG" 2>&1 &
echo "$!" > "$PIDS_FILE"

echo -n "   waiting for tunnels"
API_URL=""; MINIO_URL=""
for _ in $(seq 1 30); do
  API_URL="$(tunnel_url llove-api || true)"
  MINIO_URL="$(tunnel_url llove-minio || true)"
  [[ -n "$API_URL" && -n "$MINIO_URL" ]] && break
  echo -n "."; sleep 1
done
echo
if [[ -z "$API_URL" || -z "$MINIO_URL" ]]; then
  echo "✗ tunnels did not come up. ngrok log:" >&2; tail -20 "$NGROK_LOG" >&2; stop_all; exit 1
fi
echo "   api   → $API_URL"
echo "   minio → $MINIO_URL"

echo "▶ 3/4 api server (cargo run, R2_ENDPOINT=$MINIO_URL)…"
PORT="$API_LOCAL_PORT" \
DATABASE_URL="postgres://littlelove:dev@localhost:${POSTGRES_PORT}/littlelove" \
R2_ACCOUNT_ID=local R2_BUCKET=littlelove-media \
R2_ACCESS_KEY_ID=littlelove R2_SECRET_ACCESS_KEY=devsecret123 \
R2_ENDPOINT="$MINIO_URL" \
  nohup cargo run -p littlelove-api > "$SERVER_LOG" 2>&1 &
echo "$!" >> "$PIDS_FILE"

echo -n "   waiting for server health"
for _ in $(seq 1 60); do
  if curl -s -o /dev/null -w '%{http_code}' "$API_URL/health" 2>/dev/null | grep -q 200; then break; fi
  echo -n "."; sleep 1
done
echo

echo "▶ 4/4 ready."
cat <<EOF

  Build to a phone (one per device):
    cd app && flutter run --release -d <device-id> \\
      --dart-define=LLOVE_SERVER=$API_URL

  List devices:  cd app && flutter devices
  Logs:          tail -f $SERVER_LOG   |   tail -f $NGROK_LOG
  Stop:          ./scripts/dev-phones.sh down
EOF
