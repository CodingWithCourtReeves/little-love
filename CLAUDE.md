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

**Caveat:** only `API_PORT`/`POSTGRES_PORT`/`COMPOSE_PROJECT_NAME` are offset.
MinIO's ports (9000/9001) and the reserved ngrok domains are **fixed**, so only
one worktree's blob-store stack / tunnels can run at a time. A second
`dev-up`/`dev-phones` fails with "port is already allocated"; free it by
stopping the other worktree's MinIO (`docker stop
<other-COMPOSE_PROJECT_NAME>-minio-1` — reversible, no data loss), not by
tearing it down.

### Local backend (simulator / desktop)

- `./scripts/dev-up.sh` — `docker compose up` for postgres + minio, writes
  the computed ports to `.dev.env`.
- `./scripts/dev-down.sh` — tear the containers down. Note it runs plain
  `docker compose down` (no `-v`, and it omits the minio compose file), so
  it leaves named volumes + the minio container behind. To fully clean a
  **retired** worktree's stack before removing it:
  `docker compose -f docker-compose.yml -f docker-compose.minio.yml down -v
  --remove-orphans`, then `docker image rm <COMPOSE_PROJECT_NAME>-api`.

MinIO is the local S3-compatible blob store. The API server signs presigned
URLs but never connects to the blob store itself; point it at MinIO with
`R2_ENDPOINT`.

### Two-simulator testing (no physical phones)

`./scripts/sim-couple.sh` boots two simulators as the seeded, already-paired
couple (`court` + `kaitlyn`) against the local backend — for two-sided testing
(edit, unsend, reactions) without the phones. Defaults to iPhone 17 (court) +
iPhone 17 Pro (kaitlyn); override with `COURT_SIM`/`KAITLYN_SIM`.

- It's **bring-up**, not the iteration loop — run it once per session. For UI
  work, attach `flutter run -d "<sim>"` per sim for hot reload; the seeded
  identity persists per simulator container, so no re-provision. `sim-couple.sh
  down` stops the local api (leaves docker + sims up).
- The seed tool (`server/src/bin/seed_couple.rs`) is **dev-only, gated behind
  the `dev-seed` cargo feature** — not in the default/release build, no HTTP
  route, localhost-only guard. Never enable it in prod.

**iOS gotchas this harness hit (save yourself the debugging):**

- **`Platform.environment` is empty on iOS.** Runtime env passed to `xcrun
  simctl launch` (`SIMCTL_CHILD_*`) never reaches Dart, so dev config must be
  baked with `--dart-define` (read via `String.fromEnvironment`). That's why the
  harness builds once per partner.
- **No MLKit-based plugins for simulator builds.** GoogleMLKit (pulled in by e.g.
  `mobile_scanner`) ships no arm64 *simulator* slice, forcing an x86_64-only
  binary that won't install on an Apple-Silicon iOS-26 simulator (Rosetta sims
  are gone). The build fails at install with "no matching arch".
- **CoreSimulator contention:** don't run the self-hosted CI iOS build and a
  local sim build at the same time — it deadlocks the simulator subsystem
  (`simctl boot`/`list` hang indefinitely). The reliable fix is a reboot.

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
was found" line is a non-fatal warning — the install still succeeds. Same
for transient "Connection reset by peer" / `installcoordination_proxy`
errors that `ios-deploy.sh` retries through: trust the final "App
installed" line. An **unchanged `databaseUUID`** across installs confirms
app data + keychain were preserved (no forced re-signup).

A green `flutter test` / `flutter analyze` does **not** prove an iOS build
works: the host VM never compiles federated plugin implementations (e.g.
`record_linux`), but the iOS kernel snapshot does, so a newly-added plugin can
break `flutter build ios` while tests pass. Build to a device before claiming a
plugin works; a stale transitive federated package is pinnable via
`dependency_overrides` (iOS-safe when only the `*_darwin` impl actually runs).

#### Target devices

Always deploy on-device tests to **both** physical phones, never to
Kaitlyn's:

- **Court's iPhone 17 Pro Max** — `0DC6E4DC-B58D-509A-A5B8-FD316A255D89`
- **iPhone 13 Pro Max** — `F031FD6D-9E3D-5005-918D-BB860CE37C26`
- Kaitlyn's iPhone 16 Pro Max — do **not** install here.

Pass `--device <udid>` to target each. The phones are network-paired, so
use `xcrun devicectl list devices` (not `flutter devices`) to confirm
UDIDs. Build them **one at a time**: `ios-deploy.sh` rewrites the shared
`app/ios/Flutter/Release.xcconfig` for the duration of a build, so two
release builds in parallel clobber each other.

## E2EE message semantics

**Authorize body-borne actions at the apply layer, not just in the UX.**
Both partners share the room key, so either side can craft a valid
encrypted frame — an unsend (`kind:"delete"`), a reaction, a future edit —
naming *any* message id. The receiving store must enforce the real
invariant (e.g. only a message's author may unsend it; `applyDelete` takes
the requester and drops a delete whose target it didn't author). A UX that
only exposes "Delete" on your own bubbles is not enforcement.

**Per-message status must survive the optimistic→server-id reconcile.** A
read receipt (or any status update) can arrive *before* the self-copy echo
that swaps an optimistic `clientMsgId` row for its authoritative server id
— routinely so for a link-preview send, which is delayed by the sender's
Open Graph fetch. Record such state in a set (see `_read` / `_deleted` /
`_cancelled` in `MessageStore`) and re-apply it in `add`/`reconcile`; never
just flip rows that happen to be present, or the update is lost for good.
