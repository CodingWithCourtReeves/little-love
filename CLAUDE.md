# little-love — project rules

## Database migrations

**Migrations are schema-only. Never put data UPDATE/INSERT/DELETE statements
in a migration file.**

- `ALTER TABLE`, `CREATE INDEX`, `DROP INDEX`, `ADD CONSTRAINT`, etc. — fine.
- `UPDATE … SET …`, `INSERT INTO …`, backfills, data inspection (`DO $$ …
  RAISE EXCEPTION` blocks that read row counts), etc. — not allowed.

If a column needs values populated before a `NOT NULL` flip, either:
1. Add the column `NOT NULL` from the start (only works on empty tables),
   or
2. Land the column nullable in one migration, ship a code-level backfill
   job, then flip `NOT NULL` in a follow-up migration once you've
   confirmed no NULLs remain.

Why: data migrations are hard to reason about, hard to roll back, hard to
test, and entangle schema state with application state. Keep them
separate.

## Dev setup

### Per-worktree isolation

`scripts/dev-env.sh` derives a deterministic 0–99 port offset from the
worktree directory name (sha1 → first 4 hex → mod 100). Each worktree
gets its own `API_PORT` (7707 + offset), `POSTGRES_PORT` (5432 + offset),
and `COMPOSE_PROJECT_NAME`, so multiple worktrees can run their stacks
side by side without colliding. `source scripts/dev-env.sh` to load them.

### Local backend (simulator / desktop)

- `./scripts/dev-up.sh` — `docker compose up` for postgres + minio, writes
  the computed ports to `.dev.env`.
- `./scripts/dev-down.sh` — tear the containers down.

MinIO is the local S3-compatible blob store. The API server signs presigned
URLs but never connects to the blob store itself; point it at MinIO with
`R2_ENDPOINT`.

### On-device testing (physical iPhones)

The phone can't reach your Mac's loopback, so the backend is exposed over
two ngrok **https** tunnels (iOS ATS blocks cleartext to the blob store):

- `./scripts/dev-phones.sh` — brings up postgres + minio, starts the ngrok
  tunnels (API + MinIO) using the project-local `ngrok.yml`, runs the API
  server with `R2_ENDPOINT` pointed at the MinIO tunnel, and prints the
  `LLOVE_SERVER` URL. `./scripts/dev-phones.sh down` stops the tunnels +
  server (leaves docker running).
- `ngrok.yml` is committed with reserved domains for both tunnels. The
  authtoken is **not** in this file — it's read from your global ngrok
  config (`~/Library/Application Support/ngrok/ngrok.yml`) at merge time.

**Always build to a device with `./scripts/ios-deploy.sh --server <url>`,
not raw `flutter run --release`.** Two reasons:

1. `app/ios/Flutter/Release.xcconfig` bakes the **production**
   `LLOVE_SERVER` into `DART_DEFINES`, which overrides `--dart-define` on
   release builds. `ios-deploy.sh` rewrites that line for the build and
   restores it on exit; a raw `flutter run --release` silently ships the
   prod URL and the phone never hits your dev server.
2. `ios-deploy.sh` installs via `devicectl ... install` (upgrade in place),
   which **preserves app data and the keychain identity**. `flutter run` /
   `flutter install` uninstall first, wiping the account identity and
   forcing a re-signup.

The `devicectl` "Failed to load provisioning paramter list … No provider
was found" line is a non-fatal warning — the install still succeeds.
