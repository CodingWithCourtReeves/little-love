# LittleLove — Accounts & Inbox Design (v0.2)

**Date:** 2026-06-09
**Status:** Approved through brainstorming; pending implementation plan.
**Predecessors:**
- `2026-06-09-littlelove-day1-design.md` — Day-1 (plain text → Postgres → symmetric encryption, single hardcoded conversation).
- `2026-06-09-littlelove-design.md` — Full Phase 1 (MLS, multi-device, bot host, attachments). This document is a deliberate subset.

This document is the **contract source of truth** for implementation. Five parallel worktrees will implement against the wire formats, schemas, API shapes, and cryptographic primitives defined here. Spec ambiguity is a defect to fix in the spec, not in code.

---

## 1. Summary

Replace Day-1c's single hardcoded conversation and pre-shared key with: real user accounts, partner pairing via invite code, per-conversation end-to-end encrypted keys derived by ECDH, and a responsive inbox UI that scales from desktop to mobile-class widths. Server cannot read message plaintext by construction.

Tag target: `v0.2.0`, cut after integration smoke. Three intermediate tags (`v0.2.0-auth`, `v0.2.0-pair`, `v0.2.0-inbox`) mark verification milestones.

---

## 2. Goals & Non-Goals

### Goals
- Court and Kaitlyn each have a real account, not a hardcoded config entry.
- Signup on one device, sign-in on another using a 12-word recovery phrase derived from BIP39.
- One-time invite code (with QR fallback) pairs the two accounts into a couples chat.
- Each chat encrypts with its own key, derived locally; the server never possesses it.
- Multiple chats per user (couples chat now; AI familiar chats deferred but the UI scales to them).
- Inbox UI: persistent sidebar on desktop, NavigationRail at 800px, Drawer at 600px.
- Two concurrent client sessions per user (Court on Mac + Court's hypothetical second device).

### Non-Goals (this round)
- AI familiars / bot host. Deferred entirely — Phase 1 design §9 stands.
- SQLCipher client-side encrypted DB. Local SQLite remains plaintext for v0.2; OS keystore protects the keys.
- Attachments (images / voice / file send).
- Per-device identity keypairs and revocation. All devices for one user share the keypair derived from the recovery phrase. Phase 1 design §6.3 covers the eventual model.
- Multi-party rooms. Positioning forbids; familiars come later as Phase 1 design §7.1 extension.
- Native mobile builds (Android / iOS). Design must collapse to mobile widths; native packaging is Phase 2.
- Forward secrecy beyond the room-key derivation. v0.2 uses a single symmetric key per room. MLS ratchets land in Phase 1.

### Positioning posture
Reaffirming `docs/positioning.md`: monogamous couples. "Inbox" plural because:
- The human couples chat (Court + Kaitlyn, optionally a future AI familiar as a third member).
- Each partner's private 1:1 chats with their AI familiars (deferred, but architecture leaves room).

No friend lists, no group rooms, no family threads. The "invite" surface is exactly two affordances: pair-with-partner (one-time per account) and add-familiar-to-chat (deferred).

---

## 3. Identity & Authentication

### 3.1 Account creation

1. User picks a username (3–20 chars, `[a-z0-9_]`, server-side uniqueness check before commit).
2. Client generates a 256-bit entropy seed via OS CSPRNG.
3. Encode the seed as BIP39 (English wordlist) — produces a 12-word phrase.
4. Derive a master secret: `HKDF-SHA256(salt="littlelove.v0.2.master", ikm=seed)` → 32 bytes.
5. Derive two keypairs deterministically from the master secret:
   - `signing_key_seed = HKDF(salt="littlelove.v0.2.signing", ikm=master)` → 32 bytes → Ed25519 keypair.
   - `encryption_key_seed = HKDF(salt="littlelove.v0.2.encryption", ikm=master)` → 32 bytes → X25519 keypair.
6. Show the user the recovery phrase. Require the user to re-enter words 3, 7, and 11 in order to confirm they recorded it (low-friction sanity check, not a full re-type).
7. Client `POST /accounts` to server with `{ username, ed25519_pub, x25519_pub }`. Server inserts; rejects 409 on duplicate username.
8. Client stores the master secret in the OS keystore using `flutter_secure_storage` with key `llove.master.<username>`. Storage descriptor:
   - macOS: Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
   - Windows: `CredentialManager` (DPAPI-backed).
9. Client persists `{ username, ed25519_pub, x25519_pub, created_at }` in `~/.littlelove/account.json` (non-secret).

### 3.2 Sign-in on a new device (recovery)

1. User enters the 12-word phrase.
2. Client repeats steps 3–5 of §3.1, producing the same keypairs.
3. Client `GET /accounts/by-username/<u>` to fetch the server's stored public keys.
4. Client compares the derived publics to the server's. Mismatch → "this phrase belongs to a different account."
5. On match, client writes the master secret to OS keystore (as in §3.1.8) and `account.json` (as §3.1.9).

### 3.3 Connecting to the server (every WSS session)

1. Client opens `wss://server/connect`.
2. Server sends `{ kind: "Challenge", nonce: <32 random bytes, base64> }` as the first frame.
3. Client computes the **domain-separated signing input** (see §8.5.1): `b"littlelove.v0.2.challenge" || 0x00 || nonce` (25 ASCII bytes + 1 NUL delimiter + 32 nonce bytes = 58 bytes). Client signs that input with its Ed25519 private key.
4. Client replies with `{ kind: "Identify", username, signature: <base64> }`.
5. Server looks up `(username, ed25519_pub)`, verifies the signature, and registers the connection.
6. On failure, server closes with WSS close code 4001 (custom: "auth failed").

The legacy `x-llove-user` header from Day-1 is **removed**. Any server code reading that header is deleted.

### 3.4 Local unlock (every app launch)

- On launch, app reads `~/.littlelove/account.json` to get the username.
- App requests the master secret from OS keystore. This triggers Touch ID on macOS / Windows Hello (PIN/biometric) on Windows 11.
- If the user has opted out of biometric wrap (Settings), app prompts for the recovery phrase instead.
- Once unlocked, derive keypairs in memory; never persist them to disk in cleartext.

### 3.5 Lost recovery phrase

There is no recovery mechanism. The phrase is the only way to restore identity. The signup flow's confirmation step (re-enter words 3/7/11) is the only safety net.

This is intentional. It's also what the positioning doc demands: structural privacy means the server cannot recover what it never possessed.

---

## 4. Pairing & Invites

### 4.1 Flow

1. Court signs up (§3.1) and connects via WSS (§3.3).
2. Court taps "Pair with partner" in the sidebar.
3. Client sends WSS frame `{ kind: "CreateInvite" }`.
4. Server generates a 32-byte random `token`, encodes it as 4 BIP39 words (see §8.6). Stores `(token_hash, inviter_account_id, expires_at = now + 1h, consumed_at = null)`.
5. Server replies `{ kind: "InviteCreated", code, qr_png_base64, expires_at }`. QR encodes the same code string (no extra payload — the code is canonical).
6. Court sends the code to Kaitlyn out of band (text, Signal, in person).
7. Kaitlyn opens the app, picks "I have an invite," types the code (or pastes a code captured from a QR scan).
8. Client `POST /invites/{code}/preview` (unauthenticated REST — Kaitlyn may not have an account yet) returns `{ inviter_username, inviter_ed25519_pub, inviter_x25519_pub, expires_at }`.
9. Kaitlyn confirms ("Pair with @court?"). If she has no account yet she completes signup (§3.1.1–3.1.9) first, then connects via WSS (§3.3).
10. Kaitlyn's client sends WSS frame `{ kind: "ConsumeInvite", code, signature_over_token }`. The signature is Ed25519 over the **domain-separated input** `b"littlelove.v0.2.invite-consume" || 0x00 || token` (30 ASCII bytes + 1 NUL delimiter + 32 raw token bytes = 63 bytes; see §8.5.1). Server verifies the signature against her registered Ed25519 pubkey, marks the invite consumed, creates a `rooms` row with both accounts in `room_members`.
11. Server replies to Kaitlyn `{ kind: "InviteConsumed", room_id, peer_username, peer_ed25519_pub, peer_x25519_pub }` and pushes `{ kind: "RoomCreated", room_id, peer_username, peer_ed25519_pub, peer_x25519_pub }` to Court's connected sessions.
12. Both clients derive the room key (§5). UI: room appears in inbox sidebar pinned at the top.

### 4.2 Constraints

- Invites are single-use. Second consumption attempt returns 410 Gone.
- Invites expire after 1 hour.
- A user can have at most one outstanding invite at a time. Creating a new one revokes the prior.
- An account can be in at most one couples-room (positioning: monogamous). Server enforces this on consume.

### 4.3 QR encoding

QR is a pure presentation of the code string — no JSON, no URL scheme, just the dashed word string. This keeps "type the code" and "scan the code" feeding the same code path on the receiver.

---

## 5. Per-Conversation Encryption

### 5.1 Key derivation

For a room with members A and B:

```
shared_secret = X25519(A_priv, B_pub) = X25519(B_priv, A_pub)  // ECDH
room_key      = HKDF-SHA256(
                  salt = "littlelove.v0.2.room",
                  ikm  = shared_secret,
                  info = room_id (as UTF-8 bytes),
                  len  = 32
                )
```

Both sides compute the same `room_key` independently. The server never learns it.

### 5.2 Message encryption (unchanged from Day-1c)

XChaCha20-Poly1305 AEAD. Per Day-1c, the wire body is base64-encoded ciphertext + nonce. The encrypted-body envelope is unchanged.

### 5.3 Key storage

Client caches derived room keys in memory only. On app restart, they're re-derived from the cached X25519 keypair + the peer pubkeys in the room record. Both are already locally available; derivation takes microseconds; no need to persist the room key.

---

## 6. Inbox UI Architecture

### 6.1 Layouts by width

| Window width | Layout |
|---|---|
| ≥ 800px | Sidebar + detail. Sidebar fixed at 240px, detail fills the rest. |
| 600–799px | NavigationRail (compact icons) + detail. Tap rail entry to switch conversation. |
| < 600px | Drawer + full-screen detail. Hamburger toggles the drawer; detail covers the viewport. |

Breakpoints implemented via `LayoutBuilder` and `MediaQuery`. Sidebar/rail/drawer share the same data source and selection state — only the chrome differs.

### 6.2 Sidebar contents

```
┌────────────────────────┐
│ COUPLES                │
│ ▸ Kaitlyn (pinned)     │  <- always first, always present once paired
│                        │
│ FAMILIARS (deferred)   │  <- section header present, list empty in v0.2
│                        │
│ ─────────────────────  │
│ ⚙  @court              │  <- footer: gear opens settings, @handle shows username
└────────────────────────┘
```

### 6.3 Conversation switching

Selection state lives in a Riverpod-managed `InboxState` provider:
```dart
class InboxState {
  final List<Room> rooms;
  final String? selectedRoomId;
}
```
Switching conversations rebuilds only the detail pane; sidebar selection animates highlight. Per-conversation message lists are independent `MessageStore` instances keyed by `room_id`.

### 6.4 Mobile-first invariants
- Tap targets minimum 44×44 logical pixels.
- Drawer dismiss on detail tap-outside.
- Composer is fixed at the bottom of the detail viewport; scroll the message list above it.
- All sidebar text uses `Theme.of(context).textTheme` — no fixed font sizes that break at large system text settings.

---

## 7. Multi-Device Behavior

- The recovery phrase deterministically derives a user's keypair. Typing the same phrase on a new device → same identity → server accepts the same signatures.
- A user can have multiple concurrent WSS sessions (e.g., Mac and phone). Server tracks `Vec<Tx>` per username and fans out incoming messages to all of them.
- No per-device identity in v0.2. Compromise of any device compromises the identity. Per-device keypairs + revocation are Phase 1 design §6.3 territory and explicitly out of scope.

---

## 8. Contracts (the load-bearing section)

Workstreams MUST implement against these exact shapes. Any deviation is a contract amendment — update the spec first.

### 8.1 REST endpoints (all unauthenticated; authenticated operations are WSS frames in §8.2)

Only three REST endpoints exist in v0.2. Everything else is WSS frames.

#### `POST /accounts`
**Request:**
```json
{ "username": "court", "ed25519_pub": "<32 bytes base64>", "x25519_pub": "<32 bytes base64>" }
```
**Response 201:** `{ "username": "court", "created_at": "2026-06-09T19:32:00Z" }`
**Errors:** 400 (invalid username format), 409 (taken).

#### `GET /accounts/by-username/{username}`
Used by the recovery flow (§3.2) to confirm the derived keypair matches the server's record.
**Response 200:** `{ "username", "ed25519_pub", "x25519_pub", "created_at" }`
**Errors:** 404.

#### `POST /invites/{code}/preview`
Unauthenticated by design — Kaitlyn may not have an account yet. Possession of the code is the only authorization.
**Request:** `{}`
**Response 200:** `{ "inviter_username", "inviter_ed25519_pub", "inviter_x25519_pub", "expires_at" }`
**Errors:** 404 (unknown), 410 (expired or consumed).

### 8.2 WebSocket frames

All frames are JSON with a `kind` discriminator.

#### Server → client, first frame after connect
```json
{ "kind": "Challenge", "nonce": "<32 bytes base64>" }
```

#### Client → server, response to Challenge
```json
{ "kind": "Identify", "username": "court", "signature": "<base64 Ed25519 sig of the domain-separated nonce; see §3.3 and §8.5.1>" }
```

#### Server → client after successful Identify
```json
{ "kind": "Authenticated" }
```

#### Server → client, immediately after Authenticated, the user's room list
```json
{ "kind": "Rooms", "rooms": [ { "room_id": "01J2QXK...", "peer_username": "kaitlyn", "peer_ed25519_pub": "<base64>", "peer_x25519_pub": "<base64>", "created_at": "..." } ] }
```

#### Client → server, after Authenticated, to subscribe to a room (also requests replay)
```json
{ "kind": "Subscribe", "room_id": "01J2QXK...", "since_message_id": null }
```

#### Server → client, replay or live message
```json
{ "kind": "Message", "id": "...", "room_id": "...", "from": "court", "ts": "2026-06-09T19:33:00Z", "body": "<wire body>", "replayed": true }
```

#### Client → server, send a message
```json
{ "kind": "Send", "room_id": "...", "body": "<wire body, base64(ciphertext)|base64(nonce)>", "client_msg_id": "<uuid>" }
```

#### Client → server, create an invite
```json
{ "kind": "CreateInvite" }
```

#### Server → client, invite created
```json
{ "kind": "InviteCreated", "code": "amber-fern-locket-tide", "qr_png_base64": "<base64>", "expires_at": "2026-06-09T20:32:00Z" }
```
**Errors:** WSS error frame `{ kind: "Error", code: "AlreadyPaired" }` if the caller already has a room member entry.

#### Client → server, consume an invite
```json
{ "kind": "ConsumeInvite", "code": "amber-fern-locket-tide", "signature_over_token": "<base64 Ed25519 sig of the domain-separated token; see §4.1 and §8.5.1>" }
```

#### Server → consumer, invite consumed
```json
{ "kind": "InviteConsumed", "room_id": "01J2QXK...", "peer_username": "court", "peer_ed25519_pub": "<base64>", "peer_x25519_pub": "<base64>" }
```

#### Server → inviter, room created (pushed to all inviter sessions)
```json
{ "kind": "RoomCreated", "room_id": "01J2QXK...", "peer_username": "kaitlyn", "peer_ed25519_pub": "<base64>", "peer_x25519_pub": "<base64>" }
```

#### Server → client, generic error
```json
{ "kind": "Error", "code": "<error code>", "message": "<human-readable>" }
```
Error codes: `AlreadyPaired`, `InviteNotFound`, `InviteExpired`, `InviteConsumed`, `InvalidSignature`, `UnknownRoom`.

The Day-1 `Hello` frame is **removed**. Its replay function is taken over by `Rooms` (room list on connect) + `Subscribe` (per-room replay request).

### 8.3 Auth surface — WSS only for authenticated calls

v0.2 has exactly one auth surface: the WSS Challenge → Identify handshake (§8.2). All operations that require auth (CreateInvite, ConsumeInvite, Subscribe, Send, Rooms listing) happen as WSS frames after Identify.

The three REST endpoints in §8.1 are the only unauthenticated surfaces and they're each safe to be: signup needs to be reachable without an account; account lookup is public (public keys are public); invite preview is gated by code possession.

No JWT, no Bearer header, no REST token exchange in v0.2.

### 8.4 Postgres schema

#### Migration `0002_accounts.sql`
```sql
CREATE TABLE accounts (
  id            BIGSERIAL PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  ed25519_pub   BYTEA NOT NULL,
  x25519_pub    BYTEA NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX accounts_username_idx ON accounts (username);
```

#### Migration `0003_invites.sql`
```sql
CREATE TABLE invites (
  token_hash   BYTEA PRIMARY KEY,  -- SHA-256 of the raw 32-byte token
  inviter_id   BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at   TIMESTAMPTZ NOT NULL,
  consumed_at  TIMESTAMPTZ
);
CREATE INDEX invites_inviter_idx ON invites (inviter_id) WHERE consumed_at IS NULL;
```

#### Migration `0004_rooms.sql`
```sql
CREATE TABLE rooms (
  id           TEXT PRIMARY KEY,  -- ULID
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE room_members (
  room_id     TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, account_id)
);
CREATE INDEX room_members_account_idx ON room_members (account_id);

-- Enforce monogamy: a single non-familiar room per account
CREATE UNIQUE INDEX room_members_one_per_account ON room_members (account_id);
```

#### Migration `0005_alter_messages.sql`
```sql
ALTER TABLE messages ADD COLUMN room_id TEXT NOT NULL REFERENCES rooms(id);
ALTER TABLE messages ADD COLUMN from_account_id BIGINT NOT NULL REFERENCES accounts(id);
ALTER TABLE messages DROP COLUMN to_user;
ALTER TABLE messages DROP COLUMN from_user;
CREATE INDEX messages_room_ts_idx ON messages (room_id, ts);
```

Day-1c's `to_user` / `from_user` columns are removed; routing is by room membership now.

### 8.5 Cryptographic primitives

| Purpose | Algorithm | Source |
|---|---|---|
| Recovery phrase | BIP39 English 2048-word list | `bip39` Dart pkg |
| Master key derivation | HKDF-SHA256 | `cryptography` Dart pkg / `hkdf` Rust crate |
| Signing | Ed25519 (RFC 8032) | `ed25519_dart` / `ed25519-dalek` |
| Encryption keypair | X25519 (RFC 7748) | `cryptography` / `x25519-dalek` |
| Message AEAD | XChaCha20-Poly1305 | unchanged from Day-1c |
| ULID generation | `ulid` crate / `ulid` Dart pkg | for `room_id`, `message_id` |
| OS keystore | `flutter_secure_storage` 9.x | macOS Keychain / Windows DPAPI |

All algorithm + library choices are fixed here. Workstreams MUST use these and not substitute.

### 8.5.1 Domain separation for Ed25519 signatures

Every Ed25519 signature in this protocol is computed over a **domain-separated input** of the form `tag || 0x00 || payload`, where:

- `tag` is an ASCII string from the table below — no NUL bytes, no length prefix, no trailing whitespace.
- `0x00` is a single NUL-byte delimiter (since tags are pure ASCII, the NUL byte cannot appear in any tag — the boundary between tag and payload is unambiguous).
- `payload` is the context-specific byte string named in the table.

| Context | Tag (ASCII string, length) | Payload | Total signed input |
|---|---|---|---|
| WSS Challenge response (§3.3) | `littlelove.v0.2.challenge` (25 bytes) | 32-byte server-issued nonce | 25 + 1 + 32 = **58 bytes** |
| Invite consume (§4.1) | `littlelove.v0.2.invite-consume` (30 bytes) | 32-byte raw invite token | 30 + 1 + 32 = **63 bytes** |

Signers MUST prepend the tag and NUL delimiter before invoking Ed25519 sign. Verifiers MUST prepend the identical tag and NUL delimiter before invoking Ed25519 verify (use the strict-verification variant on platforms that distinguish, e.g. `verify_strict` in `ed25519-dalek`). An implementation that omits the prefix on either side will not interoperate; tests MUST exercise the success path with the prefix present and fail-closed without it.

**Rationale.** Without domain separation, the same Ed25519 key signs raw 32-byte blobs in two unrelated contexts (Challenge nonce and invite token). An attacker who could coerce a victim into producing one signature could replay it as the other. Today the probability of coincident inputs is negligible (the invite-token-hash padding in §8.6 means token-derived input bytes 6–31 are zero, which is structurally distinct from Challenge nonce entropy), but the defense is incidental rather than explicit. Domain-separation tags make the boundary structural so future spec revisions can't accidentally remove it. This is standard practice in modern signing protocols (ssh, age, Noise, MLS).

**Test vector** (for cross-implementation parity):

Given Ed25519 signing key seed (32 bytes hex) = `0101010101010101010101010101010101010101010101010101010101010101` and nonce (32 bytes hex) = `0202020202020202020202020202020202020202020202020202020202020202`, the domain-separated input for the Challenge response is the byte sequence:

```
6c 69 74 74 6c 65 6c 6f 76 65 2e 76 30 2e 32 2e   littlelove.v0.2.
63 68 61 6c 6c 65 6e 67 65 00 02 02 02 02 02 02   challenge·······
02 02 02 02 02 02 02 02 02 02 02 02 02 02 02 02   ················
02 02 02 02 02 02 02 02 02 02                     ··········
```

(58 bytes total. The `·` in the rendering represents non-printing bytes; the actual bytes are as listed in hex.) WT-A and WT-C MUST agree byte-for-byte on this construction; the same convention applies for invite-consume with its tag.

### 8.6 BIP39 word ordering for invite codes — byte-deterministic

Invite codes use the BIP39 English wordlist (2048 words) but with no checksum, since the security comes from server-side single-use enforcement, not client-side validation.

**Encoding** (32-byte raw token → 4-word code):
1. Let `t` be the 32-byte raw token. Read the first 6 bytes `t[0..6]` as a big-endian unsigned 48-bit integer `n`.
2. Right-shift `n` by 4 bits so only 44 bits remain: `n44 = n >> 4`.
3. Extract four 11-bit indices, most-significant-first:
   - `w0 = (n44 >> 33) & 0x7FF`
   - `w1 = (n44 >> 22) & 0x7FF`
   - `w2 = (n44 >> 11) & 0x7FF`
   - `w3 =  n44        & 0x7FF`
4. Look up `BIP39_EN[w0]..[w3]`. Join with `-`. Lowercase ASCII.

**Decoding** (4-word code → 44 bits, used to look up `token_hash`):
1. Lowercase, split on `-`, look up each word's index in BIP39_EN. Reject if any not found.
2. Recombine into a 44-bit integer using the inverse of step 3 above.
3. The server stores `token_hash = SHA-256(t)` and looks up by `sha256(repack_to_6_bytes(44_bits) || zeros)` — i.e., the **token_hash key** is derived from only the 44-bit code, not the full 32 bytes. That means server-side the "token" is effectively 44 bits of entropy, which is acceptable because invites are single-use with 1h expiry and rate-limited (TODO: rate limit details in the WT-B plan).

**Cross-language fixtures** (workstreams MUST agree):

A shared test fixture file `server/tests/data/invite_vectors.json` lists 8 input tokens (as 32-byte hex strings) and their expected 4-word codes. The fixture is generated by whichever of WT-B / WT-D lands first; the other consumes it and asserts byte-for-byte identical encoding. The integration round (after both merge) re-runs the fixture from both sides in CI. Any mismatch is a spec defect to be amended before either workstream proceeds.

---

## 9. Server Design Changes

### 9.1 Module layout
```
server/src/
  main.rs
  ws.rs           # WSS: Challenge → Identify → Authenticated → Subscribe/Send/Message
  store.rs        # message persistence (existing, refactored for room_id)
  accounts.rs     # NEW: REST /accounts handlers
  invites.rs      # NEW: REST /invites handlers
  rooms.rs        # NEW: room creation, membership, broadcast routing
  auth.rs         # NEW: nonce generation, signature verification, optional bearer-token
```

### 9.2 Routing changes
- WSS handler verifies signature first; rejects anything that fails §3.3.
- Inbound `Send` is rewritten so the server forces `from_account_id` to the authenticated account — clients can't spoof.
- Server routes by `room_id` to all connected sockets whose account is in `room_members` for that room.

### 9.3 Concurrency model
Per-account connection table becomes `HashMap<AccountId, Vec<UnboundedSender<ServerFrame>>>`. Fan-out is "all senders for accounts in `room_members`." Day-1b's bug fix (replay both directions) is subsumed by per-room queries.

---

## 10. Client Architecture Changes

### 10.1 New top-level structure
```
app/lib/
  identity/
    bip39.dart
    keypair.dart
    keystore.dart        # flutter_secure_storage wrapper
    account_local.dart   # ~/.littlelove/account.json
  pairing/
    invite_create.dart
    invite_consume.dart
    qr.dart
  crypto/
    ecdh.dart            # X25519 shared secret + HKDF
    cipher.dart          # existing XChaCha20-Poly1305 (renamed wire/crypto.dart)
  inbox/
    inbox_state.dart     # Riverpod provider
    sidebar.dart
    navigation_rail.dart
    drawer.dart
    layout_scaffold.dart # picks sidebar/rail/drawer by width
  conversation/
    conversation_page.dart  # existing, refactored to room_id
    message_store.dart      # per-room
  wire/
    frames.dart          # ALL WS frame types
    rest_client.dart     # accounts/invites/rooms REST
  screens/
    auth/signup.dart
    auth/recovery_confirm.dart
    auth/signin.dart
    pair/show_invite.dart
    pair/enter_code.dart
    inbox/inbox_shell.dart
  main.dart              # boot, AuthGate, theme
```

### 10.2 State management
Riverpod is introduced this round. Providers:
- `accountProvider` — current signed-in account (nullable; null gates routing to auth screens).
- `wsClientProvider` — single connection, authenticated.
- `inboxStateProvider` — list of rooms + selected room.
- `messageStoreProvider.family(roomId)` — per-room message store.

### 10.3 Removed
- `config.toml` reading. The signed-in identity replaces it.
- `wire/message.dart` `Hello` frame.
- Day-1c PSK loading.

---

## 11. Testing Strategy

Per-workstream unit + integration tests; per-round manual smoke.

| WT | Server tests | Client tests | Manual smoke |
|---|---|---|---|
| A | `accounts_create.rs`, `accounts_lookup.rs`, `auth_challenge.rs`, `ws_handshake.rs` | — | — |
| B | `invites_create.rs`, `invites_consume.rs`, `rooms_routing.rs`, `monogamy_enforcement.rs` | — | — |
| C | — | `bip39_test.dart`, `keypair_test.dart`, `keystore_test.dart`, `signup_widget_test.dart`, `signin_widget_test.dart` | R1 |
| D | — | `ecdh_test.dart`, `invite_show_test.dart`, `invite_consume_test.dart` | R2 |
| E | — | `inbox_layout_test.dart` × 3 widths, `sidebar_test.dart`, `switch_conversation_test.dart` | R3 |

Manual smoke rounds (Court-driven):
- **R1 — Identity:** Court signs up on Mac. Sees recovery phrase. Confirms words 3/7/11. Closes app. Reopens. Touch ID unlocks. Server log shows signed handshake. Same recovery phrase signs in on Kaitlyn's Win11 (using a throwaway second account or temp username) → Windows Hello PIN unlocks.
- **R2 — Pairing:** Court generates invite code. Code arrives in his clipboard. Kaitlyn enters the code on her account. Both see the conversation in their inbox. Court sends "test"; server log shows ciphertext only; Kaitlyn receives "test". `psql` `SELECT body FROM messages` returns base64 garbage.
- **R3 — Inbox:** Multiple conversations show in sidebar (test fixture or second pairing). Switching is instantaneous. Resize window from 1400 → 700 → 500 px; layout transitions cleanly at 800 and 600. Composer stays anchored at bottom; tap targets in drawer are at least 44×44.

---

## 12. Workstream Decomposition

### 12.1 Five worktrees, two rounds of parallel work plus one solo

| WT | Title | Owns | Depends on |
|---|---|---|---|
| **A** | Server identity | `server/src/{auth.rs, accounts.rs, ws.rs}`, `migrations/0002_accounts.sql` | spec §8.1, §8.2, §8.4 |
| **B** | Server pairing + rooms | `server/src/{invites.rs, rooms.rs, store.rs (refactor), ws.rs (room routing)}`, `migrations/0003+0004+0005` | WT-A merged |
| **C** | Client identity | `app/lib/{identity/, crypto/, wire/frames.dart (auth subset), wire/rest_client.dart (accounts subset), screens/auth/, main.dart (AuthGate)}` | spec §8.1, §8.2, §8.5 |
| **D** | Client pairing + ECDH | `app/lib/{pairing/, crypto/ecdh.dart, screens/pair/, wire/frames.dart (room subset), wire/rest_client.dart (invites/rooms subset)}` | WT-C merged |
| **E** | Client inbox shell | `app/lib/{inbox/, conversation/ (refactor for room_id), screens/inbox/}` | WT-C merged (consumes `accountProvider`); D not blocking (mocks the room provider) |

### 12.2 Verification rounds

- **R1:** A + C parallel → R1 smoke → tag `v0.2.0-auth`.
- **R2:** B + D parallel → R2 smoke → tag `v0.2.0-pair`.
- **R3:** E solo → R3 smoke → tag `v0.2.0-inbox`.
- **Integration:** glue session, end-to-end smoke, fix any contract gaps, tag `v0.2.0`.

### 12.3 Worktree isolation rules

- Each WT branches from `main` and merges back via PR before its successor starts.
- Each WT's PR must include its tests passing in CI and an updated `docs/superpowers/specs/.../<WT-letter>-notes.md` if any spec amendment surfaced.
- `dev-env.sh` already partitions ports per worktree via sha1(basename). No port collisions.
- `demo.sh` is updated by WT-C to launch the signup flow when no `~/.littlelove/account.json` exists.

### 12.4 Spec amendment process

If a workstream discovers a contract gap or contradiction:
1. The WT stops implementation immediately.
2. Court is pinged.
3. Spec is amended in `main`.
4. All open WTs rebase onto the amended `main` before continuing.

This is more friction than "just push through" but prevents the failure mode where four worktrees each ship their own interpretation and integration is a rebuild.

---

## 13. Acceptance Criteria

The v0.2.0 tag may not be cut until all of these pass:

1. Court signs up on Mac. Recovery phrase is shown exactly once. Re-typing words 3/7/11 confirms it. Same recovery phrase signs in on Kaitlyn's Win11.
2. Court generates an invite code. Kaitlyn enters it on her account. Both see the conversation in their sidebar within 2 seconds of consume.
3. Court sends a message. `psql` against the message store shows base64 garbage in the `body` column. Kaitlyn's client renders the plaintext.
4. Both partners have two concurrent WSS sessions open from the same identity. A message from a third party arrives at all four sockets.
5. Window resizes from 1400 → 700 → 500 px. Sidebar transitions to NavigationRail at 800, Drawer at 600. No layout jank. Composer remains anchored.
6. Legacy `config.toml` PSK loading is removed from the codebase. `x-llove-user` header trust is removed from the server.
7. All five WTs' tests pass under CI. `cargo fmt --check`, `cargo clippy -- -D warnings`, `dart format --set-exit-if-changed`, `flutter test`, `flutter analyze` all pass.

---

## 14. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `flutter_secure_storage` Windows behavior differs from macOS | WT-C writes integration tests that exercise the keystore on both targets via a `--platform` matrix in CI; manual smoke on Kaitlyn's Win11 is required for R1 sign-off. |
| BIP39 encoding diverges between Dart and Rust | Spec §8.6 nails byte ordering; WT-B and WT-D each include a "vectors match" unit test using the same 8 deterministic input tokens. |
| Worktree drift on the auth contract | Spec §8.1 + §8.2 freeze the wire format. Amendment process §12.4 enforces re-sync. |
| `flutter_secure_storage` prompts feel jarring on macOS | "Allow access to Keychain" once at first launch is normal UX; no further prompts during the session because `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the item live. |
| One partner loses their recovery phrase | Documented as intentional (§3.5). UI surfaces this strongly during signup. |
| Server compromise leaks public keys | Public keys are public by design. No confidentiality loss; identity-spoofing protection still holds because the attacker has no private keys. |

---

## 15. Open Questions

None blocking implementation. The brainstorming pass closed:
- Auth scheme — passphrase + OS unlock wrapper (Bitwarden pattern).
- Invite — code primary + QR optional.
- Encryption — ECDH-derived per-conversation key.
- Layout — sidebar+detail, mobile-collapse breakpoints at 800/600.
- Multi-device — recovery phrase as the pairing primitive.
- Worktree decomposition — five WTs, three rounds of verification, integration last.

Phase 1 design's MLS, multi-device-per-key, attachments, and bot host all remain as the next slice after v0.2.

---

## 16. References

- `docs/positioning.md` — founder voice; positioning posture this spec defers to.
- `docs/superpowers/specs/2026-06-09-littlelove-day1-design.md` — Day-1 throwaway design we're replacing the auth surface of.
- `docs/superpowers/specs/2026-06-09-littlelove-design.md` — full Phase 1 design; this spec is a deliberate subset and forward-compatible with the MLS migration in Phase 1 §§5–7.
- BIP39 spec: bitcoin/bips/bip-0039
- RFC 7748 (X25519), RFC 8032 (Ed25519), RFC 5869 (HKDF), RFC 7539 (ChaCha20-Poly1305).
