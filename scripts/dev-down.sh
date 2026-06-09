#!/usr/bin/env bash
# scripts/dev-down.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

docker compose down
