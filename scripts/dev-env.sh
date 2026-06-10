# scripts/dev-env.sh
# Source this script to set COMPOSE_PROJECT_NAME and port offsets per worktree.
# Usage: source scripts/dev-env.sh

set -u

_workdir_name="$(basename "$PWD")"

# Derive a deterministic 0..99 offset from the worktree directory name.
# sha1 of the name → take first 4 hex chars → modulo 100.
# (1-in-100 collisions across worktrees are handled by renaming the dir.
#  An earlier version tried to detect bind collisions with lsof and bump
#  the offset, but that re-sourced after dev-up wrongly bumps past the
#  project's own running containers.)
_hash_hex=$(printf '%s' "$_workdir_name" | shasum -a 1 | awk '{print $1}' | cut -c1-4)
_offset=$(( 0x$_hash_hex % 100 ))

_api_port=$(( 7707 + _offset ))
_pg_port=$(( 5432 + _offset ))

# docker compose rejects project names containing uppercase letters
# ("must consist only of lowercase alphanumeric characters, hyphens, and
# underscores"). The port offset is still derived from the case-sensitive
# basename above, so two worktrees that differ only by case still get
# different ports.
_compose_name="$(printf '%s' "$_workdir_name" | tr '[:upper:]' '[:lower:]')"

export COMPOSE_PROJECT_NAME="$_compose_name"
export API_PORT="$_api_port"
export POSTGRES_PORT="$_pg_port"
export DATABASE_URL="postgres://littlelove:dev@localhost:${_pg_port}/littlelove"

unset _workdir_name _hash_hex _offset _api_port _pg_port _compose_name
