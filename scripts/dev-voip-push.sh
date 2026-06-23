#!/usr/bin/env bash
# scripts/dev-voip-push.sh — fire ONE synthetic APNs VoIP push at a device.
#
# Decouples the CallKit-wake pipeline from the whole WebRTC/call flow: if the
# native incoming-call screen appears from a *killed* app after running this,
# the wake path (PushKit registry → showCallkitIncoming → completion) works,
# independent of whether media ever connects. The single biggest debugging
# time-saver for voice calling (spec §9).
#
# Usage:
#   ./scripts/dev-voip-push.sh <voip-device-token> [call_id] [from]
#
# The VoIP device token is the PushKit token (kind=voip), distinct from the
# alert token. Get it from the dev server logs (RegisterPush) or from the DB:
#   psql "$DATABASE_URL" -tc \
#     "SELECT apns_token FROM device_push_tokens WHERE kind='voip' ORDER BY updated_at DESC LIMIT 1"
#
# Reads APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID / APNS_TOPIC from .secrets.env
# (sourced if present). Targets the APNs SANDBOX endpoint (dev builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -f "$ROOT_DIR/.secrets.env" ]] && source "$ROOT_DIR/.secrets.env"

TOKEN="${1:?usage: dev-voip-push.sh <voip-device-token> [call_id] [from]}"
CALL_ID="${2:-test-$(date +%s)}"
FROM="${3:-Partner}"
ROOM_ID="${ROOM_ID:-test-room}"

: "${APNS_KEY_P8:?APNS_KEY_P8 not set (source .secrets.env)}"
: "${APNS_KEY_ID:?APNS_KEY_ID not set}"
: "${APNS_TEAM_ID:?APNS_TEAM_ID not set}"
: "${APNS_TOPIC:?APNS_TOPIC not set}"
VOIP_TOPIC="${APNS_VOIP_TOPIC:-${APNS_TOPIC}.voip}"

# Build the APNs ES256 provider JWT. openssl signs (DER); python repacks the
# signature to the raw R||S form JOSE requires and assembles the token.
JWT="$(
  APNS_KEY_ID="$APNS_KEY_ID" APNS_TEAM_ID="$APNS_TEAM_ID" APNS_KEY_P8="$APNS_KEY_P8" \
  python3 - <<'PY'
import base64, json, os, subprocess, tempfile, time

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

header = {"alg": "ES256", "kid": os.environ["APNS_KEY_ID"]}
claims = {"iss": os.environ["APNS_TEAM_ID"], "iat": int(time.time())}
signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"

with tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False) as f:
    f.write(os.environ["APNS_KEY_P8"])
    keypath = f.name
der = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", keypath],
    input=signing_input.encode(), capture_output=True, check=True,
).stdout
os.unlink(keypath)

# DER ECDSA: 0x30 len 0x02 rlen R 0x02 slen S  →  raw R||S (32 bytes each).
i = 2 + ((der[1] & 0x7f) if der[1] & 0x80 else 0)
rlen = der[i + 1]; r = der[i + 2 : i + 2 + rlen]
j = i + 2 + rlen
slen = der[j + 1]; s = der[j + 2 : j + 2 + slen]
raw = r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")
print(f"{signing_input}.{b64url(raw)}")
PY
)"

PAYLOAD="$(printf '{"call_id":"%s","room_id":"%s","from":"%s"}' "$CALL_ID" "$ROOM_ID" "$FROM")"

echo "▶ VoIP push → token ${TOKEN:0:8}…  topic=$VOIP_TOPIC  call_id=$CALL_ID"
curl -sS --http2 \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $VOIP_TOPIC" \
  -H "apns-push-type: voip" \
  -H "apns-priority: 10" \
  -d "$PAYLOAD" \
  -w "\nAPNs HTTP %{http_code}\n" \
  "https://api.sandbox.push.apple.com/3/device/$TOKEN"
echo "If the killed app rings (native CallKit screen), the wake path works."
