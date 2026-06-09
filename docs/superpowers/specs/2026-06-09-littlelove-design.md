# LittleLove — Phase 1 Design

**Status:** Draft, awaiting review
**Date:** 2026-06-09
**Author:** Court Reeves (with Claude)

## 1. Summary

LittleLove is a private, end-to-end encrypted messenger **for couples**. Its distinguishing feature is the ability to bring along an AI "familiar" — a self-hosted local AI model that participates in conversations as a real cryptographic member of the room. Users run the AI on their own hardware (Ollama on a home box) so plaintext never leaves devices the user controls.

LittleLove is positioned for couples. Multi-party rooms (e.g., a couple plus an AI familiar, or a couple plus one close third person) are a capability we inherit from MLS, not the marketed use case. The product voice, defaults, and onboarding flow all assume "two people in love" — group-chat affordances exist because the protocol gives them to us, not because we're chasing the family-chat market.

The full product voice — what we claim, how we defend it, and what we deliberately are NOT — lives in `docs/positioning.md`. Implementation tasks that touch user-facing copy should defer to that document.

Phase 1 is **desktop-first** (macOS / Windows / Linux) and ships a working private-beta product between two users (the author and his wife) plus a bot familiar running on a Windows home box. Mobile is deferred to Phase 1.5.

Rough effort: ~2–3 months full-time, ~4–5 months calendar at side-project pace.

## 2. Goals & Non-Goals

### Goals

- True end-to-end encryption — server cannot read messages.
- 1:1 couples rooms as the default; multi-party rooms (couple + AI familiar, or couple + one close third person) supported by the same MLS protocol (RFC 9420) without any special-casing.
- AI participants as first-class cryptographic members; **local-model only**.
- Cross-device usage via QR pairing (e.g., a user's laptop + a user's desktop).
- Photo and voice-memo attachments (encrypted, opaque to server).
- One hosted server (Railway). Publishable beyond beta with no protocol changes.
- Build per Court's saved engineering preferences: TDD as the default, build/lint/test checks on every PR/push, split release/deploy workflows.

### Non-Goals (Phase 1)

- Mobile (iOS, Android) — Phase 1.5.
- Push notifications (APNs/FCM) — not needed for desktop-only.
- Server-stored history sync for newly paired devices — Phase 1.5.
- Server-side encrypted backup / "recover lost devices" — Phase 2+.
- Cloud AI providers (OpenAI, Anthropic, OpenRouter, etc.). Local-only by design.
- Federation. One hosted server.
- Disappearing messages, read receipts, typing indicators — Phase 1.5 polish.
- Voice/video calls — Phase 2+.

### Explicit privacy posture

LittleLove makes one promise and one disclosure.

- **Promise:** the server cannot read message contents or attachments.
- **Disclosure:** if a user loses all their devices, message history is gone. Phase 1 does not include account recovery or key backup; this is stated plainly at signup.

## 3. System Architecture

### 3.1 Topology

```
┌──────────────────────────┐    WSS (real-time)   ┌──────────────────────────┐
│  Flutter desktop app     │ ◄──────────────────► │  LittleLove server       │
│  (macOS / Win / Linux)   │    REST (control)    │  (Rust + Axum, Railway)  │
│                          │ ◄──────────────────► │                          │
│  ┌────────────────────┐  │                      │  - Identity / handles    │
│  │ Rust core          │  │                      │  - Prekey directory      │
│  │ (openmls, store,   │  │                      │  - Ciphertext store      │
│  │  transport)        │  │                      │  - WebSocket hub         │
│  └────────────────────┘  │                      │                          │
└──────────────────────────┘                      │  Postgres + S3-compat    │
                                                  └──────────────────────────┘
                                                              ▲
                                                              │ WSS
                                                              ▼
                            ┌──────────────────────────────────────┐
                            │  Home box (Windows in Phase 1)       │
                            │                                       │
                            │  ┌────────────────┐  ┌─────────────┐ │
                            │  │ Bot host       │  │ Ollama      │ │
                            │  │ (Rust daemon)  │◄─┤ (local LLM) │ │
                            │  │ uses: core     │  └─────────────┘ │
                            │  └────────────────┘                  │
                            └──────────────────────────────────────┘
```

### 3.2 Components

1. **`core/`** — Rust library. MLS state (via `openmls`), local message store (SQLite + SQLCipher), WebSocket transport, identity and prekey handling, attachment encryption. Shared between the Flutter app and the bot host.
2. **`server/`** — Rust + Axum web service. Identity registry, prekey directory, ciphertext store, WebSocket hub for delivery, signed-URL minting for attachment blobs.
3. **`app/`** — Flutter desktop application. macOS, Windows, Linux. Calls into `core` via `flutter_rust_bridge`.
4. **`bot-host/`** — Rust daemon. Hosts one or more AI character cards as MLS members. Talks to a local model provider (Ollama or OpenAI-compatible local server). Targets macOS and Windows.

### 3.3 Stack Versions (target — locked at `cargo init` time)

- Rust 1.78+
- `openmls` 0.6.x
- Flutter 3.22+
- `flutter_rust_bridge` 2.x
- `axum` 0.7+, `tokio` 1.38+, `sqlx` 0.7+
- Postgres 16
- **Cloudflare R2** for attachment ciphertext (S3-compatible API; zero egress fees — important for a messenger where every recipient downloads every attachment)
- SQLite + SQLCipher on clients
- `tokio-tungstenite` for WebSocket on both sides

## 4. E2EE Protocol — MLS

LittleLove uses **MLS (Messaging Layer Security, RFC 9420)** via the Rust `openmls` crate.

Why MLS over the Signal Protocol:

- MLS handles 1:1 and many-party rooms with one protocol — no migration when group rooms ship.
- Forward secrecy and post-compromise security via key rotation (epochs).
- Native multi-device model where each device is a distinct cryptographic member.
- AI bots fit cleanly as members with their own keypair, no protocol gymnastics.

What we use:

- **MLS application messages** carry user-visible chat content (text and attachment refs) encrypted to the room's current epoch.
- **MLS commit messages** handle membership changes (add device, add bot, remove device).
- **MLS Welcome messages** bootstrap a new member into the group state.

What we don't do in Phase 1:

- We don't implement custom MLS extensions. Stock openmls only.
- We don't implement a Delivery Service interop layer for federation.

## 5. Identity & Authentication

### 5.1 Accounts and identity

- A user is a **username** (e.g., `@court`). Unique on the server.
- An account has **no password**. The user is whoever holds the private keys of any device linked to the account.
- Each device generates an MLS **identity keypair** on first run and stores the private key in the OS keystore (macOS Keychain / Windows DPAPI / Linux Secret Service). Hardware-backed where the OS supports it.

### 5.2 Server-side records per user

- `username`
- One or more `device_id → identity_public_key` records
- A `signed_prekey` per device
- A small batch of `one_time_prekey`s per device (used up as new contacts pair)

### 5.3 Connecting to the server (every session)

Standard challenge-response:

1. Device opens WSS to `wss://server/connect`.
2. Server sends a random 32-byte nonce.
3. Device signs the nonce with its identity private key (OS prompts for biometric/passcode if the key is gated).
4. Server verifies the signature against the stored public key for `(username, device_id)`.
5. Connection is now authenticated for the lifetime of the WebSocket.

### 5.4 Unlocking the app (every launch)

- The local message store is encrypted at rest using SQLCipher. The DB key is sealed in the OS keystore.
- Opening the app triggers an OS-level keystore unlock (Touch ID, Windows Hello, Linux secret service prompt).
- No app-level PIN in Phase 1. Adding one is a small Phase 1.5 addition.

## 6. Multi-Device & Pairing

### 6.1 Adding a second device (QR flow)

1. New device opens app for the first time. User picks "Link to existing account."
2. New device generates its own identity keypair and displays a QR code containing a short-lived pairing token + its public key.
3. On an already-linked device, user opens **Settings → Linked Devices → + Add device**, authenticates (biometric/passcode), and scans the QR.
4. The existing device produces an MLS Welcome for each room the user is in, addressed to the new device's key.
5. Welcomes are uploaded to the server and pulled down by the new device.
6. New device decrypts the Welcomes, joins the rooms cryptographically, and is now a full member.

### 6.2 Phase 1 limitation: forward-only history

A newly paired device sees messages **from the moment of pairing forward**. Existing history stays on the device that already had it. The pairing screen says this clearly. Full peer-assisted history sync (Option B-prime) is designed but ships in Phase 1.5.

### 6.3 Removing a device

- User picks "Revoke" on a linked device entry.
- The other devices issue MLS Remove proposals in every room the revoked device participated in.
- Revoked device cannot decrypt new messages after the commit.

## 7. Rooms, Messages, Delivery

### 7.1 Rooms

- A **room** is an MLS group.
- 1:1 rooms have 2 user accounts as members. Multi-party rooms (a couple plus a third trusted person, for example) follow the same protocol with more members. AI familiars are extra members alongside humans.
- Membership is opaque to the server (MLS keeps the group state client-side). The server only knows there is a room with a given ID and ciphertext flows through it.

### 7.2 Sending a message

1. User types text in the Flutter UI; calls `core.send_message(room_id, body)`.
2. Rust core encrypts as an MLS application message at the current epoch.
3. Sends ciphertext frame over WSS to the server.
4. Server stores the frame and broadcasts it to every currently connected recipient device.
5. Local store records the sent message with `status = sent`.

### 7.3 Receiving a message

1. Server pushes a ciphertext frame over WSS to a recipient device.
2. Rust core decrypts via openmls and writes plaintext to the local SQLite store.
3. UI subscribes to a stream of new messages and re-renders.

### 7.4 Catch-up on reconnect

- Each device tracks `last_received_message_id` per room.
- On WSS reconnect, the device sends an `ACK` of its last known IDs; the server replays any missing frames.

### 7.5 Server-side retention

- Server keeps ciphertext indefinitely (chosen by the user during brainstorming as the iMessage/WhatsApp posture).
- A future "delete for everyone" feature would send an MLS application message tombstone that clients honor in their local stores — server ciphertext can also be deleted at that point for storage hygiene.

## 8. Attachments

- The Flutter UI hands the Rust core a file path and content type.
- Core generates a fresh symmetric key (AES-256-GCM) and a nonce.
- Core encrypts the file and uploads ciphertext to Cloudflare R2 via a server-issued signed PUT URL.
- Core posts a normal MLS application message into the room with a small attachment reference:
  ```
  { kind: "attachment", blob_url, key, nonce, content_type, size, filename }
  ```
- The reference is encrypted by MLS just like any text message, so the server never sees the decryption key.
- Recipients fetch the ciphertext blob via the URL and decrypt with the key from the reference.

Phase 1 supports images and voice memos. Generic file send is trivially the same path; we'll enable it once the UI for picking arbitrary files is in.

## 9. AI Participants ("Familiars")

The defining feature of LittleLove. An AI familiar is a real MLS member with its own identity keypair, hosted on user-owned hardware. Plaintext stays on hardware the user controls.

### 9.1 Character cards

A `CharacterCard` is a first-class data type:

```rust
struct CharacterCard {
    id: Uuid,
    name: String,           // "Ollie"
    avatar: Option<AvatarRef>,
    persona: String,        // system prompt
    greeting: Option<String>,
    provider_ref: ProviderRef,
    behavior: BotBehavior,  // MentionOnly | AlwaysOn | Smart
    tags: Vec<String>,
}
```

- A user has a **library** of character cards stored on their devices.
- Cards sync between a user's own devices via a dedicated "self" MLS room (the same multi-device sync mechanism we already need).
- Cards never sync between *different* users — each user's library is private.

### 9.2 Bot host

- `little-love-bot-host` is a standalone Rust binary built from the same workspace as the desktop app.
- Targets macOS and Windows (Court's day-one home box is Windows; macOS is included so the same software works in any common home setup).
- Reuses the `core` crate entirely — MLS, message store, transport, attachment handling.
- Configuration file (`bot-host.toml`):
  ```toml
  server = "wss://littlelove.dev/connect"
  
  [provider.home-ollama]
  kind = "ollama"
  endpoint = "http://localhost:11434"
  
  [[card]]
  name = "Ollie"
  persona = """You are Ollie..."""
  provider = "home-ollama"
  model = "llama3.1:8b"
  behavior = "smart"
  ```

### 9.3 Pairing a bot host to an account

1. User installs `little-love-bot-host` on their home box.
2. First run prints a 9-digit pairing code to stdout and serves it at `http://localhost:7707` for convenience.
3. User opens the Flutter app → **Settings → Bot Hosts → + Pair host** → enters the code.
4. App authenticates with biometric/passcode and endorses the host.
5. Host registers one MLS identity per card declared in `bot-host.toml`.
6. From now on, adding a card to a room generates an MLS Welcome that the host pulls down and joins.

### 9.4 Model providers

A small Rust trait covers all supported backends:

```rust
trait LocalModelProvider {
    async fn generate(&self, prompt: ChatPrompt) -> Result<ChatResponse>;
}
```

Implementations Phase 1:

- **Ollama** — HTTP `POST /api/chat`. Primary path.
- **OpenAI-compatible local** — covers LM Studio, llama.cpp server, vLLM. One HTTP adapter, several endpoint configurations.

All `endpoint` values are LAN URLs or `localhost`. Cloud providers (OpenAI, Anthropic, OpenRouter) are **not** implemented and are not planned. This is a privacy product; we will not provide an in-app affordance to leak plaintext to third parties.

### 9.5 Prompt construction

For each triggering message, the bot host builds a prompt:

```
SYSTEM
  <card.persona>
  
  You are in a chat with the following members:
  - @court
  - @kaitlyn

HISTORY (oldest → newest, sender-tagged)
  [@court 14:02] hey love, how was work?
  [@kaitlyn 14:03] long. you?
  
LATEST
  [@court 14:03] hey @ollie what do you think we should do tonight?
```

History is filled from the bot host's local SQLite copy of the room, walked backward until either (a) a token budget is hit or (b) the start of the room is reached. Token budgeting is per-model (we expose a `max_context_tokens` field per provider/model).

### 9.6 Response triggering

Each card declares a behavior:

- **`MentionOnly`** — reply when @mentioned or directly addressed.
- **`AlwaysOn`** — reply to every human message. Useful in dedicated user-bot rooms.
- **`Smart`** — small heuristic: reply if mentioned, if the latest line ends in a question mark, or after N seconds of silence with no human reply. Cheap and surprisingly good.

### 9.7 Offline behavior

- When the bot host is unreachable, the room shows the bot's presence as **offline**.
- Human messages still flow normally.
- On reconnect, the bot host processes a bounded backlog (default: skip replies for messages older than 30 minutes — stale replies feel weird).

### 9.8 Phase 1 limits

- **One bot per room** (multi-bot rooms come later).
- **No cross-bot conversation** (bots don't reply to each other).
- **No tool use / function calling** (Phase 2+).
- **No SillyTavern PNG card import** in Phase 1; arrives in Phase 1.5 as a small additive feature.

## 10. Server Design (`server/`)

### 10.1 Endpoints — REST

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/accounts` | Register username + identity bundle (first device only) |
| `POST` | `/v1/accounts/me/devices` | Register a new device under an existing account (called after pairing Welcome) |
| `GET`  | `/v1/users/:username/key-bundle` | Fetch identity public key + a one-time prekey for starting MLS handshake |
| `POST` | `/v1/attachments/upload-url` | Mint a signed PUT URL for ciphertext blob upload |
| `DELETE` | `/v1/accounts/me/devices/:device_id` | Revoke a device |

All endpoints other than the initial `POST /v1/accounts` require challenge-response auth using the calling device's identity key.

### 10.2 WebSocket

`wss://server/v1/connect` — one long-lived connection per device. After auth, the connection carries:

- Outbound (server → client): ciphertext frames, server-side notifications (e.g., another device of yours connected).
- Inbound (client → server): ciphertext frames to deliver, ACKs for received frames.

Catch-up: on connect, client sends per-room `last_received_id`; server replays the gap before going live.

### 10.3 Postgres schema (sketch)

```
users(id, username UNIQUE, created_at)
devices(id, user_id, identity_public_key, signed_prekey, created_at, revoked_at)
one_time_prekeys(id, device_id, key, consumed_at)
rooms(id, created_at)                                   -- opaque to server
ciphertext_messages(
  id, room_id, sender_device_id, payload BYTEA, created_at
)
room_devices(room_id, device_id)                        -- delivery list only
attachment_blobs(id, content_length, created_at)        -- pointer; bytes in S3
```

Note: `room_devices` is purely for *delivery routing* — the server needs to know which devices to push a ciphertext frame to. It is not the source of truth for membership; MLS state on the clients is. The server learning that device X is in room Y is unavoidable metadata.

### 10.4 Privacy properties

The server **sees**: usernames, device identity public keys, ciphertext bytes, traffic timing, device-to-room mappings (for routing), connection times.

The server **cannot see**: message plaintext, attachment contents, attachment decryption keys, the "shape" of conversations beyond per-room flow, or character card contents.

The threat model is **honest-but-curious server, plus assume eventual compromise**. E2EE limits the blast radius of a compromised server to the metadata above. A future audit story should make this explicit in the published privacy policy.

### 10.5 Infrastructure & Deployment

**Cloud accounts and named resources** (Phase 1 starts with these; provisioned once and reused):

| Resource | Provider | Purpose | Day-1 needs it? |
|---|---|---|---|
| `littlelove-api` service | Railway | Rust + Axum server | Yes |
| `littlelove` Postgres database | Railway managed Postgres | Identity, prekeys, ciphertext metadata | No (Day-1 is in-memory) |
| `littlelove-attachments` bucket | Cloudflare R2 | Encrypted attachment ciphertext blobs | No (Day-1 has no attachments) |
| `littlelove.dev` zone | Cloudflare DNS | Authoritative DNS for the domain | Yes |

**Domain layout:**

- `api.littlelove.dev` → CNAME to the Railway service. Carries `wss://api.littlelove.dev/v1/connect` (WSS) and `https://api.littlelove.dev/v1/...` (REST). Used by clients.
- `littlelove.dev` (apex) → reserved for an eventual marketing/landing site; nothing on it Phase 1.
- **No Cloudflare proxy (orange cloud) in front of Railway** for Phase 1 — direct CNAME, Railway terminates TLS. Adding the proxy later for DDoS/CDN is reversible.

**Deployment workflow** (per Court's saved feedback to split release and deploy):

- Two GitHub Actions workflows:
  1. **release**: build Rust binary, push container image to `ghcr.io/codingwithcourtreeves/littlelove-api:<tag>`, tag the commit.
  2. **deploy**: invoke Railway CLI to deploy a tagged image.
- Required PR/push checks: build, lint (`cargo clippy -D warnings`), tests for `core`, `server`, `bot-host`, and `app`.

**Cost posture (Phase 1, beta usage between two users):**

- Railway: ~$5/mo developer plan + Postgres usage (negligible at beta scale).
- Cloudflare R2: free tier covers 10GB storage + unlimited egress; comfortable for the beta couple.
- Cloudflare DNS: free.
- Total Phase 1 carry: ~$5/mo until real users join.

## 11. Desktop Client (`app/`)

### 11.1 Stack

- Flutter 3.22+ desktop, targets macOS / Windows / Linux.
- All sensitive operations cross into Rust through `flutter_rust_bridge` 2.x. The Flutter side is a thin UI layer: it doesn't touch crypto, doesn't open sockets, doesn't manage keys.
- Local DB: SQLite via SQLCipher; key sealed in OS keystore.
- State management: Riverpod.

### 11.2 Screens (Phase 1)

- **Onboarding** — create account or link device (QR display/scan).
- **Conversation list** — rooms ordered by last activity.
- **Conversation view** — text + attachment messages, send composer, bot presence indicator.
- **Linked devices** — list, pair (QR scanner), revoke.
- **Bot hosts** — list, pair host, manage character card library, add cards to rooms.
- **Settings** — basic preferences, account info, **theme picker** (Hearth default + Linen / Vellum / Twilight presets — see §11.4), "delete account" (irreversible).

### 11.3 Cross-Rust threading

- `core` exposes `tokio`-based async APIs.
- `flutter_rust_bridge` handles the async FFI boundary.
- UI never blocks on crypto or IO; long operations show progress in the UI.

### 11.4 Design tokens, themes, and palette switcher

LittleLove uses semantic design tokens, not raw hex codes, so theming is mechanically possible from day one. The token vocabulary:

| Token | Meaning |
|---|---|
| `bg-canvas` | Page background |
| `bg-surface` | Raised surfaces (sidebar, cards, message bubbles) |
| `bg-surface-alt` | Secondary surfaces (composer, hover states) |
| `text-primary` | Body text |
| `text-muted` | Metadata, timestamps |
| `accent-user` | Your own bubble + sigil + send button |
| `accent-partner` | Your partner's bubble (subtle differentiation) |
| `accent-familiar` | AI familiar bubble + sigil + "AI" pill + left-edge rule |
| `border-soft` | Dividers, card outlines |
| `rule-strong` | The bold left-edge accent on familiar messages (often = `accent-familiar`) |

#### Themes shipped in Phase 1

Four presets, all WCAG-AA-passing for body text in both light and dark:

- **Hearth** (default) — Cozy fireside warmth. Brick-red user accent, warm ochre familiar.
- **Linen** — Soft cream with a coral-rose / forest-teal accent palette. Bright, friendly.
- **Vellum** — Paper-letter aesthetic. Dusty slate-blue user, old-gold familiar. Quieter and more literary.
- **Twilight** — Dark-first identity. Pale dusk-rose user, sage familiar. Evening intimacy.

#### Hearth — locked hex codes (default theme)

**Light variant**

| Token | Hex |
|---|---|
| `bg-canvas` | `#FBEEDD` |
| `bg-surface` | `#F5E2C9` |
| `bg-surface-alt` | `#EFD6B3` |
| `text-primary` | `#2C1E16` |
| `text-muted` | `#8A6E58` |
| `accent-user` | `#B23F2E` |
| `accent-partner` | `#C97E5A` |
| `accent-familiar` | `#9A6B1E` |
| `border-soft` | `#E3CBA6` |
| `rule-strong` | `#9A6B1E` |

**Dark variant**

| Token | Hex |
|---|---|
| `bg-canvas` | `#1E1410` |
| `bg-surface` | `#2A1C15` |
| `bg-surface-alt` | `#33221A` |
| `text-primary` | `#F2E2CB` |
| `text-muted` | `#B0917A` |
| `accent-user` | `#E27966` |
| `accent-partner` | `#D89473` |
| `accent-familiar` | `#E0B25A` |
| `border-soft` | `#43301F` |
| `rule-strong` | `#E0B25A` |

Linen / Vellum / Twilight token tables live in `docs/mocks/palette-gallery.html` — the gallery is the source of truth for non-default themes until those values are extracted into a `core` constants module at implementation time.

#### Application semantics

- **Per-user setting, not per-couple.** Each partner picks their own theme; it does not sync between you. (Synced themes are an explicit non-goal for Phase 1 — it would force matching aesthetics on two people whose tastes differ by default.)
- **Symmetric rendering.** Your own messages render with *your* `accent-user`, regardless of which theme your partner uses. Their messages render with *your* `accent-partner`. The familiar renders with *your* `accent-familiar`. The point: everyone always sees their own bubbles in their own brand color.
- **Per-device, not per-account.** Theme is stored in the local config protected by the OS keystore, alongside the SQLCipher DB key. Each device of yours can have its own theme.
- **Light/dark follows OS** by default, with a manual override in Settings.

#### Flutter implementation note

A `LittleLoveTheme` Dart class exposes the same token vocabulary, with one `ThemeData` per (preset × light/dark) combination — 8 total. Widgets read tokens via `Theme.of(context).extension<LittleLoveColors>()!.accentUser`, never inline hex.

## 12. Bot Host (`bot-host/`)

Already described in §9. Extra notes for build and packaging:

- Cargo workspace member, depends on `core`.
- `cargo build --release` produces a single binary per target platform.
- Distribution Phase 1:
  - Windows: signed `.exe` + a small `install.ps1` that registers a Windows Service.
  - macOS: `.pkg` installer + `launchd` plist; signing/notarization required.
  - Linux: tarball + a sample `systemd` unit (not officially supported in Phase 1).
- Service-isation can come post-beta if manual `start` is acceptable for the author's first deployment.

## 13. Data Flow — Sequences

### 13.1 Send and deliver a text message

```
court's laptop                 server                 kaitlyn's laptop      bot host
     │ core.send("hi")            │                            │                 │
     ├─MLS encrypt──┐             │                            │                 │
     │              │             │                            │                 │
     ├──────WSS frame─────────────►                            │                 │
     │              │             │ store ciphertext           │                 │
     │              │             ├────fanout──────────────────►                 │
     │              │             ├────fanout──────────────────────────────────────►
     │              │             │                            │ decrypt          │ decrypt
     │              │             │                            │ render           │ evaluate trigger
     │              │             │                            │                 │ generate (Ollama)
     │              │             │                            │                 │ MLS encrypt reply
     │              │             ◄──────────WSS frame──────────────────────────────
     │              │             ├────fanout──────────────────►                 │
     │              │             ├────fanout──┐               │ decrypt          │
     │ decrypt own ▼              │            ▼               │ render          │
```

### 13.2 New device pairing

```
desktop (new)                  server                phone-equivalent (existing)
     │ generate identity keypair                              │
     │ show QR(token, pubkey)                                 │
     │                                                        │
     │                       <user scans QR>                  │
     │                                                        │
     │                                ◄── biometric prompt ──►│
     │                                                        │ for each room:
     │                                                        │   build MLS Welcome
     │                                                        │   encrypt to new pubkey
     │                                ◄── POST welcomes ──────│
     │                                                        │
     │ ─── GET welcomes ──────────────►                        │
     │ decrypt, join all rooms, ready                         │
```

## 14. Error Handling

- **WSS drop:** auto-reconnect with exponential backoff (1s, 2s, 5s, 15s, 30s, then capped at 60s).
- **Catch-up gap:** server replays from `last_received_id`; if the gap is too large for memory, server streams in chunks.
- **MLS decryption failure** (rare; indicates state desync): record diagnostic event; render a placeholder *"Couldn't decrypt — ask sender to resend"* in the room.
- **Attachment upload failure:** retry up to 3 times with backoff, then surface a user-visible "Couldn't send attachment, try again" with a manual retry.
- **Bot host disconnect:** bot presence flips to offline; human messages flow normally; on reconnect, bot processes backlog up to 30 minutes old.
- **Crash/kill recovery:** all client writes are transactional in SQLite. No half-written state survives a crash.

## 15. Testing Strategy

Per Court's saved TDD preference: failing test first → make it pass → refactor.

- **`core/`** — Rust unit tests covering MLS state transitions we manage on top of openmls, local-store invariants, attachment encryption round-trips. We do not retest openmls itself.
- **`server/`** — Integration tests using a real Postgres (via testcontainers). End-to-end test harness with two simulated clients (in-process), no UI, that exercises full send/receive/catch-up.
- **Full-stack integration tests** — a `tests/integration/` harness runs against the Docker Compose stack (`./scripts/dev-up.sh`). Two simulated clients exchange real MLS messages through the real Axum server backed by a real Postgres. Runs in CI on every PR via `ci.yml`. Worktree-aware: each worktree gets its own Compose project (namespaced volumes + offset ports) so multiple feature branches can run their integration suites simultaneously without colliding.
- **`bot-host/`** — Integration tests against (a) a mock `LocalModelProvider` returning canned responses, and (b) a real Ollama running in a CI container with a tiny model. The second is gated to nightly to keep PR CI fast.
- **`app/`** — Flutter widget tests for UI flows. Integration tests across the FFI boundary use a fake `core` provider (Riverpod override). Manual QA between two laptops fills the gap for end-to-end UI Phase 1.
- **PR/push required checks** (per saved feedback): build + lint + tests for each crate and the app.

## 16. Repo Layout

```
little-love/
├── Cargo.toml                  # workspace
├── core/                       # Rust library: MLS, store, transport
├── server/                     # Rust + Axum server
│   └── Dockerfile
├── bot-host/                   # Rust daemon for AI bot hosts
├── app/                        # Flutter desktop app
│   └── rust_bridge/            # flutter_rust_bridge generated code
├── shared/                     # CBOR schemas, protocol constants
├── docker-compose.yml          # full local stack: api + postgres + minio (R2 emu)
├── scripts/
│   ├── dev-up.sh               # worktree-aware: namespaces project + offsets ports
│   ├── dev-down.sh
│   └── dev-env.sh              # sourced helper; COMPOSE_PROJECT_NAME + port math
├── tests/
│   └── integration/            # cross-component tests run against compose stack
├── docs/
│   ├── superpowers/
│   │   ├── specs/
│   │   │   └── 2026-06-09-littlelove-design.md
│   │   └── plans/
│   └── architecture/           # ADRs, diagrams
├── .github/workflows/
│   ├── ci.yml                  # build + lint + unit + integration tests
│   ├── release.yml             # on tag push: build & publish .dmg/.msi to GH Release
│   └── deploy.yml              # Railway CLI deploy
├── .gitignore                  # includes .dev.env (per-worktree, generated)
└── README.md
```

**Distribution model:** Court and Kaitlyn (and eventually public users) install the desktop app from `.dmg` (macOS) and `.msi` (Windows) artifacts attached to GitHub Releases by `release.yml` on tag push. No code signing in Phase 1; signing comes when the app goes public. The `app-macos` job runs on a `macos-latest` runner, `app-windows` on `windows-latest`.

Repo will live as a private repository at `github.com/CodingWithCourtReeves/little-love`, matching the saved pattern from related projects. Branch protection deferred (free-tier limitation, per saved pattern).

## 17. Risks & Mitigations

- **MLS state desync between devices** — a known footgun. Mitigation: defensive resync handshakes when a decryption fails with a state-mismatch signal; metrics on per-device decrypt failures to catch regressions early.
- **`flutter_rust_bridge` schema drift** — keep the FFI surface small and explicit; regenerate bindings in CI; pin all dependency versions.
- **Bot host UX when offline** — covered by offline indicator + bounded backlog reply.
- **Single hosted server is a SPOF for Phase 1** — accepted; revisit if real users join beyond the beta couple.
- **Windows packaging and signing** — first time for this project; budget time, treat the first Windows signed release as its own task.
- **Long Rust compile times** — accepted side-project cost; can revisit with `sccache` if it becomes painful.

## 18. Phase 1.5 Hooks (designed, not built)

The following are deliberately deferred but the Phase 1 architecture is built so they slot in without rework:

- **Cross-device history sync** (Option B-prime peer-assisted). Local store already supports chunkable scans; server already hosts opaque blobs.
- **Mobile (iOS + Android)** via the same Flutter app + `flutter_rust_bridge`. Will require APNs/FCM + background-fetch + Keychain/Keystore work, but no protocol or server changes.
- **Push notifications** using a wake-and-fetch model (push payload contains a wake token only; ciphertext is fetched over WSS after wake).
- **SillyTavern PNG character-card import** — purely additive.
- **App-level PIN** in addition to OS unlock.
- **Custom user theme** — let each couple pick their own accent colors instead of choosing a preset. Falls out of the token system for free.
- **Disappearing messages, read receipts, typing indicators.**
- **Multiple bots per room.**

## 19. Phase 2+ (sketch)

- Server-side encrypted backup / "lost all devices" recovery (PIN + Secure Value Recovery-style HSM rate-limiting).
- Always-on bot host as a hosted service for users without home hardware (still local-model only — runs Ollama in a cloud box the user pays for).
- Voice/video calls (E2EE).
- Federation / multi-server.

## 20. Open Questions

None at the moment. This section is left as a placeholder for review feedback.
