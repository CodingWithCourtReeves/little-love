---
paths:
  - "server/**/*.rs"
  - "server/**/*.sql"
  - "server/Cargo.toml"
  - "crypto/**"
  - "Cargo.toml"
---

# Rust coding standards (`server/`, `crypto/`)

These describe how the server is already written. Match them in new code.
Where the codebase is inconsistent, the rule below says which side to follow;
do not "fix" the other side in an unrelated change. Rules the existing code
doesn't fully follow yet are listed under "Known gaps" at the end: apply them
to new code, and don't flag the existing gaps in review. The migration rule and
E2EE rules in the root `CLAUDE.md` apply and are not repeated here.

Toolchain: edition 2021, Rust 1.88 (workspace `rust-version`, CI and the
Dockerfile all pin it). No `unsafe`.

## Gate before you call it done

The CI `rust` job runs these from the repo root (see `.github/workflows/ci.yml`):

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings   # every warning fails
cargo build --workspace --all-targets
cargo test --workspace
```

**`cargo test` truncates every table** (`tests/common/mod.rs::fresh_store`)
in whatever `DATABASE_URL` points at, and `scripts/dev-env.sh` *exports* it
pointing at the dev database. Run tests in a subshell so the dev URL never
leaks into your shell (a later bare `cargo test` would wipe the dev DB):

```sh
( source scripts/dev-env.sh
  export DATABASE_URL="postgres://littlelove:dev@localhost:${POSTGRES_PORT}/littlelove_test"
  cargo test --workspace )
```

(Create `littlelove_test` once with `createdb` / `CREATE DATABASE`.) If your
shell has already sourced `dev-env.sh`, don't run a bare `cargo test` in it.

## Layout

- Workspace members: `crypto` (primitives: aead, ecdh, identity, invite, sig)
  and `server` (`littlelove-api`, lib + bin).
- One domain per module in `server/src/` (`rooms.rs`, `invites.rs`,
  `accounts.rs`, `push.rs`, ...), with a `//!` module doc saying what it owns
  and any invariant. New modules get a `//!` doc.
- `ws.rs` holds the socket loop and frame handlers; `wire.rs` holds every
  serde frame and `error_codes`. Keep SQL out of `ws.rs`: put queries in the
  owning domain module as `pub async fn f(pool: &PgPool, ...)`.
- Routes are declared in `main.rs`. **The test router in
  `tests/common/mod.rs` duplicates them by hand; add new routes there too.**
- Workspace dependencies: use `foo.workspace = true` when the crate is in
  `[workspace.dependencies]`; don't re-pin versions in `server/Cargo.toml`.
- Dev-only code sits behind a cargo feature (`dev-seed`) with
  `required-features`, a localhost-only guard, and no HTTP route. Never
  enable it in a release build.

## Wire protocol (`wire.rs`)

- Frames are `#[serde(tag = "kind")]` enums with PascalCase variants and
  snake_case fields. No field may be named `kind` (it's the tag).
- Optional fields: `#[serde(default, skip_serializing_if = "Option::is_none")]`.
  Flags: `skip_serializing_if = "std::ops::Not::not"`. New fields on existing
  frames need `#[serde(default)]` for old clients.
- Serde ignores unknown fields, so a shape mismatch no-ops silently. Every
  frame change gets a round-trip unit test in `wire.rs` **and** the matching
  Dart change in `app/lib/wire/frames.dart`.
- Id formats must match the typed field: a `Uuid` field rejects a ULID and
  the whole frame is dropped with only a log line.
- DB row types stay separate from wire types; convert with `into_wire()`.
- Every error code sent to a client is a constant in `wire::error_codes`.
  Don't add new string literals (`"Internal"` and `"BadName"` are existing
  literals; move them into the module when you touch them). Don't reuse a code
  for an unrelated failure.

## WebSocket handlers

- A new `RoomClientFrame` arm dispatches to `handle_<frame>(&state, &me, ..., &tx).await`
  returning `()`, and replies by pushing frames onto `tx`.
- Every handler that names a room checks `is_member(pool, room_id, me.id)`
  first. The partner is always resolved from `accounts.partner_account_id`,
  never from a client-supplied target. Identity comes from the authenticated
  `me`, never from a field in the frame.
- New frames that do DB work, fan out, push, or call a paid API get a rate
  limit: a per-connection `WindowRateLimiter` local in `handle_socket`
  (sequential loop, no locking), replying `RATE_LIMITED` and dropping the
  frame (typing drops silently). Don't tear the connection down. Which
  frames are limited today: see Known gaps.
- Cap every client-supplied size with a documented `const` (`MAX_BODY_BYTES`,
  `MAX_SEND_RECIPIENTS`, ...) and enforce it before touching the DB.
- Don't leak existence: a non-member asking for a blob gets `UNKNOWN_BLOB`,
  not "forbidden". Auth failures all close with the same 4001.
- The server never sees plaintext. Bodies, profile envelopes, SDP and ICE are
  opaque; never persist SDP, never put content, names or senders in APNs or
  VoIP payloads (only an opaque `room_id`).
- `let _ = tx.send(...)` (ignoring a closed channel) is the accepted pattern.

## Errors

- `anyhow` at the edges (`main`, startup, infra clients, the seed tool).
- `sqlx::Result<T>` from query functions.
- `thiserror` enums for domain outcomes callers branch on (`PairError`,
  `CreateRoomError`), with `#[error(transparent)]` + `#[from]` for wrapped
  sqlx errors.
- In WS handlers the shape is a `match` with `Ok(Some)`, `Ok(None)` →
  specific error code, `Err(e)` → log + `send_error(tx, "Internal", "")` +
  `return` (the literal should become `error_codes::INTERNAL`).
- The error message sent to a client is empty or a short constant string
  (`"store unavailable"`, `"too many recipients"`, `"name too long"`). Never
  send error text (`e.to_string()`), ids, usernames or any request data.
- REST handlers return `(StatusCode, "plain text").into_response()`.
- `unwrap`/`expect` in production code only for true invariants: static
  regexes, `Mutex::lock()`, conversions of constants. Everything else
  handles the error. Tests may unwrap freely.
- Optional subsystems (R2, APNs, TURN, Sentry) degrade to `None` with a
  `warn!` and keep the server up.
- Use `saturating_sub` / checked arithmetic on anything derived from sizes or
  timestamps.

## Database

- Runtime-checked `sqlx::query(...).bind(...)` / `query_as::<_, (tuple)>`,
  decoded into a named tuple alias (`type MessageDbRow = (...)`) and mapped by
  hand. No `query!` macros (no offline data is kept). Values are always
  bound; `format!` into SQL only with constant fragments.
- Transactions: `let mut tx = pool.begin().await?; ... .execute(&mut *tx) ...; tx.commit().await?`.
- Invariants are enforced by the database (UNIQUE / partial index / CHECK), not
  only by a read-then-write. Races use `SELECT ... FOR UPDATE` in canonical
  lock order (by id). Irreversible "consume" steps go last.
- Idempotency via `ON CONFLICT ... DO NOTHING/UPDATE` and `WHERE ... IS NULL`.
- Detect unique violations by SQLSTATE `23505`.

### Migrations

- Schema-only (see `CLAUDE.md`). File name `NNNN_snake_description.sql`,
  leading `--` comment explaining why.
- **Never edit a migration that has been applied**; sqlx checksums it. Add a
  new one.
- Every new FK states its `ON DELETE` behaviour, checked against the existing
  delete paths (`leave_room`, account deletion).
- New migrations get a schema test (`tests/migration_00NN_schema.rs`)
  asserting against `information_schema` / `pg_indexes`
  (`accounts_schema.rs` is the model: it already uses `#[file_serial(db)]`;
  the `migration_00NN_schema.rs` files still use `#[serial]`, see Known gaps).

## Logging and observability

- `tracing` macros. `error!` means a real fault (it becomes a Bugsink event);
  `warn!` for handled failures and rate-limit hits; `info!` for lifecycle.
- **Identifiers go in structured fields, never interpolated**:
  `warn!(username = %me.username, room_id = %room_id, "typing rate limit hit")`,
  not `warn!("... {}", me.username)`. Key-based redaction in `scrub.rs` only
  catches fields.
- Never log message content, ciphertext, keys, tokens or push payloads.
- New identifying field names go into `SENSITIVE_KEYS` in `scrub.rs` **and**
  `_sensitiveKeys` in `app/lib/diagnostics/scrub.dart`.
- Structs holding secrets must not derive a `Debug` that prints them (the
  config structs currently do; don't `{:?}` them, and redact when you touch
  them).
- The Sentry guard is bound to a named variable, never `let _`.

## Concurrency and resources

- Shared state is behind `Arc` in `AppState` (cheap to clone). Per-connection
  state stays local to `handle_socket`.
- Never hold a `std::sync::Mutex` guard across `.await`.
- Every outbound HTTP client has request and connect timeouts.
- Every in-memory TTL map has a sweeper task.
- A background job that could be started again while a previous run is
  still going must guard against overlapping itself (no example in the
  server today; an `AtomicBool` swap is the simple option).
- `tokio::time::interval` ticks immediately; use `interval_at(now + d)` when
  the first tick should wait.
- Compare secrets in constant time.
- Fire-and-forget `tokio::spawn` is fine for side effects (APNs fan-out) that
  must not block the sender's ack.

## Config

- All env vars are read in `config.rs::ServerConfig::from_env`, grouping each
  subsystem into an `Option<XConfig>` that is `None` if any required var is
  missing. Local stand-ins are enabled by an override var (`R2_ENDPOINT`,
  `TURN_ICE_OVERRIDE`).

## Comments

- `//!` module docs; dense `///` docs on functions and constants that explain
  **why** (constants carry their rationale). Cite the spec section
  (`spec §8.2`) and use intra-doc links.
- Mark known limitations `KNOWN GAP:` with what's missing.
- Keep comments true: when you change behaviour, fix the doc and any comment
  that names a type you renamed or removed.

## Tests

- Pure unit tests in-module under `#[cfg(test)] mod tests { use super::*; }`.
- Integration tests in `server/tests/<feature>_ws.rs` / `<feature>_store.rs`,
  starting with `mod common;`. They spin up the real router on
  `127.0.0.1:0` and use `handshake_as`, `drain_rooms`, `next_frame` (10s
  timeout, skips ping/pong/presence) and the shared seed helpers. Put a
  helper used by more than one file in `common`, not a copy per file.
- **Every test that touches the database must be serialized**, because
  `fresh_store()` truncates shared tables. New DB tests use
  `#[file_serial(db)]`: it's a file lock, so it also holds under
  `cargo-nextest` (one process per test, where `#[serial]` does nothing) and
  across two concurrent `cargo test` runs on the same DB. Don't mix
  `serial` and `file_serial` in one file; they are separate locks.
- **Until the `#[serial]` files in Known gaps are migrated, only plain
  `cargo test` is safe**: don't run the suite under `cargo-nextest` or run two
  `cargo test` processes against the same DB, or truncations race.
  Env-mutating tests use `#[serial]` and restore the env.
- Prove absence with a bounded timeout, not by asserting order.
- Race tests: `tokio::spawn` + `join_all`.
- Fake external services with a trait impl (`PushSender` → mpsc).
- Tests needing external services are `#[ignore = "requires ..."]`.
- Names are behaviour sentences:
  `typing_for_non_member_room_is_ignored`,
  `handshake_nonce_is_single_use_per_connection`.
- Security-relevant handlers get a negative test: non-member, wrong partner,
  replayed signature, over-limit flood.

## Known gaps

Existing code that doesn't meet the rules above yet. Apply the rules to new
and changed code; don't report these as findings on lines a change doesn't
touch.

- **Rate limiting**: every `RoomClientFrame` except `Typing`,
  `RequestUpload`, `CallTurnRequest` and `CallInvite` has no limiter.
  `ConsumeInvite` is the most notable (unthrottled invite attempts).
  Tracked in #25.
- **Test serialization**: these DB test files use `#[serial_test::serial]`
  instead of `#[file_serial(db)]`: `partner_race.rs`, `room_mutations.rs`,
  `profiles_store.rs`, `push_tokens_store.rs`, `read_receipts_store.rs`,
  `store_per_recipient.rs`, `partner_helpers.rs`, `rooms_detail.rs`,
  `invite_preview_members.rs`, `attachments_store.rs`, and the
  `migration_00NN_schema.rs` files.
- **Migration schema tests**: only 0006, 0010, 0011 and 0012 have one.
- **Error codes**: `"Internal"` and `"BadName"` are string literals in
  `ws.rs`, not `error_codes` constants.
- **Logging**: some `ws.rs` lines interpolate room and call ids into the
  message instead of using fields.
- **Secrets in `Debug`**: the config structs in `config.rs` derive `Debug`.
- **SQL in `ws.rs`**: one inline `INSERT` in a handler.
- **Dependencies**: `server/Cargo.toml` re-pins some crates that are in
  `[workspace.dependencies]`.
