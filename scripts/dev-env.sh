# scripts/dev-env.sh
# Source this script to set COMPOSE_PROJECT_NAME and port offsets per worktree.
# Usage: source scripts/dev-env.sh

set -u

_workdir_name="$(basename "$PWD")"

# Derive a deterministic 0..99 offset from the worktree directory name.
# sha1 of the name → take first 4 hex chars → modulo 100.
_hash_hex=$(printf '%s' "$_workdir_name" | shasum -a 1 | awk '{print $1}' | cut -c1-4)
_offset=$(( 0x$_hash_hex % 100 ))

# Base ports
_api_base=7707
_pg_base=5432

# Detect collisions with other running Compose projects: if the chosen
# ports are bound, bump by 1 until free (max 5 attempts).
_port_busy() { lsof -i ":$1" >/dev/null 2>&1; }

_api_port=$(( _api_base + _offset ))
_pg_port=$(( _pg_base + _offset ))
for _ in 1 2 3 4 5; do
  if _port_busy "$_api_port" || _port_busy "$_pg_port"; then
    _offset=$(( (_offset + 1) % 100 ))
    _api_port=$(( _api_base + _offset ))
    _pg_port=$(( _pg_base + _offset ))
  else
    break
  fi
done

export COMPOSE_PROJECT_NAME="$_workdir_name"
export API_PORT="$_api_port"
export POSTGRES_PORT="$_pg_port"
export DATABASE_URL="postgres://littlelove:dev@localhost:${_pg_port}/littlelove"

unset _workdir_name _hash_hex _offset _api_base _pg_base _api_port _pg_port _port_busy
