> **HISTORICAL — superseded (annotated 2026-06-16).** This document predates the
> removal of the AI "familiar" / bring-your-own-model feature. LittleLove is now a
> couples-first, channels-based, fully end-to-end-encrypted messenger with **no AI
> and no familiars**. Any mention below of bots, familiars, character cards, LLMs,
> or cloud/local AI describes a **retired** design and does NOT reflect the current
> product. For current framing see `README.md` and `docs/positioning.md`.

# LittleLove — Day 1 Design

**Status:** Draft
**Date:** 2026-06-09
**Parent spec:** `2026-06-09-littlelove-design.md` (Phase 1)
**Goal:** A vertical slice that Court and Kaitlyn can use on their laptops this weekend.

## 1. Summary

This is the smallest end-to-end LittleLove that two people can actually chat on. It is **explicitly throwaway** in the places that matter — encryption is symmetric and pre-shared, identity is a config file, persistence doesn't exist. Day 1 exists to prove the wire (Flutter ↔ Axum ↔ Flutter), give Court and Kaitlyn something usable, and de-risk the architecture before we invest in MLS + multi-device + bot host.

Everything not in §3 is deferred to the Phase 1 spec.

## 2. Three-stage milestone

We ship Day-1 in three takes. Each is a real release tagged in git and downloadable from GitHub Releases.

- **Day-1a (~4 hours):** plain text over WebSocket. Two Flutter desktop apps + one Axum server. No encryption, no persistence. In-memory routing. Proves the wire end-to-end.
- **Day-1b (~3–4 hours):** add **Postgres persistence + replay-on-connect**. Server stores every message; on connect, a client receives all messages addressed to it newer than its `since` timestamp. Survives server restarts. Kaitlyn can close her laptop overnight and see Court's messages in the morning. No client-side persistence yet (client still replays from server on every relaunch).
- **Day-1c (~3–4 hours):** add **end-to-end symmetric encryption** (XChaCha20-Poly1305 with a pre-shared key). Same UX, ciphertext on the wire and in the server's database.

Each stage produces something usable. If Day-1c slips, Day-1b is still a real, persistent (server-trusted) messenger.

Total: ~10–12 hours over 2–3 evenings.

## 3. In scope

- **Two clients** (one on macOS, one on Windows — Court and Kaitlyn). Flutter desktop, **macOS + Windows targets**. Linux deferred.
- **One server** (Rust + Axum) — runs locally on Court's machine for first usage; deployable to Railway once the wire works.
- **One conversation** between two hardcoded users. No conversation list, no sidebar, no settings, no theme picker.
- **Text only.** No attachments, no voice memo, no images.
- **Hearth palette** hardcoded (the default).
- **Server-side persistence from Day-1b** — managed Postgres on Railway (locally via Docker Compose). Stores every message with a `since`-style replay on connect.
- **No client-side persistence in Day-1** — every relaunch replays from the server. Client-side SQLite is Day-2.
- **Pure Dart for Day 1.** The `cryptography` package (XChaCha20-Poly1305) covers Day-1c encryption with no native deps. **No `flutter_rust_bridge`, no Rust core in the client yet** — that lands when we introduce MLS in Phase 1.

## 4. Explicitly out of scope

| Feature | Where it lives |
|---|---|
| MLS / E2EE protocol | Phase 1 |
| Client-side SQLite (+ SQLCipher) persistence | Day 2 (post-Day-1) |
| QR device pairing | Phase 1 |
| Multi-device per user | Phase 1 |
| Account signup, prekey directory | Phase 1 |
| Server signed-challenge auth | Phase 1 |
| Attachments | Phase 1 |
| Bot host + character cards + AI familiars | Phase 1 |
| Theme picker | Phase 1 |
| Push notifications | Phase 1.5 (mobile) |
| Cross-device history sync | Phase 1.5 |
| Settings screen | Phase 1 |
| Recovery / account loss | Phase 2 |
| Linux desktop | Phase 1 |
| Conversation list, multiple rooms | Phase 1 |
| iOS / Android | Phase 1.5 |

## 5. Identity & "auth"

A config file at a per-OS standard location:

- **macOS:** `~/.littlelove/config.toml`
- **Windows:** `%USERPROFILE%\.littlelove\config.toml`

Same TOML format on both:

```toml
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:7707/ws"

# Day 1b symmetric key (32 bytes, hex-encoded). Pre-shared.
# Court and Kaitlyn use IDENTICAL values here.
shared_key = "<32-byte hex>"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
```

- On launch, app reads the config and opens a WebSocket to `server_url`.
- "Auth" for Day 1 is the username sent in the upgrade headers (`x-llove-user`). No signature, no challenge, no token. The server simply records "who's connected as whom."
- This is the honest "Day 1" identity story. Real challenge-response auth arrives in Phase 1.

## 6. Wire format

### Day-1a (plain text, no replay)

JSON over WebSocket text frames:

```json
{ "type": "msg", "id": "<uuid>", "from": "court", "to": "kaitlyn", "body": "hey love", "ts": 1717930800 }
```

### Day-1b (adds replay-on-connect)

Two new frames:

```json
// client → server, immediately after WSS upgrade
{ "type": "hello", "since": "2026-06-08T00:00:00Z" }

// server → client, replay of stored history
{ "type": "msg", "id": "<uuid>", "from": "court", "to": "kaitlyn", "body": "hey", "ts": 1717930800, "replayed": true }
```

If the client doesn't send a `hello`, the server defaults `since` to "now". If `since` is provided, the server replays every stored message addressed to the connecting user with `ts > since`. Day-1 client (no local persistence) always sends `since = now - 30 days` on each launch.

### Day-1c (adds encryption)

Same envelope, but `body` becomes `{ ciphertext, nonce }`, encrypted symmetrically with the pre-shared 32-byte key using XChaCha20-Poly1305:

```json
{ "type": "msg", "id": "<uuid>", "from": "court", "to": "kaitlyn",
  "body": { "ciphertext": "<base64>", "nonce": "<base64>" },
  "ts": 1717930800 }
```

The server can no longer read `body`; it stores and replays the ciphertext verbatim. `from` / `to` / `ts` / `id` stay in cleartext for routing and replay.

## 7. Server (`server/`)

Rust + Axum + `tokio-tungstenite`. Two endpoints: `GET /ws` (WebSocket upgrade) and `GET /health` (200 OK).

### 7.1 Day-1a behavior

A single in-memory `HashMap<username, WebSocketSink>`. On receiving a `msg` frame from `court`, look up the connection for `kaitlyn` and forward verbatim. If she isn't connected, drop the message. No database. ~150 lines.

### 7.2 Day-1b behavior (Postgres + replay)

Add `sqlx` and a managed Postgres connection (Railway in production, Compose locally). One migration:

```sql
-- 0001_create_messages.sql
CREATE TABLE messages (
  id          uuid        PRIMARY KEY,
  from_user   text        NOT NULL,
  to_user     text        NOT NULL,
  body        text        NOT NULL,             -- plain text in 1b, ciphertext in 1c
  ts          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_to_ts ON messages (to_user, ts);
```

On `msg` receive: `INSERT INTO messages …` and forward to the recipient's open connection (if any). On `hello` receive: `SELECT … WHERE to_user = $1 AND ts > $2 ORDER BY ts` and stream each row as a `msg` frame with `replayed: true`. Total addition: ~30 lines Rust + the migration.

No retention sweeps yet — Day-1 stores forever. Retention policy is a Phase 1 concern.

### 7.3 Day-1c behavior (encryption)

Wire format change only. Server logic unchanged — it stores and replays whatever bytes the client sends. The `body` column now holds ciphertext; server is blind to it.

### 7.4 Deployment

- **Day-1a:** local Docker Compose, then deploy to Railway service `littlelove-api` (Postgres already provisioned but unused).
- **Day-1b:** Railway with `DATABASE_URL` injected from the managed Postgres service. Migration runs at startup via `sqlx migrate run`.
- **Day-1c:** no infra change.
- All slices: `wss://api.littlelove.dev/ws` (CNAME `api.littlelove.dev` → Railway service). `littlelove.dev` apex unused.
- Same Railway project and subdomain carry forward into Phase 1; only the server binary gets replaced when MLS lands.

## 8. Client (`app/`)

- Flutter desktop, **macOS and Windows** for Day 1. Same Dart codebase; no platform-specific Day-1 code paths.
- Single screen: a conversation view styled with the Hearth palette (lifted directly from the mock).
- Sidebar in the mock is hidden in Day 1 — only one conversation exists.
- Theme switcher widget from the mock is hidden in Day 1 — only Hearth, only light.
- Composer at the bottom. Enter to send.
- In-memory `List<Message>` backs the UI. State management: Riverpod (or `setState` if Riverpod feels like overkill at this size).
- WebSocket via the `web_socket_channel` package. Auto-reconnect with simple linear backoff.
- Encryption (Day-1b): `package:cryptography` — `Xchacha20.poly1305Aead()`.

## 9. Repo layout (Day 1)

```
little-love/
├── server/                 # Rust + Axum (Day 1)
│   ├── Cargo.toml
│   ├── Dockerfile
│   ├── migrations/
│   │   └── 0001_create_messages.sql
│   └── src/main.rs
├── app/                    # Flutter desktop (Day 1, macOS + Windows)
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart
│       ├── config.dart      # reads OS-appropriate config path
│       ├── conversation_page.dart
│       ├── ws_client.dart
│       └── crypto.dart      # Day-1b only; XChaCha20-Poly1305 wrapper
├── docker-compose.yml       # local dev stack (api + postgres from Day-1b; minio in Phase 1)
├── scripts/
│   ├── dev-up.sh            # worktree-aware: derives project name + ports
│   ├── dev-down.sh
│   └── dev-env.sh           # sourced helper; computes COMPOSE_PROJECT_NAME + offsets
├── .github/workflows/
│   ├── ci.yml               # build + lint + tests for server and app
│   └── release.yml          # triggered on tag push; builds + publishes binaries
├── docs/                    # (already populated)
├── README.md
└── .gitignore
```

## 10. Local dev & distribution

### 10.1 Local dev stack — Docker Compose, worktree-aware

`docker-compose.yml` defines the full local stack. Day-1 ships just the `api` service; Day-2 adds `postgres`; Phase 1 adds `minio` (for R2 emulation).

Court uses heavy git-worktree development. To avoid port and volume conflicts when multiple worktrees run side-by-side, the dev scripts namespace everything by worktree directory name:

- **`COMPOSE_PROJECT_NAME`** is set to `$(basename "$PWD")`. Containers, networks, and named volumes all become `<worktree>_*`. Postgres data in one worktree never bleeds into another.
- **Port offset** is computed deterministically from the worktree name: `offset = sha1(name) mod 100`. Each Compose service publishes at `base_port + offset`. Worktree A might land on `:7707`, worktree B on `:7752`.
- **`scripts/dev-up.sh`** computes both, writes them to a gitignored `.dev.env`, and runs `docker compose up -d`. Prints the URLs to use.
- **`scripts/dev-down.sh`** runs `docker compose down`.

```sh
# any worktree
./scripts/dev-up.sh
# → starts api on http://127.0.0.1:<offset_port>
flutter run -d macos     # or `flutter run -d windows`
./scripts/dev-down.sh
```

### 10.2 Distribution — GitHub Releases on tag push

Court and Kaitlyn install the app from **pre-built binaries published to GitHub Releases**, not by running `flutter run` themselves. This removes Kaitlyn's biggest friction (the Windows toolchain install).

- `.github/workflows/release.yml` triggers on tag push matching `v*`.
- Three parallel jobs:
  1. **`server`** — build container, push to `ghcr.io/codingwithcourtreeves/littlelove-api:<tag>`, deploy to Railway.
  2. **`app-macos`** — `macos-latest` runner; `flutter build macos`; package as `.dmg`; upload to release.
  3. **`app-windows`** — `windows-latest` runner; `flutter build windows`; package as `.msi`; upload to release.
- All three artifacts attach to the GitHub Release page.
- Versioning follows semver from the tag: `v0.1.0-day1a`, `v0.1.0-day1b`, `v0.2.0`, etc.

**No code signing in Phase 1.** First-launch warnings ("unidentified developer" on macOS, SmartScreen on Windows) are expected and will be documented in the release notes. Apple Developer + Windows Authenticode certs come if/when the product goes public.

### 10.3 Court & Kaitlyn's install flow

1. Court pushes a tag (`git tag v0.1.0-day1b && git push --tags`).
2. CI publishes the release with `LittleLove-0.1.0-day1b.dmg` and `LittleLove-0.1.0-day1b.msi`.
3. Court downloads the `.dmg`, drags to `/Applications`. First launch: right-click → Open → "Open anyway."
4. Kaitlyn downloads the `.msi`, double-clicks. First launch: SmartScreen → "More info" → "Run anyway."
5. Both place their `config.toml` at the OS-appropriate path (§5).
6. They open the app; it connects to `wss://api.littlelove.dev/ws` (configured in the Day-1b config).

### 10.4 Server URL across the slices

- **Day-1a (local LAN):** server runs on Court's machine via `./scripts/dev-up.sh`. Clients point at `ws://192.168.x.x:<port>/ws`.
- **Day-1b (deployed):** server runs on Railway. Clients point at `wss://api.littlelove.dev/ws`. Same `Dockerfile`, same binary, just `docker compose up` → Railway deploy.

### 10.5 Developer prereqs (Court only)

- Docker Desktop (macOS) or Docker Engine + Compose.
- Rust toolchain (`rustup`).
- Flutter SDK + Xcode CLT (macOS) for client iteration.
- A GitHub Personal Access Token with `write:packages` for local `release.yml` testing — optional.

**Kaitlyn needs none of this.** She installs the `.msi` and runs the app.

## 11. Testing

Three layers:

1. **Unit tests** — TDD-first per saved feedback. Minimum set:
   - `config_test.dart` — parses a TOML config correctly.
   - `crypto_test.dart` (Day-1c) — round-trip encrypt → decrypt with the same key.
   - `server::forwards_message_to_recipient_when_both_connected` (Rust, 1a).
   - `server::stores_and_replays_history_for_disconnected_recipient` (Rust, 1b).

2. **Integration tests against the full stack** — run against the Docker Compose stack started by `./scripts/dev-up.sh`. A small `tests/integration/` harness:
   - Brings up the stack (or uses the existing one if already running).
   - Spawns two fake clients (Rust test harness using `tokio-tungstenite`).
   - Asserts message round-trip: client A → server → client B with the right `from`/`to`/`body`.
   - Tears down (or leaves running if invoked with `--reuse`).
   - Runs in CI as part of `ci.yml`.

3. **Manual two-laptop QA** — Court types on macOS, Kaitlyn sees it on Windows. Reverse direction. Kill each side, confirm graceful reconnect within 5s.

## 12. Acceptance criteria

Day 1 is "done" when, on Court's macOS machine and Kaitlyn's Windows machine:

1. Court launches the app, sees the last ~30 days of conversation history.
2. Kaitlyn launches the app on her machine, sees the same history.
3. Court types "hey love" → Kaitlyn sees it within ~500ms.
4. Kaitlyn replies → Court sees it.
5. **Persistence (1b):** Court sends a message while Kaitlyn's laptop is closed; Kaitlyn opens her laptop hours later and immediately sees Court's message at the top of the unread set.
6. **Persistence (1b):** restarting the Railway server does not lose any messages.
7. **Encryption (1c):** the Railway Postgres console shows ciphertext in the `body` column, not plaintext.
8. Killing the server, restarting it, killing each client, restarting each client — they reconnect and resume messaging within ~5 seconds.

## 13. What the next slices look like

After Day 1 is working, the natural next slices (one weekend each, roughly):

- **Day 2** — Client-side SQLite persistence. Client no longer replays from server on every launch; it tracks its own `last_seen_id` locally and asks the server only for what's new.
- **Day 3** — Basic auth: real handshake with a per-user keypair, ditch the shared symmetric key, use libsodium box-encryption per recipient. Still not MLS.
- **Day 4** — Introduce the Rust core via `flutter_rust_bridge`. Move encryption and WS transport behind the FFI. The pure-Dart code from Day 1 is thrown away here.
- **Day 5+** — MLS via `openmls` in the Rust core; multiple rooms; QR device pairing.
- **(...)** — character cards, bot host, Windows + Linux, the rest of Phase 1.

This is a sketch, not a commitment. Each slice gets brainstormed and spec'd when we get to it.

## 14. Risks

- **Networking gotchas on a home LAN** — firewalls (macOS *and* Windows Defender), sleep/wake on a Mac, Wi-Fi router config. Windows Defender will prompt on first run of the Axum server if Court hosts on his Windows box; allow on private network. Mitigate by being prepared to deploy the server to Railway early if LAN turns out to be flaky.
- **First-launch unsigned-binary warnings** — Court (right-click → Open on macOS) and Kaitlyn (SmartScreen → Run anyway on Windows) will see warnings on first launch of each new release. Documented in release notes. Real code signing is deferred to public-launch readiness.
- **Worktree dev-script edge cases** — port-offset hashing could collide if two worktrees happen to have names that hash to the same offset (1-in-100 odds per pair). `dev-up.sh` detects collisions against currently-running Compose projects and bumps if needed.
- **Pure-Dart code becoming load-bearing** — be explicit in the README that Day-1 Dart is throwaway, so we don't accidentally lean on it past Day 3.
- **Time pressure to add "just one more thing"** — Day 1 is intentionally tiny. Defer everything that doesn't fit the §3 list, even if it's tempting.
