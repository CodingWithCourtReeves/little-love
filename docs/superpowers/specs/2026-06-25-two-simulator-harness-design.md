# Two-simulator test harness (seeded paired couple) — design

**Date:** 2026-06-25
**Status:** Approved, building

## Goal

One command boots **two iOS simulators**, each signed in as a different partner
of an already-paired couple (`court` + `kaitlyn`), talking to a **local
backend**, so we can test real cross-"device" chat (e.g. message editing
round-trips) without the physical phones (which are on prod). Reproducible and
reset-proof: re-running yields the same working pair every time.

Calling/video and attachments are **not required** (CallKit/VoIP/TURN don't work
on the simulator); text chat + edit/unsend/reactions are the target.

## Hard constraint: no public attack surface

The dev-only seeding capability must be **impossible to reach in production**.
Met by making it a **separate, cargo-feature-gated binary** — not an HTTP route.
The production `littlelove-api` serving binary is unchanged: no new routes, no
new handlers. `scripts/release.sh` never enables the feature, so the seed code
isn't even in the prod artifact. Defense-in-depth: the bin refuses unless
`DATABASE_URL` points at localhost/127.0.0.1.

## Key constraint discovered: no cross-language phrase derivation

Dart and Rust share the **same HKDF chain** (`littlelove.v0.2.{master,signing,
encryption}` salts) but **not** the phrase/seed format:

- Dart client (`bip39.dart`/`keypair.dart`): **12-word** standard BIP39,
  **16-byte** seed.
- Rust `crypto` crate (`identity.rs`): **24-word**, **32-byte**, custom
  no-checksum encoding.

So we cannot derive the client's keys from a phrase in Rust. Instead we
**precompute a fixture once with the real Dart impl** and commit it: two valid
12-word phrases + their derived ed25519/x25519 pubkeys. The seed tool inserts
those known pubkeys (no derivation); the client restores from the same phrases
and derives identical keys, so E2EE/auth line up by construction.

## Components

### 1. Dev fixture — `scripts/dev-couple.json` (committed)

Generated once by a Dart helper using the canonical client derivation. Single
source of truth for both the seed tool (pubkeys) and the harness (phrases):

```json
{
  "court":   { "phrase": "<12 words>", "ed25519_pub": "<b64>", "x25519_pub": "<b64>" },
  "kaitlyn": { "phrase": "<12 words>", "ed25519_pub": "<b64>", "x25519_pub": "<b64>" }
}
```

A Dart test (`test/identity/dev_couple_fixture_test.dart`) re-derives from the
committed phrases and asserts the committed pubkeys still match, so a future
crypto change can't silently break the fixture.

### 2. Server seed tool — `server/src/bin/seed_couple.rs` (feature `dev-seed`)

- Gated `#[cfg(feature = "dev-seed")]`; a `[features] dev-seed = []` in
  `server/Cargo.toml`. Not built by the default/release build.
- Refuses unless `DATABASE_URL` host is `localhost`/`127.0.0.1`.
- Reads `scripts/dev-couple.json`, then, **reusing the existing store functions
  the tests use** (no new logic): upserts the two accounts with the fixture
  pubkeys, pairs them (`set_partner_link`), and creates the couple room
  (`create_room_with_members`). Idempotent — safe to re-run.
- Run by the harness: `cargo run -p littlelove-api --bin seed_couple
  --features dev-seed` with the dev `DATABASE_URL`.

### 3. Client dev auto-provision — `LLOVE_DEV_USERNAME` + `LLOVE_DEV_PHRASE`

In `main()`, alongside the existing `LLOVE_FIXTURES` hook (in
`identity/dev_provision.dart`): if both are baked in **and** no local account
exists yet, headlessly do what `_commit`/`onRestored` do — `phraseToSeed` →
`deriveIdentity` → write keystore `llove.master.<username>` + save `LocalAccount`
(createdAt from a best-effort `getAccountByUsername`, else now). The account
already exists server-side (seed tool), so no signup is needed; the app boots
straight into the inbox and connects.

**These are compile-time `--dart-define`s, read via `String.fromEnvironment`.**
A runtime-env approach (`Platform.environment` + `SIMCTL_CHILD_*`) was tried
first and *failed*: Flutter's `Platform.environment` is **empty on iOS**, so
`simctl launch` env vars never reach Dart (verified — the OS process had the
vars, Dart saw zero keys). Compile-time defines are reliable (same mechanism as
`LLOVE_SERVER`/`LLOVE_FIXTURES`); the cost is **one build per partner** (the
harness builds court, installs, then builds kaitlyn — incremental, so the second
is fast). Inert in production: the defines are empty, nothing is baked in, and it
no-ops the instant a real account already exists.

### 4. iOS ATS — `app/ios/Runner/Info.plist`

Add `NSAppTransportSecurity { NSAllowsLocalNetworking = true }` so the simulator
can reach `http://127.0.0.1:<port>` (cleartext to an IP literal is otherwise
ATS-blocked). This only relaxes localhost/.local/literal-IP networking; it does
**not** weaken security for real domains, so it's safe to commit and ship.

### 5. Harness — `scripts/sim-couple.sh`

```
1. source scripts/dev-env.sh          # API_PORT / POSTGRES_PORT / DATABASE_URL
2. docker compose up -d postgres minio # data deps only (NOT the docker api)
3. cargo run the api locally on 127.0.0.1:$API_PORT with DATABASE_URL +
   R2_ENDPOINT=http://127.0.0.1:9000 (reuse dev-phones.sh's env assembly)
4. cargo run --bin seed_couple --features dev-seed   # create + pair the couple
5. for each of two simulators: flutter build (debug, simulator) with
   --dart-define=LLOVE_SERVER=http://127.0.0.1:$API_PORT +
   --dart-define=LLOVE_DEV_USERNAME=<court|kaitlyn> +
   --dart-define=LLOVE_DEV_PHRASE="<that user's phrase>", then boot, install,
   launch. Default sims: iPhone 17 (court) + iPhone 17 Pro (kaitlyn); overridable
   via COURT_SIM/KAITLYN_SIM env.

### Gotcha: arm64 simulator build (mobile_scanner removed)

The unused `mobile_scanner` dependency pulled in GoogleMLKit, which ships no
arm64 *simulator* slice — forcing an x86_64-only build that won't install on an
Apple-Silicon iOS-26 simulator (Rosetta sims are gone). `mobile_scanner` was
dead code (QR is *generated* via `qr_flutter`; scanning is delegated to the
system camera via universal links — no in-app scanner), so it's removed from
`pubspec.yaml`. The build is now a fat x86_64+arm64 binary that installs on
modern sims.
6. Print the two server/identity bindings + a teardown hint.
```

Two distinct simulator devices = two distinct app containers = two distinct
accounts, no `$HOME` juggling needed (unlike the macOS `demo.sh`).

## Data flow

Seed tool writes accounts+pairing+room to Postgres → each simulator launches,
auto-provisions its local identity from its phrase, connects over WSS to the
local api → server replays the shared room → court edits a message → frame
relays through the local server → kaitlyn's sim applies the edit. Exactly the
prod path, just pointed at localhost with pre-seeded identities.

## Out of scope

- Calling/video (CallKit + PushKit VoIP + TURN — simulator-incompatible).
- Push notifications (APNs needs a real device).
- Attachments need MinIO presigned URLs reachable from the sim; `R2_ENDPOINT=
  http://127.0.0.1:9000` makes them work, but they aren't the target and aren't
  gating.

## Testing / verification

- The fixture self-check test (re-derive → assert pubkeys).
- Manual: run `scripts/sim-couple.sh`, confirm both sims land in the shared
  room, send a message court→kaitlyn, edit it, confirm kaitlyn sees the new text
  + "edited" marker (the actual reason this harness exists).
- `flutter analyze` + `flutter test` stay green; `cargo build` (default, no
  feature) unaffected; `cargo build --features dev-seed` compiles the tool.
