#!/usr/bin/env bash
# scripts/sim-couple.sh — boot TWO iOS simulators as an already-paired couple
# (court + kaitlyn) against a LOCAL backend, for cross-"device" chat testing
# (e.g. message-edit round-trips) without the physical phones.
#
#   ./scripts/sim-couple.sh            # iPhone 17 = court, iPhone 17 Pro = kaitlyn
#   COURT_SIM="iPhone 17" KAITLYN_SIM="iPhone Air" ./scripts/sim-couple.sh
#   ./scripts/sim-couple.sh down       # stop the local api (leaves docker up)
#
# What it does: postgres+minio (docker) → api (cargo run, localhost, auto-migrates)
# → seed_couple (dev-only, feature-gated) creates+pairs the couple+room → build the
# app once → install on both sims and launch each with its seeded identity (passed
# at runtime via SIMCTL_CHILD_* env, so one build serves both).
#
# Calling/video/push don't work on the simulator; this is for text chat. The seed
# tool is gated behind the `dev-seed` cargo feature and refuses non-localhost DBs,
# so nothing here is reachable in production.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

RUN_DIR="$ROOT_DIR/.dev"
mkdir -p "$RUN_DIR"
SERVER_LOG="$RUN_DIR/sim-server.log"
PIDS_FILE="$RUN_DIR/sim-couple.pids"
FIXTURE="$ROOT_DIR/scripts/dev-couple.json"

COURT_SIM="${COURT_SIM:-iPhone 17}"
KAITLYN_SIM="${KAITLYN_SIM:-iPhone 17 Pro}"
SERVER_URL="http://127.0.0.1:${API_PORT}"

stop_all() {
  echo "▶ stopping local api…"
  [[ -f "$PIDS_FILE" ]] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDS_FILE"
  rm -f "$PIDS_FILE"
  # The cargo-run wrapper spawns the actual server as a child; sweep it too.
  pkill -f "target/debug/littlelove-api" 2>/dev/null || true
  echo "  (postgres + minio + simulators left running)"
}

if [[ "${1:-}" == "down" ]]; then
  stop_all
  exit 0
fi

if [[ "$COURT_SIM" == "$KAITLYN_SIM" ]]; then
  echo "✗ COURT_SIM and KAITLYN_SIM must be different devices (got '$COURT_SIM')." >&2
  exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then
  echo "✗ $FIXTURE missing (the committed dev-couple fixture)." >&2
  exit 1
fi

# Exact-name UDID of an available simulator (so "iPhone 17" doesn't match
# "iPhone 17 Pro").
udid_for() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
want=sys.argv[1]
data=json.load(sys.stdin)
for runtime in data['devices'].values():
    for d in runtime:
        if d.get('isAvailable') and d['name']==want:
            print(d['udid']); sys.exit(0)
sys.exit(1)
" "$1"
}

phrase_for() { # $1 = court|kaitlyn → its 12-word phrase from the fixture
  python3 -c "import json;print(json.load(open('$FIXTURE'))['$1']['phrase'])"
}

COURT_UDID="$(udid_for "$COURT_SIM")" || { echo "✗ no available simulator named '$COURT_SIM'" >&2; exit 1; }
KAITLYN_UDID="$(udid_for "$KAITLYN_SIM")" || { echo "✗ no available simulator named '$KAITLYN_SIM'" >&2; exit 1; }

# Kill any api left running by a prior run (it holds API_PORT); otherwise the
# fresh cargo run can't bind and the health check times out.
if [[ -f "$PIDS_FILE" ]]; then
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDS_FILE"
fi
pkill -f "target/debug/littlelove-api" 2>/dev/null || true

echo "▶ 1/5 postgres + minio (docker)…"
docker compose -f docker-compose.yml -f docker-compose.minio.yml up -d postgres minio minio-init >/dev/null

echo "▶ 2/5 api server (cargo run → ${SERVER_URL}, auto-migrates)…"
: > "$PIDS_FILE"
PORT="$API_PORT" \
DATABASE_URL="$DATABASE_URL" \
R2_ACCOUNT_ID=local R2_BUCKET=littlelove-media \
R2_ACCESS_KEY_ID=littlelove R2_SECRET_ACCESS_KEY=devsecret123 \
R2_ENDPOINT="http://127.0.0.1:9000" \
  nohup cargo run -p littlelove-api > "$SERVER_LOG" 2>&1 &
echo "$!" >> "$PIDS_FILE"

echo -n "   waiting for api health"
for _ in $(seq 1 90); do
  if curl -s -o /dev/null -w '%{http_code}' "$SERVER_URL/health" 2>/dev/null | grep -q 200; then break; fi
  echo -n "."; sleep 1
done
echo
if ! curl -s -o /dev/null -w '%{http_code}' "$SERVER_URL/health" 2>/dev/null | grep -q 200; then
  echo "✗ api did not become healthy. Log tail:" >&2; tail -30 "$SERVER_LOG" >&2; stop_all; exit 1
fi

echo "▶ 3/5 seed + pair the couple (dev-only)…"
DATABASE_URL="$DATABASE_URL" \
  cargo run -p littlelove-api --features dev-seed --bin seed_couple -- "$FIXTURE"

echo "▶ 4/5 build + install per partner…"
# Flutter's Platform.environment is empty on iOS, so the seeded identity must be
# baked at build time with --dart-define (one build per partner). Builds are
# incremental after the first, so the second partner is quick.
APP="$ROOT_DIR/app/build/ios/iphonesimulator/Runner.app"
open -a Simulator

build_install_launch() { # $1 = udid  $2 = display name  $3 = court|kaitlyn
  local udid="$1" name="$2" user="$3"
  echo "   • building @$user → $name"
  ( cd app && flutter build ios --debug --simulator \
      --dart-define=LLOVE_SERVER="$SERVER_URL" \
      --dart-define=LLOVE_DEV_USERNAME="$user" \
      --dart-define=LLOVE_DEV_PHRASE="$(phrase_for "$user")" )
  local bundle
  bundle="$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
  echo "     installed + launched on $name"
}

echo "▶ 5/5 launch both simulators…"
build_install_launch "$COURT_UDID" "$COURT_SIM" court
build_install_launch "$KAITLYN_UDID" "$KAITLYN_SIM" kaitlyn

cat <<EOF

▶ ready.
  api:      $SERVER_URL   (log: $SERVER_LOG)
  court:    $COURT_SIM
  kaitlyn:  $KAITLYN_SIM
  Both are signed in and paired. Send a message on one, edit it, watch it update
  on the other (with the "edited" marker).

  Re-launch after a code change: re-run this script (identities persist per sim).
  Stop the api:  ./scripts/sim-couple.sh down
EOF
