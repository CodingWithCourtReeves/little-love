#!/usr/bin/env bash
# scripts/dev-attachments.sh
#
# Like dev-up.sh, but adds a local MinIO (S3-compatible) blob store so the
# end-to-end attachment flow (encrypt → presign → upload → download → decrypt)
# works fully offline, with no Cloudflare R2 account. See docker-compose.minio.yml.
#
# After this is up:
#   ./scripts/demo.sh court        # one client
#   ./scripts/demo.sh kaitlyn      # the other
# Pair them, then use the composer "+" to send a photo.
#
# Note: the macOS demo client can send/receive PHOTOS. Video needs an iOS
# device/simulator (video_thumbnail has no macOS support).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

# Persist computed values for other shells / tooling (matches dev-up.sh + MinIO).
cat > "$ROOT_DIR/.dev.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
API_PORT=${API_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
DATABASE_URL=${DATABASE_URL}
MINIO_PORT=${MINIO_PORT}
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT}
EOF

echo "▶ project:       ${COMPOSE_PROJECT_NAME}"
echo "▶ api:           http://127.0.0.1:${API_PORT}"
echo "▶ postgres:      localhost:${POSTGRES_PORT}"
echo "▶ minio (s3):    http://localhost:${MINIO_PORT}"
echo "▶ minio console: http://localhost:${MINIO_CONSOLE_PORT}  (littlelove / devsecret123)"

MINIO_PORT="${MINIO_PORT}" MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT}" \
  docker compose -f docker-compose.yml -f docker-compose.minio.yml up -d --build
