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

# ---------- 2. Confirm an existing project link ----------
#
# Earlier versions of this script hardcoded a project ID from a one-off
# MCP create_project response. That ID turned out to be stale (the MCP
# layer reported a UUID that didn't actually land in this workspace).
# Rely on the user's existing `railway link` instead — they'll run
# `railway link` interactively once, then this script is repeatable.

LINKED_PROJECT_NAME="$(railway status --json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name",""))' \
  2>/dev/null || true)"

if [[ -z "$LINKED_PROJECT_NAME" ]]; then
  echo "✗ no Railway project is linked in this directory." >&2
  echo "  Run: railway link" >&2
  echo "  Select workspace → littlelove → production, then re-run this script." >&2
  exit 1
fi

if [[ "$LINKED_PROJECT_NAME" != "$PROJECT_NAME" ]]; then
  echo "⚠ linked project is \"$LINKED_PROJECT_NAME\", expected \"$PROJECT_NAME\"." >&2
  echo "  If that's intentional, set PROJECT_NAME at the top of this script." >&2
  echo "  Otherwise: railway link  (and pick littlelove)" >&2
  exit 1
fi

echo "→ linked to project $LINKED_PROJECT_NAME"

# ---------- 3. Postgres plugin ----------

if railway service Postgres >/dev/null 2>&1; then
  echo "→ Postgres already exists, skipping"
else
  echo "→ adding Postgres plugin"
  # `</dev/null` keeps the CLI from dropping into its interactive prompt loop
  # after the database is added.
  railway add --database postgres </dev/null
fi

# ---------- 4. littlelove-api service ----------

API_IMAGE="ghcr.io/codingwithcourtreeves/littlelove-api:latest"
if railway service "$API_SERVICE_NAME" >/dev/null 2>&1; then
  echo "→ $API_SERVICE_NAME already exists, skipping create"
else
  echo "→ creating $API_SERVICE_NAME service from $API_IMAGE"
  # Pre-supply --variables so the CLI's post-create "now add env vars"
  # interactive loop sees that everything is set and exits cleanly.
  # `</dev/null` is the belt-and-suspenders: closes stdin so any remaining
  # prompts can't block.
  railway add \
    --service "$API_SERVICE_NAME" \
    --image "$API_IMAGE" \
    --variables "RUST_LOG=info,littlelove_api=info" \
    --variables 'DATABASE_URL=${{ Postgres.DATABASE_URL }}' \
    </dev/null
fi

# ---------- 5. Ensure env vars on littlelove-api ----------
#
# If the service already existed before this run, --variables on `add` was
# skipped — set them explicitly. `railway variables --set` is idempotent
# and prints a no-op message if the value is already correct.

echo "→ ensuring RUST_LOG on $API_SERVICE_NAME"
railway variables \
  --service "$API_SERVICE_NAME" \
  --set "RUST_LOG=info,littlelove_api=info"

echo "→ ensuring DATABASE_URL reference on $API_SERVICE_NAME"
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
