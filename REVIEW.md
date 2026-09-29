# Code review guide

Review instructions for little-love: an iOS-only, end-to-end encrypted
messenger for exactly two partners. Flutter/Dart app in `app/`, Rust (axum +
sqlx + Postgres) server in `server/`, shared primitives in `crypto/`.

Coding standards live in `.claude/rules/dart.md` and `.claude/rules/rust.md`;
project rules in `CLAUDE.md`. Read the one matching each changed file. A
violation of those in new or changed code is a finding; restating them is
not. Each rules file ends with a **Known gaps** list of existing code that
doesn't meet the rules yet: those are not findings unless the change makes
them worse or touches those lines.

Every item in the checklist below comes from a bug that actually shipped or
nearly shipped here. Prioritize these over generic advice.

## Severity

- **Critical**: breaks E2EE or privacy (plaintext, keys, identifiers or
  content reaching the server, logs, crash reports, pushes, or the next
  account on the device); lets one partner act as the other; loses or
  duplicates messages; data loss from a migration; breaks the iOS build or
  App Store submission.
- **High**: a message/status/read-state bug a user will see; a race that
  corrupts state; a server handler missing membership or rate-limit gating;
  a wire change on one side only; a crash on a reachable path.
- **Medium**: resource leak, unbounded growth, missing timeout, a
  non-hermetic or flaky test, a missing test for a changed invariant.
- **Nit**: style drift from the standards docs, stale comments. Report at most
  5 nits, and only in changed lines.

Don't report: formatting that `dart format` / `cargo fmt` would fix, lints
that `flutter analyze` / `clippy -D warnings` would catch (CI enforces them),
pre-existing issues on unchanged lines, or requests for group-chat, Android or
desktop support (out of scope).

## Checklist

### 1. Authorization at the apply layer (E2EE)

Both partners hold the room key, so either one can craft any encrypted body.

- Every body-borne action (delete, edit, reaction, call frame, any new kind)
  checks `target.from == requester` **on every path that applies it**: the
  live router, outbox rehydrate, deferred application inside
  `add`/`reconcile`, and the `MessageDb` projection. A UI that only shows the
  button on your own bubbles is not enforcement.
- The acting identity comes from the authenticated frame/session or room
  membership, never from a field inside the body (e.g. call peer derived from
  membership, not the invite's `from`).
- Server: nothing in a request names who is acting; signatures cover every
  field the server acts on, are domain-separated, and can't be replayed.

### 2. State that must survive the optimistic → server-id reconcile

- Any new per-message state (read, deleted, cancelled, edited, ...) is
  recorded in a set/map and re-applied in `add` / `setAll` / `reconcile`,
  not just flipped on rows that happen to exist.
- Per-row UI state (keys, animations, pop-in) is keyed by
  `clientMsgId ?? id`.
- A late echo can't resurrect a cancelled send.
- Look for a test of the "update arrives before its row" ordering.

### 3. New message kind or frame type

- Every exhaustive `switch` handles it: inbound router, outbox rehydrate,
  `MessageDb`, FTS indexing, chat-info tabs, reply-quote preview, banner,
  chime and unread counting.
- Non-timeline kinds (reaction, delete, edit, call-log) don't bump unread,
  banner or chime.
- The change is mirrored in `server/src/wire.rs` **and**
  `app/lib/wire/frames.dart`, with round-trip tests on both sides. Serde
  ignores unknown fields, so a one-sided rename silently no-ops.
- Id formats match the typed field (`Uuid` vs ULID). CallKit call ids must be
  UUIDs.

### 4. Read state and replay

- Every read path (live, replay on reconnect, resume, cold launch) updates
  both the server (`MarkRead`) and the local marker, and the badge.
- Anything delivered "live only" has a replay/backfill path for a peer that
  was offline.
- Debounced timers re-check their preconditions when they fire.

### 5. Honest UI

- Chime, toast and "sent" fire only after the durable step (outbox enqueue),
  never optimistically.
- Every failure after an optimistic insert ends in `failed` (tap to retry) or
  removes the bubble; nothing can stay "sending" forever.
- A local save and a best-effort partner sync are reported separately.

### 6. Sign-out and device-global state

- Any new persisted store, cache, pref, FTS/index table or keychain item is
  wiped **and awaited** in `app/lib/identity/sign_out.dart`, and its providers
  invalidated. Otherwise the next account on the device inherits it.

### 7. Server handler gating

For every new or changed `RoomClientFrame` arm or REST route:

- `is_member` check on the named room before any work.
- Recipient derived from `partner_account_id`, never client-supplied.
- A **new** frame gets a per-connection rate limit if it does DB work,
  fan-out, push, or a paid external call (TURN). Existing unlimited frames
  (`Send`, `MarkRead`, ...) are a known gap tracked in #25; don't flag them
  on a change that only touches their handler logic.
- Client-supplied sizes capped with a documented constant, and the client
  encoder guarantees it fits (thumbnails once overflowed the body cap).
- Existence not leaked (`UNKNOWN_BLOB`, not forbidden).
- Error codes come from `wire::error_codes`; no internal detail sent.
- New routes are added to both `main.rs` and `tests/common/mod.rs`.

### 8. Atomicity and migrations

- Invariants are backed by a DB constraint plus a transaction, not a
  read-then-write. Locks in canonical order. Irreversible "consume" steps
  last.
- Postgres migrations are schema-only (no `UPDATE`/`INSERT`/`DELETE`/backfill,
  no `DO $$` data checks).
- No edits to an already-applied migration file.
- New FKs state `ON DELETE` and it's compatible with `leave_room` and
  account deletion.

### 9. Privacy in logs, crash reports and pushes

- Rust: identifiers are structured fields (`username = %x`), never `{}`
  interpolated into the message.
- Dart: `reportFault` context is a constant; no content, names, paths or
  raw frames.
- New identifying field names are added to **both** `server/src/scrub.rs`
  and `app/lib/diagnostics/scrub.dart`.
- APNs/VoIP payloads carry no text, names or senders.
- No secrets in `Debug` output.
- No new third-party network requests (fonts, analytics, CDNs).
- Content stays between the partners: no share-sheet, forward, or
  export-to-third-party affordances. Saving received media to your own
  Photos library (Save to Photos, #61) is allowed.

### 10. Async ordering and lifecycle

- For each native→Dart or server→client event: is someone subscribed at the
  moment it fires? PushKit tokens and the first `Rooms` frame were both lost
  this way. Prefer pull or buffered APIs; long-lived listeners must be
  eagerly instantiated.
- Guard flags reset in `finally`; side effects emitted before a teardown that
  can re-enter.
- Every outbox enqueue followed by `drain.kick()`.
- `mounted` / `context.mounted` checked after every `await` in widget code.
- Widgets read live providers, not constructor snapshots or one-time latches.
- Presence-like flags have a heartbeat or expiry.

### 11. Resources

- Dart: `AnimationController`, `OverlayEntry`, `TapGestureRecognizer`,
  subscriptions and timers disposed. Image decodes bounded with
  `cacheWidth`. No sorts/decodes in `build` or per-frame paths. Stable list
  keys.
- Rust: outbound HTTP clients have timeouts; in-memory TTL maps have a
  sweeper; no `std::sync::Mutex` guard held across `.await`;
  `interval_at` when the first tick shouldn't be immediate; `saturating_sub`
  on size/time math; secrets compared in constant time.
- Untrusted ids are validated before being joined into a file path.

### 12. iOS build and platform

- Any `pubspec.yaml` plugin change: was it verified with a real
  `flutter build ios` / device install? `flutter test` doesn't compile the
  iOS plugin graph. Check the minimum iOS target (13) and that it doesn't
  pull GoogleMLKit.
- New native capability → Info.plist purpose string.
- Known iOS traps: `applicationIconBadgeNumber` is a no-op on iOS 18+ (use
  `setBadgeCount`); universal links arrive at `SceneDelegate` under UIScene;
  requesting mic and camera together crashes; `Platform.environment` is empty
  (use `--dart-define`); the sandbox root isn't writable (use `Documents/`).
- Widgets under `MaterialApp.builder` need their own `Material` ancestor and
  `StackFit.expand`.

### 13. Tests

- A changed invariant has a test that would fail without the change, named as
  the invariant (`'applyDelete from a non-author is ignored'`).
- Security-relevant server changes include a negative test (non-member,
  replay, flood).
- Waits are condition-based (`pumpUntil`, bounded timeouts), not fixed
  delays.
- Tests are hermetic: no real home dir, no dev DB. New server DB tests use
  `#[file_serial(db)]`, and a file never mixes it with `#[serial]`.
- The test drives the production flow when the bug is in navigation or
  wiring, not a screen mounted in isolation.

### 14. Docs drift

- If the change makes `CLAUDE.md`, `.claude/rules/*.md`, `server/PUSH.md`,
  `docs/error-monitoring.md` or a code comment untrue, flag it.

## Output

Lead with Critical and High findings. For each: file:line, the concrete
failure scenario (inputs and ordering that trigger it), and the fix. Only
report something as a bug if you can describe how it fails. If nothing
survives verification, say so plainly.
