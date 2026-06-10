# LittleLove v0.3 — Group Rooms with Familiars

**Status:** Draft (amends `2026-06-09-littlelove-accounts-and-inbox-design.md`)
**Date:** 2026-06-10
**Supersedes:** v0.2 §4 (Pairing), §5 (Per-Conversation Encryption), §8.2 (WS frames), §8.4 (Postgres schema) — in part.

**Amendments (2026-06-10, post-plan-writing):**
- §5.2 step 5 — InviteConsumed (consumer-only ack) AND RoomCreated (broadcast to others) both fire, both carrying the v0.3 multi-member payload.
- §8.2 Rooms frame — adds `owned_bots: [Member]` so the Create-Chat picker can list familiars that aren't yet in any room.
- §9 migration 0006 — adds `invites.room_id` column binding an invite to its parent room created by `CreateRoom { invite_human_partner: true }`.

---

## 1. Summary

v0.3 generalizes LittleLove's room model from "exactly two humans" to "**one human partner** + **any number of local AI familiars**." Humans remain monogamously paired with at most one other human; familiars are non-human room participants owned by humans, deterministically derived from the owner's master seed, and reusable across rooms. The per-room ECDH key derivation (v0.2 §5.1) stays the same primitive but composes into **pairwise fan-out** — each `Send` carries one ciphertext per other room member.

## 2. Goals & Non-Goals

### Goals

- Support rooms with N members: 1 or 2 humans + 0..N familiars.
- Preserve the v0.2 "no cloud AI ever" positioning — familiars are local-only Rust binaries (already shipped in PR #8 / `feat/ai-bot`).
- Let couples create multiple named rooms together (e.g. "Daily life", "Travel planning") without inflating to a true group-chat product.
- Keep server content-blind: every per-recipient ciphertext stays opaque to the server.
- No protocol cryptography to invent. Reuse v0.2's pairwise X25519 ECDH; reuse v0.2's XChaCha20-Poly1305 envelope; reuse v0.2's domain-separated Ed25519 signing.

### Non-Goals (this round)

- True group chat scaling. The fan-out model is fine through ~6 members; a future revision can adopt MLS when N > 10 becomes a real use case.
- Forward secrecy on departure. Removed members retain plaintext of messages they received. We do not rotate keys on `LeaveRoom`.
- Adding members to an existing room. Membership shrinks (via leave/delete), never grows.
- Bot rerunning under owner-derived identity for v0.2 bots. PR #8 ships bots with their own master secret; v0.3 introduces owner-derived identity for **new** bots. Existing bots keep working; migration is opt-in (see §11).
- Editing or deleting messages.
- Read receipts, typing indicators.

### Positioning posture

The familiar is a household-local participant, not a vendor service. The bot UI calls them "familiars" deliberately — closer in spirit to a household pet or a printed cookbook than to "Alexa." The "no cloud AI ever" line in `docs/positioning.md` is non-negotiable; PR #8's `addr_guard` enforces it at the network layer.

## 3. Conceptual Model

### 3.1 Room shapes

A room contains:

- **0 or 1 partner**: the user's one human partner identity (see §3.2).
- **0..N familiars**: bot accounts owned by either human in the room.

Combinatorially:

| Shape | Example | Sidebar section |
|---|---|---|
| 2 humans, 0 bots | Court ↔ Kaitlyn | COUPLES |
| 1 human, ≥1 bots | Court + Journal | FAMILIARS |
| 2 humans, ≥1 bots | Court + Kaitlyn + Garden | FAMILIARS |

A room must have **≥2 total participants**. A room cannot contain two different human partner identities.

### 3.2 Monogamy invariant (revised from v0.2)

**Old (v0.2):** "Each account is in at most one room." Enforced by `UNIQUE INDEX room_members_one_per_account`.

**New (v0.3):** "Each human has at most one human partner identity." Across all of a human's rooms, the union of *other humans* they co-exist with has cardinality ≤ 1.

This means: Court + Kaitlyn can share many rooms (couple-only, couple-with-Garden, couple-with-TherapyBot, etc.). Court cannot simultaneously be in any room with Kaitlyn AND any room with Alex (a different human).

The invariant is enforced in app code at `ConsumeInvite` and `CreateRoom` time (see §5.3). The database does not express the constraint with a single unique index; it stores the canonical partnership in `accounts.partner_account_id`.

### 3.3 Familiars (bot accounts)

A familiar is a regular `accounts` row with:

- `is_bot = TRUE`
- `owner_account_id` set to the human who registered it
- `partner_account_id` always NULL (familiars don't participate in monogamy)

A familiar has its own Ed25519 + X25519 keypair, signs the WSS handshake challenge like a human, and is content-blind to the server in exactly the same way.

A familiar's identity is **deterministically derived from its owner's master seed**:

```
bot_seed     = HKDF-SHA256(
                 salt = b"littlelove.v0.3.bot",
                 ikm  = owner_master_seed,
                 info = utf8("bot:" || bot_label),
                 len  = 32
               )
bot_ed25519  = Ed25519 keypair from bot_seed (per v0.2 §3.1 derivation)
bot_x25519   = X25519 keypair from bot_seed (per v0.2 §3.1 derivation)
```

Where `bot_label` is a free-form string like `"garden"` or `"journal"`. The owner picks the label at registration; the same `(owner_master_seed, label)` always reproduces the same bot identity. This means **Court's 12-word recovery phrase reproduces his entire bot stable** — no separate recovery phrases per bot.

## 4. Bot Identity Lifecycle

### 4.1 Registration

Familiars register via a new REST endpoint:

```
POST /accounts/bot
Content-Type: application/json
Body: {
  "owner_username":        "court",
  "bot_label":             "garden",
  "bot_username":          "court-garden",            // server-suggested; client may override
  "bot_ed25519_pub":       "<base64 32 bytes>",
  "bot_x25519_pub":        "<base64 32 bytes>",
  "owner_signature":       "<base64 64 bytes>"
}
```

The `owner_signature` is Ed25519 over the domain-separated input:

```
b"littlelove.v0.3.bot-register" || 0x00 || bot_ed25519_pub
```

(31 ASCII bytes + 1 NUL + 32 raw pubkey = 64 bytes total. Mirrors the §8.5.1 domain-separation pattern from v0.2.)

Server:

1. Looks up owner by `owner_username`; pulls their stored Ed25519 pubkey.
2. Verifies `owner_signature` against the domain-separated input. Reject 401 on failure.
3. Validates `bot_label` matches `/^[a-z0-9-]{1,32}$/`. Reject 400 on failure.
4. Validates `bot_username` matches `/^[a-z0-9][a-z0-9_-]{0,31}$/` (v0.2 username rules) and is not in use. Reject 409 on collision.
5. Inserts `accounts` row: `is_bot=true, owner_account_id=<owner.id>, partner_account_id=NULL`.

Idempotent on `(owner_account_id, bot_label)`: re-registering the same label is a no-op (200 with the existing bot's account info).

### 4.2 Operation

Once registered, the familiar:

- Connects to the server via the existing WSS endpoint (`/ws`).
- Runs the v0.2 §3.3 Challenge / Identify handshake. Signs the challenge with its derived Ed25519 priv.
- Receives `Rooms`, `Message`, and `RoomCreated` frames identically to a human client.
- Sends `Send` frames with pairwise fan-out (§6).

A familiar does NOT have a recovery phrase. If a familiar's identity needs to be reconstituted on a different machine, the owner re-runs `littlelove-bot spawn --label <label>` and the binary re-derives the same keypair from the owner's master seed.

### 4.3 Multi-device

Two `littlelove-bot run` processes on the same `owner_master_seed + bot_label` derive the same identity. Both connect to the server; the v0.2 multi-session routing fans every inbound frame to both. **Both processes will then send a reply.** This is a documented operational limitation; the protocol does not solve it in v0.3. Run one bot process per identity.

A future spec can add session-locking (first connect wins a server-side lease; second connect is rejected with `code: "BotSessionInUse"`).

## 5. Room Creation

### 5.1 Flow

The host creates a room before any human invite exists:

1. Host selects participants in the UI (themselves + 0..N familiars + optionally one human partner).
2. Host sends `CreateRoom` (§8.2).
3. Server validates:
   - Every `bot_account_ids[i]` exists with `is_bot=true` AND `owner_account_id ∈ {host.id, host.partner_account_id}` (host or their partner owns it).
   - Monogamy: if `invite_human_partner=true`, the host's `partner_account_id` may be NULL (new pair) OR must match the eventual consumer (enforced again at consume time).
   - `name`, if provided, ≤ 64 chars.
4. Server creates the `rooms` row and inserts `room_members` entries for the host and each listed bot immediately.
5. If `invite_human_partner=true`, server creates a pending `invites` row keyed by the new room ID; returns the 4-word code + QR.
6. Server emits `RoomCreated` to the host with the full member list. Bots receive `RoomCreated` on their own connections.

If `invite_human_partner=false`, the room is fully populated at this point (host + bots only).

### 5.2 Joining (when `invite_human_partner=true`)

The host shares the 4-word code with their partner. The partner enters it on their device. The client:

1. Calls `POST /invites/{code}/preview` (already v0.2). Server now returns the **full room roster** in the preview response (not just the inviter):
   ```json
   {
     "room_id":                "01K…",
     "name":                   "Travel planning",
     "members": [
       {"username":"court",       "ed25519_pub":"…", "x25519_pub":"…", "is_bot":false, "role":"host"},
       {"username":"court-garden","ed25519_pub":"…", "x25519_pub":"…", "is_bot":true,  "role":"familiar", "owner_username":"court"}
     ],
     "expires_at":             "2026-06-10T14:00:00Z"
   }
   ```
2. Client renders the consent screen (mocks/v0.3/invite-preview-multi.html) showing **all** members the room would contain, including which familiars are present. The user reviews → confirms.
3. Client sends `ConsumeInvite` (unchanged wire shape from v0.2, including the §8.5.1 domain-separated signature over the canonical token).
4. Server validates the signature, runs the §5.3 monogamy check, marks the invite consumed, inserts the consumer into `room_members` for the **room the invite was bound to** (see §9 `invites.room_id` column added 2026-06-10), sets `accounts.partner_account_id` on both humans if not already set.
5. Server emits `InviteConsumed { room_id, name, members }` to the consumer's own session(s) as a single-shot ack, AND broadcasts `RoomCreated { room_id, name, members, pending_invite: null }` to every OTHER member (host + familiars + any additional humans already in the room). The two frames carry identical payloads; the discriminator is the direction. _(Amendment 2026-06-10: §8.2's "Existing frames unchanged: InviteConsumed" line refers to the wire-level discriminator, not the v0.2 payload. The new payload is the v0.3 multi-member shape.)_

### 5.3 Monogamy enforcement

On `ConsumeInvite`:

| `consumer.partner_account_id` | `inviter.partner_account_id` | Action |
|---|---|---|
| NULL | NULL | Set both to each other (atomic, single SQL transaction). Allow. |
| `inviter.id` | `consumer.id` | Already paired with each other. Allow. |
| anything else | anything else | Reject `Error { code: "MonogamyViolation", message: "you already have a partner" }`. |

On `CreateRoom` with `invite_human_partner=false` but the host has a known partner: the partner is NOT automatically added (rooms are not auto-shared with the partner). If the host wants the partner in the room, they must set `invite_human_partner=true` and share the code — even though they're already paired.

## 6. Per-Conversation Encryption

### 6.1 Key derivation (unchanged from v0.2 §5.1)

For each pair of members (A, B) in a room, derive:

```
shared   = X25519(A_priv, B_pub)
room_key = HKDF-SHA256(salt=b"littlelove.v0.2.room", ikm=shared, info=room_id_utf8, len=32)
```

The salt remains `"littlelove.v0.2.room"` even on v0.3. The derivation primitive is byte-identical to v0.2; only its composition changes (now applied N-1 times per room instead of once). Keeping the salt string lets v0.2 ↔ v0.3 keypairs interoperate without a re-derivation pass during migration. Each member holds N-1 pairwise keys per room (one per other member).

### 6.2 Message encryption — pairwise fan-out

On Send, the client:

1. Computes the plaintext envelope `{kind: "text", text: "<msg>", ts: <utc>}` (per v0.2 §5.2).
2. For each other member of the room, encrypts the envelope with the pairwise `room_key` using XChaCha20-Poly1305 (same primitive and wire format as v0.2).
3. Submits `Send { room_id, bodies: { recipient_x25519_pub_b64: ciphertext_string, … }, client_msg_id }`.

Wire size grows ~linearly in N. For our scale (2–6 members, low message volume) this is irrelevant.

### 6.3 Server handling

On receiving `Send`, the server:

1. Validates `bodies.keys()` exactly equals `{m.x25519_pub | m ∈ room_members, m ≠ sender}` as a set. Mismatch → `Error { code: "FanOutMismatch" }`.
2. Allocates `message_id` (ULID, as v0.2).
3. Inserts **one `messages` row per recipient** with `(message_id, room_id, sender_account_id, recipient_account_id, body=<their ciphertext>, ts)`.
4. Fans out `Message { id, room_id, from, ts, body, replayed:false }` to all currently-connected sessions of each recipient. The recipient's `body` is the single ciphertext addressed to them; the recipient never sees other recipients' bodies.

### 6.4 Replay

On `Subscribe { room_id, since_message_id }`, the server replays:

```sql
SELECT id, room_id, sender_username AS from, ts, body
FROM messages
WHERE room_id = $1 AND recipient_account_id = $2
  AND ($3::text IS NULL OR id > $3)
ORDER BY id
```

The subscriber receives only ciphertexts addressed to them. Decryption proceeds as v0.2 §5.2, with the cannot-decrypt sentinel (`__cannot_decrypt__`) for any AEAD failure.

### 6.5 Storage cost

N× messages per room. For LittleLove's scale this is negligible:

- 6-member room (extreme upper bound for this design)
- 50 messages/day
- = 300 rows/day = ~110k rows/year

A small Postgres on a Railway free tier handles 100× that comfortably.

## 7. Inbox UX Rules

### 7.1 Room naming

`rooms.name` is set at creation (optional, max 64 chars). When non-empty, clients display it verbatim. When empty, clients derive from member roles:

| Shape | Derived name |
|---|---|
| Court + Kaitlyn | `"Kaitlyn"` |
| Court + Garden | `"Garden"` |
| Court + Garden + Journal | `"Garden + Journal"` |
| Court + Kaitlyn + Garden | `"Kaitlyn + Garden"` |
| Court + Kaitlyn + Garden + Journal | `"Kaitlyn + Garden + Journal"` |

Partner first, then familiars, alphabetical within each group. Self is never named.

### 7.2 Rename

Either **human member** can rename a room via `RenameRoom { room_id, name }`. Familiars cannot rename. Server broadcasts the new name to all connected sessions. Empty-string clears the name and reverts to derived display.

### 7.3 Sidebar grouping

Two sections persist from v0.2:

- **COUPLES** — rooms with 2 humans and 0 bots.
- **FAMILIARS** — every other room (solo + bots, couple + bots).

A user with three Court+Kaitlyn rooms ("Daily life", "Travel planning", "Big decisions") sees all three in COUPLES. A user with Court+Kaitlyn+Garden sees that in FAMILIARS.

Rooms within each section are sorted by `last_message_ts DESC`, falling back to `created_at DESC` for empty rooms.

### 7.4 Member departure

Any member (human or familiar) may leave a room they're in via `LeaveRoom { room_id }`. Server:

1. Removes the row from `room_members`.
2. Broadcasts `MemberLeft { room_id, username }` to remaining members.
3. If the departing member is the **last human** in the room, server cascades-deletes the room (familiar-only rooms with no human are not meaningful).
4. If the departing member is **one of two humans** in a couple room, the room becomes solo-with-bots OR is deleted if there are no bots.

Departure does NOT clear `partner_account_id` on either human. The pair-identity link is durable; only room-by-room membership is mutable.

### 7.5 Bot removal by owner

If an owner deletes a familiar account (`DELETE /accounts/bot/{label}` — to be specified), the server cascades-deletes the familiar's `room_members` rows and broadcasts `MemberLeft` to remaining members in each affected room. The familiar's `accounts` row is hard-deleted.

## 8. Wire Contracts

### 8.1 REST endpoints

| Method | Path | Auth | Body | Returns |
|---|---|---|---|---|
| POST | `/accounts` | none | v0.2 unchanged | v0.2 unchanged |
| POST | `/accounts/bot` | owner Ed25519 sig | §4.1 | `{ account_id, bot_username, ... }` |
| DELETE | `/accounts/bot/{label}` | owner Ed25519 sig over `b"littlelove.v0.3.bot-delete"` ‖ 0x00 ‖ label | none | 204 |
| GET | `/accounts/by-username/{u}` | none | v0.2 unchanged | v0.2 unchanged |
| POST | `/invites/{code}/preview` | none | none | §5.2 (now includes full member roster) |

### 8.2 WebSocket frames

**Existing v0.2 frames** that change:

```
Send {
  room_id:        string,
  bodies:         map<string, string>,   // recipient_x25519_pub_b64 → ciphertext
  client_msg_id:  uuid,
}

Message {
  id:             string,                // ULID
  room_id:        string,
  from:           string,                // sender username
  ts:             ISO-8601 UTC,
  body:           string,                // single ciphertext addressed to this recipient
  replayed:       bool,
}

Subscribe {
  room_id:           string,
  since_message_id:  string | null,
}

Rooms {                                  // server → client on Authenticated
  rooms: [
    {
      room_id:    string,
      name:       string,                // empty = client derives
      members: [
        {
          username:        string,
          ed25519_pub:     string,       // base64
          x25519_pub:      string,       // base64
          is_bot:          bool,
          owner_username:  string | null,   // present for bots; null for humans
        }
      ],
      created_at: ISO-8601 UTC,
    }
  ],
  // Amendment 2026-06-10: every familiar whose `owner_account_id` is the
  // authenticated user. Lets the Create-Chat picker list owned bots even
  // before they're in any room. Empty array when the user has no familiars.
  owned_bots: [/* same Member shape as rooms[].members */]
}
```

**New v0.3 frames**:

```
CreateRoom {
  name:                  string | null,    // ≤ 64 chars
  bot_account_ids:       [int64],
  invite_human_partner:  bool,
}

RoomCreated {                              // server → all current members
  room_id:         string,
  name:            string,
  members:         [/* same shape as Rooms */],
  pending_invite:  null | {
    code:           string,                // 4 BIP39 words
    qr_png_base64:  string,
    expires_at:     ISO-8601 UTC,
  },
}

RenameRoom {                               // client → server
  room_id:  string,
  name:     string,                        // empty → revert to derived
}

RoomRenamed {                              // server → all members
  room_id:  string,
  name:     string,
}

LeaveRoom {                                // client → server
  room_id:  string,
}

MemberLeft {                               // server → remaining members
  room_id:   string,
  username:  string,
}

Error {
  code:     string,
  message:  string,
}
// New error codes:
//   "FanOutMismatch"        — Send.bodies keys ≠ other room members
//   "MonogamyViolation"     — would introduce a second human partner
//   "NotOwnedBot"           — listed a bot_account_id you don't own
//   "MembershipFrozen"      — tried to add a member to an existing room
//   "BotSessionInUse"       — reserved for future session locking
```

**Existing frames unchanged**: `Challenge`, `Identify`, `Authenticated`, `CreateInvite`, `InviteCreated`, `ConsumeInvite`, `InviteConsumed`, `SendAck`. Their semantics are preserved.

### 8.3 Domain-separated signatures

v0.3 adds two new domain tags. All signatures use the v0.2 §8.5.1 pattern: `tag_bytes || 0x00 || payload_bytes`.

| Purpose | Tag (ASCII bytes) | Payload |
|---|---|---|
| Bot registration | `littlelove.v0.3.bot-register` (29 B) | bot Ed25519 pubkey (32 B) |
| Bot deletion | `littlelove.v0.3.bot-delete` (28 B) | bot label (variable, ≤ 32 B) |
| Existing: WSS challenge | `littlelove.v0.2.challenge` (25 B) | challenge nonce (32 B) |
| Existing: Invite consume | `littlelove.v0.2.invite-consume` (30 B) | canonical token (32 B) |

## 9. Postgres Schema Migration

```sql
-- 0006_v0_3_partner_and_bot.sql

-- accounts: track human partner identity + bot ownership
ALTER TABLE accounts
  ADD COLUMN is_bot              BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN owner_account_id    BIGINT  REFERENCES accounts(id) ON DELETE CASCADE,
  ADD COLUMN partner_account_id  BIGINT  REFERENCES accounts(id) ON DELETE SET NULL;

ALTER TABLE accounts
  ADD CONSTRAINT accounts_partner_not_self
    CHECK (partner_account_id IS NULL OR partner_account_id <> id);

ALTER TABLE accounts
  ADD CONSTRAINT accounts_owner_only_for_bots
    CHECK ((is_bot AND owner_account_id IS NOT NULL)
        OR (NOT is_bot AND owner_account_id IS NULL));

ALTER TABLE accounts
  ADD CONSTRAINT accounts_bots_no_partner
    CHECK (NOT is_bot OR partner_account_id IS NULL);

CREATE INDEX accounts_owner_idx   ON accounts(owner_account_id);
CREATE INDEX accounts_partner_idx ON accounts(partner_account_id);

-- rooms: optional display name
ALTER TABLE rooms
  ADD COLUMN name TEXT NOT NULL DEFAULT '',
  ADD CONSTRAINT rooms_name_length CHECK (char_length(name) <= 64);

-- room_members: drop v0.2 monogamy index; replaced by app-layer partner check
DROP INDEX room_members_one_per_account;

-- Amendment 2026-06-10: bind invites to their parent room so ConsumeInvite
-- knows which room the consumer joins. Legacy v0.2 CreateInvite (no parent
-- room) inserts NULL; the consume handler lazily creates a 2-member couples
-- room in that case (preserves the v0.2 first-time pair flow).
ALTER TABLE invites
  ADD COLUMN room_id TEXT REFERENCES rooms(id) ON DELETE CASCADE;

-- messages: switch from one-row-per-message to one-row-per-recipient
ALTER TABLE messages
  ADD COLUMN recipient_account_id BIGINT REFERENCES accounts(id) ON DELETE CASCADE;

-- Migration of existing v0.2 messages:
--   v0.2 rooms have exactly 2 members; the "other" member is the recipient
--   for each direction. The existing single-row-per-message becomes one row
--   addressed to the non-sender. This is a stop-the-world migration; for a
--   2-user system that's acceptable.
UPDATE messages m
SET recipient_account_id = (
  SELECT rm.account_id
  FROM room_members rm
  WHERE rm.room_id = m.room_id
    AND rm.account_id <> m.sender_account_id
  LIMIT 1
)
WHERE recipient_account_id IS NULL;

ALTER TABLE messages
  ALTER COLUMN recipient_account_id SET NOT NULL;

CREATE INDEX messages_room_recipient_idx
  ON messages(room_id, recipient_account_id, id);
```

Backfill of partner identity for existing v0.2 couples:

```sql
-- For each existing 2-human room, populate partner_account_id on both members.
UPDATE accounts a
SET partner_account_id = (
  SELECT b.id
  FROM room_members rm_a
  JOIN room_members rm_b ON rm_b.room_id = rm_a.room_id AND rm_b.account_id <> rm_a.account_id
  JOIN accounts b        ON b.id = rm_b.account_id
  WHERE rm_a.account_id = a.id
    AND b.is_bot = FALSE
  LIMIT 1
)
WHERE a.is_bot = FALSE AND a.partner_account_id IS NULL;
```

If somehow an account ends up with multiple v0.2 rooms (shouldn't happen given the v0.2 unique index), the `LIMIT 1` picks one and the rest are orphaned — flag as data integrity violation, do not migrate.

## 10. Migration from v0.2

### 10.1 Server

- Apply migration 0006 in a single deployment. Stop-the-world is acceptable; LittleLove has 2 users.
- Existing v0.2 couple rooms become v0.3 couple rooms with `name=''`. Clients render the derived name (`"Kaitlyn"`) as before.
- Existing `messages` rows are backfilled with `recipient_account_id`. Replay continues to work.

### 10.2 Client

- Flutter app on v0.3 sends `Send.bodies` (map) instead of `Send.body` (string). **This is a breaking client change**: a v0.2 client talking to a v0.3 server will fail to send messages (the server's `FanOutMismatch` check rejects the v0.2 single-body shape). Both Court's and Kaitlyn's clients MUST update before the server migration deploys. Coordinate the rollout: build and install the new desktop+iOS binaries on both devices first, then deploy the server migration.
- New "Create chat" wizard (mocks at `mocks/v0.3/`) replaces the inbox-empty "Pair with partner" entry point.
- Receivers' invite-preview screen renders the full member roster (including familiars).

### 10.3 v0.2 bots (PR #8)

Bots registered before v0.3 (via PR #8's pair flow) have:

- Their own master secret stored in `~/.config/littlelove-bot/identity.json`.
- A `room_members` entry in their pair room with Court.
- `accounts.is_bot` is NOT set on their account (the v0.2 schema didn't have the column).

Migration is a one-shot manual operation because the server can't tell from data alone which v0.2 accounts are bots. Court runs a CLI helper that asks for each bot account's owner and emits the SQL:

```sql
-- For each (bot_username, owner_username) pair Court provides:
UPDATE accounts
SET is_bot           = TRUE,
    owner_account_id = (SELECT id FROM accounts WHERE username = :owner_username)
WHERE username = :bot_username;
```

After this, the v0.2 bot accounts are indistinguishable from v0.3-registered bots from the protocol's perspective.

The v0.2 bots **keep** their own master secret; they don't transition to owner-derived seeds. A v0.3 bot opt-in to owner-derived identity is out of scope for this spec (call it `littlelove-bot reseed --derive-from-owner` for a future revision).

## 11. Acceptance Criteria

A v0.3 implementation is correct iff:

1. Court can create a room with himself + Garden (no human partner) and exchange E2EE messages with Garden. The Postgres `messages.body` column contains only opaque base64 (verified via `psql`).

2. Court can create a room with himself + Kaitlyn + Garden via the new "Create chat" wizard. Sends from any member fan out: the wire `Send.bodies` map has exactly 2 entries; each other member receives only their addressed ciphertext.

3. Both Court and Kaitlyn can rename a shared room; the rename broadcasts to the other within 2 seconds.

4. Kaitlyn cannot accept an invite that would pair her with a different human than Court. Server returns `Error { code: "MonogamyViolation" }`.

5. Court can simultaneously have:
   - 1 couple-only room with Kaitlyn ("Daily life")
   - 1 couple-only room with Kaitlyn ("Travel planning")
   - 1 solo+Garden room
   - 1 couple+Garden room
   Without monogamy errors. All four appear in his inbox.

6. When a familiar is offline at Send time, the message is stored in Postgres; on the bot's reconnect, `Subscribe { since_message_id }` replays the queued ciphertexts addressed to the bot's pubkey.

7. When a member leaves a room (`LeaveRoom`), remaining members see `MemberLeft`; the departing member's row is removed; the departing human's `partner_account_id` is NOT cleared.

8. A tampered `Message.body` decrypts to the `__cannot_decrypt__` sentinel and renders verbatim in the UI (v0.2 §13 AC #3 carries forward).

9. Two `littlelove-bot run` processes for the same identity both receive every frame (documented limitation; no test required for the dedup).

10. Existing v0.2 message history replays correctly after migration 0006. Court and Kaitlyn see their pre-migration messages unchanged.

## 12. Open Questions Deferred to Future Specs

- Bot session-locking (avoid double-reply when run on two machines).
- Forward secrecy on departure (key rotation; requires MLS or sender-key chains).
- Adding a member to an existing room (key exchange with the new member; UX consent flow).
- v0.2 bot opt-in to owner-derived identity.
- Group rooms with > 1 partner pair (would require redefining "couple" entirely).

---

**Mocks**: `mocks/v0.3/index.html` (gallery), `inbox-familiars.html`, `create-chat-pick.html`, `create-chat-invite.html`, `invite-preview-multi.html`, `conversation-three.html`. All responsive to phone width.
