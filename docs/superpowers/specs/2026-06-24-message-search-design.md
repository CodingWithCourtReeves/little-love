# Message Search — Design

**Date:** 2026-06-24
**Status:** Design / awaiting review
**Scope:** Search of message text, both **within a single channel** (from the
channel-info page) and **globally across all rooms** (from the chat-rooms
list). Built on a new **local encrypted (SQLCipher) message store** that
persists decrypted history on-device — the foundation the feature requires.

---

## 1. Goals & non-goals

### Goals

- **Search your whole history, instantly, offline.** Search returns results
  from the entire conversation — not just the last 30 days currently held in
  memory — without a network round-trip, matching how Signal / WhatsApp /
  iMessage behave.
- **Competitive search quality.** Relevance-ranked (BM25), accent-insensitive,
  as-you-type prefix matching, with every match highlighted in a result
  (Signal shipped all-match highlighting in 2025; we match it via FTS5
  `highlight()`).
- **Two entry points.** (1) In-channel search from the existing stubbed 🔍 on
  the channel-info page; (2) global search from the chat-rooms list.
- **Jump to the message.** Tapping a result opens the conversation scrolled to
  that exact message, briefly highlighted.
- **No weakening of the E2EE model.** The server keeps seeing only opaque
  ciphertext. Decrypted plaintext lands on disk only inside a SQLCipher
  database whose key lives in the device keychain — the same trust boundary as
  the existing identity seed.
- **Reuse existing infrastructure.** Persistence rides the existing WebSocket
  ingestion path; the local DB mirrors the existing `sqflite` outbox pattern;
  encryption/keychain reuse what identity already uses.

### Non-goals (this worktree)

- **Server-side search.** Impossible by construction — the server only holds
  ciphertext (`messages.body` is base64 XChaCha20-Poly1305). All search is
  client-side. We confirm, not change, this.
- **Backward server pagination** (`messages before id X limit N`). The server
  already supports full-history replay (`SubscribeFrame(sinceMessageId: null)`
  returns every row since epoch — `store.rs` `messages_for_recipient` `else`
  branch). Pagination is a *scaling* follow-up, flagged in §6, not built now.
- **Searching inside attachments / transcribing voice memos**, **fuzzy /
  typo-tolerant matching**, and **search filters** (by sender / date /
  media-type) — documented follow-ups (§9).
- **Substring / CJK matching** (FTS5 `trigram` tokenizer) — a documented
  tokenizer-swap follow-up (§5.2), not the MVP.
- **Android / desktop / macOS** — iOS-only MVP (`project_ios_only_mvp`).

---

## 2. Background: why a local store is required

Findings from codebase investigation (2026-06-24):

- **Messages are E2EE.** Room key = `HKDF(X25519(my_priv, peer_pub))`. The
  server stores one opaque-ciphertext row per recipient; it has no key and
  cannot read or index content. *Search must be client-side over decrypted
  text.*
- **Today the client holds messages in memory only.** `MessageStore` is a
  Riverpod `List<Msg>` per room with no persistence; history is lost on app
  termination and re-replayed (currently the whole room) on next launch. The
  outbox uses `sqflite` but stores **ciphertext only**.
- **Every comparable E2EE app makes the device the source of truth** by
  persisting decrypted history in a local encrypted DB and searching that
  (Signal: SQLCipher/AES-256; WhatsApp: on-device store, transient server copy;
  iMessage: on-device, keys in Secure Enclave). Our in-memory model is the
  outlier.

Therefore: the feature is built in two phases — a local encrypted store first,
then search on top.

---

## 3. Architecture overview

```
WebSocket stream (server = source of truth, opaque ciphertext, ULID order)
        │  decrypt (room key)
        ▼
RoomMessageRouter._ingestMessage  ── write-through ──► MessageDb (SQLCipher)
        │                                                   │  hydrate on open
        ▼                                                   ▼
   MessageStore (in-memory, UI)  ◄────────────────────  FTS5 index
                                                            ▲
                                          search queries ───┘
                                   (in-channel + global UI)
```

- **Server (Postgres):** unchanged. Source of truth for ciphertext, ULID
  ordering, read receipts, deletes, reactions.
- **`MessageDb` (new, SQLCipher):** an **idempotent projection** of the server
  stream, keyed by server message id, holding decrypted plaintext + derived
  state. A *rebuildable cache* — never the system of record (see §4.3).
- **`MessageStore` (existing):** still the in-memory UI source; gains
  hydrate-from-DB on open and write-through on mutation.
- **FTS5 index:** virtual table over message text, kept in sync with the
  messages table; powers both search surfaces.

---

## 4. Phase 1 — Local encrypted message store + sync

### 4.1 Storage & encryption

- Package: **`sqflite_sqlcipher`** (SQLCipher-backed `sqflite`; mirrors the
  existing outbox `openDatabase(version:, onCreate:, onUpgrade:)` pattern).
- DB file: `<app-support>/messages.db`.
- **Key:** a per-device random 32-byte key, minted on first open and stored in
  the iOS keychain via `flutter_secure_storage` with
  `first_unlock_this_device` — same accessibility class as the identity seed
  (`keystore.dart`). **Never synced, never escrowed**, never leaves the device.

### 4.2 Schema (initial)

- `messages` — mirrors `Msg`: `id` (server ULID, PK), `room_id`, `from`,
  `body` (decrypted text / caption), `ts`, `send_status`, attachment metadata
  (JSON), `link_preview` (JSON), `call_outcome`, plus an optimistic
  `client_msg_id` (nullable, for pre-reconcile rows).
- `reactions` — `(message_id, username, emoji)`; or a `reactions_json` column
  on `messages`. (Reactions don't affect search; modeled minimally.)
- `tombstones` — persisted equivalents of the in-memory `_deleted` /
  `_read` / `_cancelled` sets, so out-of-order frames survive restarts (§4.4).
- `room_sync` — per-room **high-water-mark** (max stored server ULID) for delta
  sync (§4.4).
- FTS5 virtual table — see §5.

### 4.3 The store is a rebuildable projection (migration safety)

Local plaintext is always reproducible from `server ciphertext + room key`. So
local migrations are low-risk and **independent of the server's Postgres
migrations** (the CLAUDE.md "schema-only migrations" rule governs Postgres, not
this DB). Three-tier strategy:

1. **Additive change:** `ALTER`/`CREATE` in `onUpgrade` (bump `version`).
2. **Gnarly change:** bump a "rebuild epoch"; drop & re-derive the table from a
   fresh full server replay.
3. **Worst case:** delete the DB file; full re-seed on next connect.

No local data is ever truly at risk; this is the safety net that keeps the
schema easy to evolve.

### 4.4 Sync model (local ↔ server)

**One-directional projection, server authoritative.** The client never
originates authoritative content, so there are no true write conflicts —
optimistic sends always reconcile to a server id. Sync = idempotent upsert of
the existing stream at the existing ingestion choke-points in
`room_message_router.dart`:

| Operation | Choke-point | DB action |
|-----------|-------------|-----------|
| Add message | `store.add(msg)` (`:342`) | upsert by server id |
| Optimistic→server reconcile | `store.reconcile(clientMsgId, msg)` (`:335`) | swap `client_msg_id` row → server `id` |
| Cancelled optimistic | outbox remove (`:333`) | delete `client_msg_id` row |
| Delete / unsend | `store.applyDelete` (`:270`) | soft-delete + tombstone |
| Reaction | `store.applyReaction` (`:257`) | upsert reaction |
| Read receipt | `store.markRead` (`:101`) | set `send_status=read` |

Two correctness invariants carried from CLAUDE.md:

- **High-water-mark delta sync.** Store max server ULID per room; on reconnect
  `SubscribeFrame(sinceMessageId: HWM)` pulls only the delta instead of
  replaying everything. (Client-only change; server already supports it.)
- **Out-of-order tolerance.** A read receipt / delete can arrive *before* the
  message it targets (routinely so for delayed link-preview sends). Persist
  tombstone/flag rows and re-apply them on later insert — never just mutate
  rows that happen to be present.

### 4.5 Hydrate & first-run seed

- **On room open:** `MessageStore` hydrates from `MessageDb` immediately →
  instant history, works offline.
- **First run with the feature:** the DB is empty, so the existing
  `SubscribeFrame(sinceMessageId: null)` full replay seeds it (no server change).
  Subsequent connects use the HWM delta.

### 4.6 Multi-device (iPad + iPhone, same account)

Works today and is unaffected. Identity keys are **deterministically derived
from the recovery phrase** (`keypair.dart`), not per-device or escrowed; a new
device re-derives the *same* keypair and verifies it against the server pubkey
(`signin.dart`). Same `my_priv` → same room key → both devices decrypt
everything. There is no per-device enrollment (one username = one keypair).

Consequence: **each device keeps its own independent `MessageDb`**, each seeded
from the same server stream, each searchable. They never sync to each other —
the server stream is the shared source. The DB key is per-device (keychain,
never synced). The only inherent limitation — no single-device revocation — is
pre-existing, not introduced here.

---

## 5. Phase 2 — Search

### 5.1 Index

- **FTS5 virtual table** over searchable text: message `body`, attachment
  captions, link-preview titles. Voice memos and call logs carry no text and
  are not indexed.
- Kept in sync with `messages` via triggers (or mirrored writes) on
  insert/update/delete, including soft-deletes (a deleted message leaves the
  index).

### 5.2 Tokenizer & query semantics (MVP)

- **Tokenizer:** `unicode61` with `remove_diacritics=2` → accent-insensitive,
  case-insensitive, fast, small index, full BM25 relevance.
- **Prefix matching:** query as `term*` for as-you-type results (`love*` →
  "lovely"). Define a prefix index for common lengths.
- **Ranking:** **BM25 blended with a recency boost**, so an exact recent
  message outranks an old loose match. Note SQLite `bm25()` returns *negative*
  (most-relevant most-negative) → `ORDER BY (bm25 adjusted by age) ASC`.
- **Highlighting / snippets:** `highlight()` for all-match highlighting in
  results (Signal parity) and `snippet()` for the result preview line.
- **Deferred:** `trigram` tokenizer for mid-word substring + CJK matching — a
  tokenizer swap, not a re-architecture; flagged for later (it ~3× the index
  and forgoes BM25).

### 5.3 In-channel search UX

- Entry: wire the **existing stubbed 🔍** on `chat_info_page.dart:219` (and/or a
  search affordance in the conversation app bar) — replace the "coming soon"
  toast.
- A search field + results list (snippet + highlight, newest-first within
  relevance). Tap a result → pop to the conversation **scrolled to that
  message**, briefly highlighted.
- **Scroll-to-message:** the list is `reverse: true` with keyed rows
  (`msg-{clientMsgId ?? id}`). Map target id → index and `animateTo`. If the
  target predates what's loaded in memory, load older rows from `MessageDb`
  into the `MessageStore` first, then scroll.

### 5.4 Global search UX

- Entry: a **search field on the chat-rooms list** (`home_screen.dart`).
- Query across all rooms' FTS; results **grouped by room**; tap → open that
  room scrolled to the message (§5.3 mechanism). (Usually one room for a
  couple, but generalizes to named rooms.)

---

## 6. Server-side changes

**None required for the MVP.** The server already supports full-history replay
(`SubscribeFrame(sinceMessageId: null)`), which both seeds the local DB and is
unchanged for delta sync (`sinceMessageId: HWM`). It continues to store and
route opaque ciphertext only.

**Optional scaling follow-up (not this worktree):** backward pagination
(`WHERE id < $X ORDER BY id DESC LIMIT N` + a new `Subscribe`-style frame) to
avoid loading a very large lifetime history into memory in one shot during the
initial seed. Modest for a 1:1 couples app; defer until seed-time memory bites.

---

## 7. Build sequence

1. **`MessageDb` + schema + keychain key + migration scaffold** (`onUpgrade`).
2. **Write-through** at the six ingestion choke-points (§4.4); HWM + tombstone
   persistence; delta-sync subscribe.
3. **Hydrate-on-open**; first-run full-replay seed.
4. **FTS5 index** + triggers.
5. **In-channel search UI** (wire the existing 🔍) + scroll-to-message.
6. **Global search UI** on the rooms list.

Each phase boundary (1–4 = persistence; 5–6 = search) can be its own
implementation plan.

---

## 8. Testing

- **Unit (`MessageDb`):** upsert idempotency; optimistic→server-id reconcile;
  out-of-order read/delete (tombstone re-apply); HWM advance; soft-delete
  leaves FTS clean.
- **FTS query tests:** prefix, accent-insensitivity, BM25+recency ordering,
  `highlight()`/`snippet()` output.
- **Widget tests:** in-channel + global result lists; tap → scroll-to-message
  (including target outside the loaded window).
- **On-device build (required).** A green `flutter test` does **not** prove the
  `sqflite_sqlcipher` native plugin compiles for iOS (CLAUDE.md federated-plugin
  caveat). Build to **Court's iPhone 17 Pro Max** and **the iPhone 13 Pro Max**
  (never Kaitlyn's), one at a time, via `ios-deploy.sh`. Verify search works on
  real history and survives an app restart (unchanged `databaseUUID`).
- **Never run `cargo test` against the dev DB** (`fresh_store()` truncates) —
  use `littlelove_test`. (No Rust changes expected for the MVP.)

---

## 9. Future work (explicitly out of scope here)

- Backward server pagination for huge histories (§6).
- `trigram` tokenizer for substring / CJK matching (§5.2).
- Fuzzy / typo-tolerant matching.
- Search filters (sender, date range, media type, links-only).
- Searching attachment contents / voice-memo transcription.
