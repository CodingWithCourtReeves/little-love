#!/usr/bin/env bash
# scripts/railway-bootstrap.sh — provision the LittleLove Railway project.
#
# What it does (idempotent — safe to re-run):
#   1. Verifies `railway` CLI is authenticated.
#   2. Links to the `littlelove` project (env: production).
#   3. Adds the managed Postgres plugin if missing.
#   4. Creates the `littlelove-api` service if missing.
#   5. Wires `RUST_LOG` plain var + `DATABASE_URL` reference to the Postgres
#      plugin on `littlelove-api`.
#   6. Generates a Railway-managed `*.up.railway.app` domain on `littlelove-api`.
#   7. Prints a summary you paste into docs/railway.md + GitHub Actions secrets.
#
# Prerequisites:
#   - `brew install railway` (or upgrade if you already have it)
#   - `railway login --browser` (interactive; do once)
#   - Project must already exist. If it doesn't:
#       railway init --name littlelove
#     then re-run this script with the printed project ID.
#
# Usage:
#   ./scripts/railway-bootstrap.sh                              # uses default project ID
#   RAILWAY_PROJECT_ID=<id> ./scripts/railway-bootstrap.sh      # override
#
# After it succeeds:
#   - Add `RAILWAY_TOKEN` and `RAILWAY_PROJECT_ID` to GitHub Actions secrets
#   - Trigger the `deploy` workflow with a tag
#   - Verify: curl https://<printed-domain>/health

set -euo pipefail

PROJECT_NAME="littlelove"
API_SERVICE_NAME="littlelove-api"
PROJECT_ID="${RAILWAY_PROJECT_ID:-21c1e727-a06c-449d-81b4-8cdf194bd196}"
ENVIRONMENT="production"

# ---------- 1. Pre-flight ----------

if ! command -v railway >/dev/null 2>&1; then
  echo "✗ railway CLI not found. Install with: brew install railway" >&2
  exit 1
fi

if ! railway whoami >/dev/null 2>&1; then
  echo "✗ not authenticated. Run: railway login --browser" >&2
  exit 1
fi

echo "→ railway CLI: $(railway --version 2>&1 | head -1)"
echo "→ authenticated as: $(railway whoami 2>&1 | head -1)"

# ---------- 2. Link to project ----------

echo "→ linking to project $PROJECT_NAME ($PROJECT_ID), environment $ENVIRONMENT"
if ! railway link --project "$PROJECT_ID" --environment "$ENVIRONMENT" 2>&1; then
  echo "✗ link failed. Verify the project exists at railway.com." >&2
  echo "  If not, create it: railway init --name $PROJECT_NAME" >&2
  exit 1
fi

# ---------- 3. Postgres plugin ----------

if railway service Postgres >/dev/null 2>&1; then
  echo "→ Postgres already exists, skipping"
else
  echo "→ adding Postgres plugin"
  railway add --database postgres
fi

# ---------- 4. littlelove-api service ----------

API_IMAGE="ghcr.io/codingwithcourtreeves/littlelove-api:latest"
if railway service "$API_SERVICE_NAME" >/dev/null 2>&1; then
  echo "→ $API_SERVICE_NAME already exists, skipping create"
else
  echo "→ creating $API_SERVICE_NAME service from $API_IMAGE"
  if ! railway add --service "$API_SERVICE_NAME" --image "$API_IMAGE" 2>/dev/null; then
    railway add --service "$API_SERVICE_NAME"
    echo "  ⚠ --image flag not supported by this CLI version."
    echo "    Open railway.com → littlelove → $API_SERVICE_NAME → Settings → Source"
    echo "    and set source image to: $API_IMAGE"
  fi
fi

# ---------- 5. Env vars on littlelove-api ----------

echo "→ setting RUST_LOG on $API_SERVICE_NAME"
railway variables \
  --service "$API_SERVICE_NAME" \
  --set "RUST_LOG=info,littlelove_api=info"

echo "→ wiring DATABASE_URL reference on $API_SERVICE_NAME"
railway variables \
  --service "$API_SERVICE_NAME" \
  --set 'DATABASE_URL=${{ Postgres.DATABASE_URL }}'

# ---------- 6. Railway-managed domain ----------

echo "→ generating Railway domain for $API_SERVICE_NAME (port 7707)"
if ! railway domain --service "$API_SERVICE_NAME" --port 7707 2>&1; then
  echo "  (likely already has a domain — see summary below)"
fi

# ---------- 7. Summary ----------

echo
echo "=========================================="
echo "  Bootstrap complete"
echo "=========================================="
echo
railway status || true
echo
echo "Variables on $API_SERVICE_NAME:"
railway variables --service "$API_SERVICE_NAME" || true
echo
echo "Next steps:"
echo "  1. Add GitHub Actions secrets:"
echo "       gh secret set RAILWAY_TOKEN       # paste from Railway → Settings → Tokens"
echo "       gh secret set RAILWAY_PROJECT_ID  # value: $PROJECT_ID"
echo
echo "  2. Trigger the 'release' workflow with a version (builds + pushes GHCR image)."
echo "  3. Trigger the 'deploy' workflow with that tag."
echo "  4. Verify: curl https://<railway-domain>/health"
echo "  5. Add the custom domain:"
echo "       railway domain api.littlelove.dev --service $API_SERVICE_NAME"
echo "     then add the printed CNAME to Cloudflare as 'DNS only' (gray cloud)."
echo "  6. Update docs/railway.md with the IDs above."
