# LittleLove — Day 1 Design

**Status:** Draft
**Date:** 2026-06-09
**Parent spec:** `2026-06-09-littlelove-design.md` (Phase 1)
**Goal:** A vertical slice that Court and Kaitlyn can use on their laptops this weekend.

## 1. Summary

This is the smallest end-to-end LittleLove that two people can actually chat on. It is **explicitly throwaway** in the places that matter — encryption is symmetric and pre-shared, identity is a config file, persistence doesn't exist. Day 1 exists to prove the wire (Flutter ↔ Axum ↔ Flutter), give Court and Kaitlyn something usable, and de-risk the architecture before we invest in MLS + multi-device + bot host.

Everything not in §3 is deferred to the Phase 1 spec.

## 2. Two-stage milestone

Even within Day 1, we ship in two takes:

- **Day-1a (one evening, ~4 hours):** plain text over WebSocket. Two Flutter desktop apps + one Axum server. No encryption. Proves the wire end-to-end.
- **Day-1b (one evening, ~4 hours):** add libsodium-style symmetric encryption (XChaCha20-Poly1305 with a pre-shared key). Same UX, ciphertext on the wire and in server logs.

Each day-end produces something usable. If Day-1b slips, Day-1a is still messaging.

## 3. In scope

- **Two clients** (one on macOS, one on Windows — Court and Kaitlyn). Flutter desktop, **macOS + Windows targets**. Linux deferred.
- **One server** (Rust + Axum) — runs locally on Court's machine for first usage; deployable to Railway once the wire works.
- **One conversation** between two hardcoded users. No conversation list, no sidebar, no settings, no theme picker.
- **Text only.** No attachments, no voice memo, no images.
- **Hearth palette** hardcoded (the default).
- **In-memory only** — no SQLite, no on-disk store. Restart = empty room. (Persistence arrives in Day 2.)
- **Pure Dart for Day 1.** The `cryptography` package (XChaCha20-Poly1305 + X25519) covers encryption with no native deps. **No `flutter_rust_bridge`, no Rust core in the client yet** — that lands when we introduce MLS in Phase 1.

## 4. Explicitly out of scope

| Feature | Where it lives |
|---|---|
| MLS / E2EE protocol | Phase 1 |
| SQLite + SQLCipher persistence | Day 2 (post-Day-1) |
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
| GitHub Actions CI for the client | Phase 1 (Day 1 builds locally) |

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

### Day-1a (plain text)

JSON over WebSocket text frames:

```json
{ "type": "msg", "from": "court", "to": "kaitlyn", "body": "hey love", "ts": 1717930800 }
```

### Day-1b (encrypted)

Same envelope, but `body` is `{ ciphertext, nonce }` and the inner plaintext is encrypted symmetrically with the pre-shared 32-byte key using XChaCha20-Poly1305:

```json
{ "type": "msg", "from": "court", "to": "kaitlyn",
  "body": { "ciphertext": "<base64>", "nonce": "<base64>" },
  "ts": 1717930800 }
```

The server cannot read `body` in 1b. The `from` / `to` / `ts` fields stay in cleartext for routing.

## 7. Server (`server/`)

- Rust + Axum + `tokio-tungstenite`.
- One process. A single in-memory `HashMap<username, WebSocketSink>`.
- One endpoint: `GET /ws` (WebSocket upgrade).
- One endpoint: `GET /health` (200 OK).
- Behavior: on receiving a `msg` frame from `court`, look up the connection for `kaitlyn` and forward verbatim. If she isn't connected, drop the message (Day 1 has no offline queue).
- No persistence. No database. The whole server is ~150 lines.

Deploy target: **localhost first**. Once Day-1a works locally, we deploy the same binary to Railway (with a `dockerfile` and the saved release/deploy workflow split) and point both clients at the Railway URL.

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
│   └── src/main.rs
├── app/                    # Flutter desktop (Day 1, macOS only)
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart
│       ├── config.dart      # reads ~/.littlelove/config.toml
│       ├── conversation_page.dart
│       ├── ws_client.dart
│       └── crypto.dart      # Day-1b only; XChaCha20-Poly1305 wrapper
├── docs/                   # (already populated)
├── README.md
└── .gitignore
```

## 10. Build & run

### Server

```sh
cd server
cargo run                   # listens on 127.0.0.1:7707
```

### Client — macOS (Court)

```sh
cd app
flutter run -d macos        # uses ~/.littlelove/config.toml
```

Prereq: Xcode command-line tools installed.

### Client — Windows (Kaitlyn)

```powershell
cd app
flutter run -d windows       # uses %USERPROFILE%\.littlelove\config.toml
```

Prereq: Visual Studio 2022 with the "Desktop development with C++" workload, plus Flutter Windows desktop enabled (`flutter config --enable-windows-desktop`). Kaitlyn builds + runs locally on her own machine; she does not receive a pre-built binary from Court.

Until the server is on Railway, both clients point at Court's machine's LAN IP for `server_url` in their respective configs (`ws://192.168.x.x:7707/ws`).

## 11. Testing

- Day 1 testing is **manual two-laptop QA**. Court types, Kaitlyn sees it; reverse direction. Restart each side, confirm graceful reconnect.
- One unit test per non-trivial Dart file is the minimum:
  - `config_test.dart` — parses a TOML config correctly.
  - `crypto_test.dart` (Day-1b) — round-trip encrypt → decrypt with the same key.
- One Rust unit test on the server: `forwards_message_to_recipient_when_both_connected`.

TDD discipline per saved feedback: write the failing test first for each of those three.

## 12. Acceptance criteria

Day 1 is "done" when, on Court's macOS machine and Kaitlyn's Windows machine:

1. Court launches the app, sees an empty conversation.
2. Kaitlyn launches the app on her machine, sees an empty conversation.
3. Court types "hey love" → Kaitlyn sees it within ~500ms.
4. Kaitlyn replies → Court sees it.
5. If Day-1b: server logs show ciphertext, not plaintext.
6. Killing the server, restarting it, killing each client, restarting each client — they reconnect and resume messaging within ~5 seconds.

## 13. What the next slices look like

After Day 1 is working, the natural next slices (one weekend each, roughly):

- **Day 2** — SQLite persistence (no SQLCipher yet). Messages survive restart.
- **Day 3** — Basic auth: real handshake with a per-user keypair, ditch the shared symmetric key, use libsodium box-encryption per recipient. Still not MLS.
- **Day 4** — Introduce the Rust core via `flutter_rust_bridge`. Move encryption and WS transport behind the FFI. The pure-Dart code from Day 1 is thrown away here.
- **Day 5+** — MLS via `openmls` in the Rust core; multiple rooms; QR device pairing.
- **(...)** — character cards, bot host, Windows + Linux, the rest of Phase 1.

This is a sketch, not a commitment. Each slice gets brainstormed and spec'd when we get to it.

## 14. Risks

- **Networking gotchas on a home LAN** — firewalls (macOS *and* Windows Defender), sleep/wake on a Mac, Wi-Fi router config. Windows Defender will prompt on first run of the Axum server if Court hosts on his Windows box; allow on private network. Mitigate by being prepared to deploy the server to Railway early if LAN turns out to be flaky.
- **Windows toolchain setup tax** — Kaitlyn needs Visual Studio Build Tools + "Desktop development with C++" workload (multi-GB download). Plan for an hour of toolchain install before her first `flutter run -d windows`. Once done, it's a one-time cost.
- **Pure-Dart code becoming load-bearing** — be explicit in the README that Day-1 Dart is throwaway, so we don't accidentally lean on it past Day 3.
- **Time pressure to add "just one more thing"** — Day 1 is intentionally tiny. Defer everything that doesn't fit the §3 list, even if it's tempting.
