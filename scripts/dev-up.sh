#!/usr/bin/env bash
# scripts/dev-up.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

# Persist the computed values for other shells / tooling that may need them.
cat > "$ROOT_DIR/.dev.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
API_PORT=${API_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
DATABASE_URL=${DATABASE_URL}
EOF

echo "▶ project:  ${COMPOSE_PROJECT_NAME}"
echo "▶ api:      http://127.0.0.1:${API_PORT}"
echo "▶ postgres: localhost:${POSTGRES_PORT}"

docker compose up -d --build
