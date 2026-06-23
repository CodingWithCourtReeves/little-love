#!/usr/bin/env bash
# scripts/release.sh — cut a release locally, with no GitHub Actions minutes.
#
# Replaces the old release.yml. Does what that workflow did, from your Mac:
#   1. tag the current commit (vX.Y.Z) and push it
#   2. build + push the linux/amd64 server image to Docker Hub (Railway runs amd64)
#   3. redeploy prod on Railway (service is pinned to :latest)
#
# iOS distribution is intentionally NOT here — that stays manual (Xcode /
# scripts/ios-deploy.sh).
#
# Usage:
#   ./scripts/release.sh 0.4.0          # the v prefix is added automatically
#
# One-time prerequisites:
#   - Docker Desktop running (provides buildx + linux/amd64 emulation).
#   - Logged into Docker Hub with an access token that has write access, e.g.:
#       echo "$DOCKERHUB_TOKEN" | docker login -u codingwithcourt --password-stdin
#   - Railway CLI linked to the prod service (this repo dir already is):
#       railway link --project <id> --service littlelove-api --environment production
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>  (e.g. 0.4.0)}"
TAG="v${VERSION}"
IMAGE="docker.io/codingwithcourt/littlelove-api"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Refuse to ship uncommitted code; warn (don't block) if not on main.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ working tree is dirty — commit or stash before releasing" >&2
  exit 1
fi
branch="$(git branch --show-current)"
[[ "$branch" == "main" ]] || echo "⚠ releasing from '$branch', not main"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "✗ tag $TAG already exists; pick a different version" >&2
  exit 1
fi

echo "→ 1/3 tag $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "→ 2/3 build + push $IMAGE ($TAG, latest) for linux/amd64"
docker buildx build --platform linux/amd64 \
  --file server/Dockerfile \
  --tag "${IMAGE}:${TAG}" --tag "${IMAGE}:latest" \
  --push .

echo "→ 3/3 redeploy prod"
railway redeploy --service littlelove-api --yes

echo "✓ released $TAG and redeployed prod (https://api.littlelove.dev/health)"
