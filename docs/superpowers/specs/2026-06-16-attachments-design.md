# Attachments — photo &amp; video (iOS MVP) — Design

**Date:** 2026-06-16
**Status:** Approved design, pre-implementation
**Scope:** Send and receive photo/video attachments in a conversation,
end-to-end encrypted, on iOS.

Mockup: `docs/mocks/attachments.html` (six screens — attach, pick, sending,
image conversation, video conversation, full-screen viewer).

---

## 1. Goal &amp; principles

Let a couple send photos and short videos in a chat, end-to-end encrypted,
with an instant inline preview thumbnail in the conversation and a tap-to-open
full-resolution view.

An attachment is **a normal chat message whose plaintext describes a file**
instead of being a line of text. The large encrypted bytes live in Cloudflare
R2; the small stuff (content key, metadata, inline thumbnail) rides inside the
existing per-recipient encrypted message body. The fan-out, durable outbox, and
WS relay are reused unchanged in shape.

**E2EE invariant:** the server brokers short-lived R2 URLs but never sees the
file content key. R2 stores only opaque ciphertext.

## 2. Platform scope

iOS only (see project decision: iOS-only MVP). No macOS/Windows client work.
This removes the cross-platform video-player problem — iOS uses the native
`video_player` (AVPlayer) and `video_thumbnail`, so poster-frame extraction is
reliable rather than best-effort.

**Flutter packages added (client):**

- `image_picker` — pick photo/video from the Photos library (primary path).
- `file_picker` — pick an arbitrary file (secondary "Choose File" path).
- `image` — downscale images / encode the thumbnail JPEG.
- `video_thumbnail` — extract a video poster frame for the thumbnail.
- `video_player` — play the decrypted video from a local file.

## 3. The content envelope (plaintext layer)

Today the decrypted plaintext is a bare text string. To carry two message kinds
unambiguously, introduce a **versioned content envelope** — the value that gets
per-recipient encrypted by `encryptOutgoing`:

```jsonc
// kind: "text"
{ "v": 1, "kind": "text", "text": "hi" }

// kind: "file"
{ "v": 1, "kind": "file",
  "blob_key": "01J...",            // R2 object key (ULID)
  "content_key": "<base64 32B>",   // per-file XChaCha20-Poly1305 key
  "nonce": "<base64 24B>",         // nonce for the file-bytes ciphertext
  "mime": "image/jpeg",            // or video/mp4, etc.
  "filename": "IMG_1234.jpg",
  "size": 5242880,                 // plaintext byte length
  "width": 4032, "height": 3024,
  "duration_ms": 8200,             // video only, optional
  "thumb": "<base64>"              // encrypted tiny JPEG, key+nonce embedded in-band
}
```

- The file `content_key` is **independent** of the room ECDH key. The server,
  which brokers R2 URLs, never receives it.
- `thumb` is a downscaled JPEG (target ≤180px long edge, ~q50), encrypted with
  its own key+nonce packed in-band, so the preview is self-contained inside the
  message body — no extra fetch to render it. Typical size ~5–15 KB.
- Migration of existing text: all text sends switch to `kind:"text"`. There is
  no persisted history to migrate (alpha; no client persistence guarantee), so
  no backfill is needed.

## 4. Crypto details

- File bytes: XChaCha20-Poly1305 (same AEAD as messages), one random 32-byte
  content key + 24-byte nonce per file. Ciphertext = `cipher || mac`, matching
  the existing `cipher.dart` packing convention.
- `cipher.dart` gains raw-bytes `encryptBytes(Uint8List)` /
  `decryptBytes(Uint8List)` alongside the existing string methods.
- Thumbnail uses the same scheme with its own key/nonce.

**Why this scheme (validated 2026-06-16):** this is the same shape Signal and
WhatsApp use for attachments — encrypt the file once with an ephemeral random
key, upload ciphertext to a blob store, and send the key + a pointer inside the
normal encrypted message. WhatsApp uses AES-CBC + HMAC-SHA256; Matrix uses
AES-CTR + HMAC. We use XChaCha20-Poly1305, a true AEAD, which is *stronger* than
Matrix's AES-CTR construction (whose IV is not covered by the integrity hash —
not IND-CCA2 secure). XChaCha20-Poly1305's 192-bit nonce supports up to ~256 GB
per message with random nonces and no practical nonce-reuse limit, so a single
one-shot encryption over a ≤500 MiB file is well within cryptographic bounds
(the constraint is memory, below — not the cipher).

**One-shot vs. streaming (deliberate, with a known limit):** for the 500 MiB
cap we encrypt/decrypt the whole file in one AEAD operation, matching how
Signal/WhatsApp/Matrix clients historically handled whole attachments. The
tradeoff is memory. To keep the peak bounded, the **blob is uploaded/downloaded
as raw ciphertext bytes** — base64 is used *only* for the small inline
thumbnail and envelope, never for the full file. Peak RAM is therefore ~1×
plaintext + 1× ciphertext (~2× file size, ≈1 GB at the 500 MiB cap), not 3×.

This is comfortable on recent iPhones but is a real watch-point on older
3 GB-RAM devices (iOS jetsam can kill the app near ~1.5 GB). Mitigations:
free the plaintext buffer immediately after encrypt; stream the decrypted
output straight to the cache file. **If on-device testing at 500 MiB shows
memory pressure, drop the cap to 256 MiB** (documented fallback). Raising the
cap further (long 4K video, Telegram-class sizes) requires a **chunked
streaming AEAD** (fixed-size blocks, per-chunk nonce — XChaCha20-Poly1305's
nonce space makes this safe) plus multipart upload; both tracked as the upgrade
path (§10).

## 5. Server changes (Rust / Axum)

### 5.1 `attachments` table (new migration, schema-only)

```sql
CREATE TABLE attachments (
  blob_key            TEXT        PRIMARY KEY,
  room_id             TEXT        NOT NULL REFERENCES rooms(id),
  uploader_account_id BIGINT      NOT NULL REFERENCES accounts(id),
  byte_size           BIGINT      NOT NULL,
  committed           BOOLEAN     NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX attachments_room_idx ON attachments (room_id);
```

This is the authorization source of truth for who may read a blob. Per project
rule, migrations are schema-only — no data statements.

### 5.2 New WS frames (post-Authenticated)

Defined in `wire.rs`, handled in `ws.rs`:

- `RequestUpload { room_id, byte_size }`
  → validate the sender is a member of `room_id` and `byte_size ≤ 500 MiB`;
  mint a `blob_key` (ULID); insert an `attachments` row (`committed=false`);
  return `UploadGranted { blob_key, url, headers, expires_at }` — a presigned
  R2 PUT, ~10 min TTL.
- `RequestDownload { blob_key }`
  → look up the blob's `room_id`; verify the requester is a member of it;
  return `DownloadGranted { blob_key, url, expires_at }` — a presigned R2 GET.
- Error responses reuse the existing `Error { code, message }` frame.

### 5.3 R2 presigning

Use a lightweight presign-only crate — `rusty-s3` or `s3-presign` (both do
SigV4 presigning with no IO/SDK weight); `rust-s3` (`presign_put`/`presign_get`,
ships an R2 example) is the fallback if we want a fuller client. Credentials via
env / Railway secrets: `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`.

**Validated 2026-06-16:**
- R2 presigned URLs are fully S3 SigV4-compatible and support `PUT`, `GET`,
  `HEAD`, `DELETE`. Signing is done client-side with no round-trip to R2.
- **R2 requires path-style URLs** (`<account>.r2.cloudflarestorage.com/<bucket>/<key>`),
  not virtual-host style — set the equivalent of `use_path_style()` on whichever
  crate we pick. This is the most common R2 presigning gotcha.
- Max presign TTL is 7 days (604,800 s); our ~10 min upload / download windows
  are well within range.

### 5.4 Commit on send

When a `Send` whose envelope is `kind:"file"` is persisted, flip the matching
`attachments.committed = true` (keyed by `blob_key`). This is a code-level write
in the WS send handler, not a migration.

### 5.5 Body size cap

Raise `MAX_BODY_BYTES` from 64 KiB to 96 KiB to give the inline thumbnail
headroom while keeping the DoS bound. `MAX_SEND_RECIPIENTS` unchanged.

## 6. Client flow

### 6.1 Send

1. Pick file (`image_picker` / `file_picker`).
2. Read bytes; reject if &gt; 500 MiB with a clear message.
3. Generate content key + nonce; `encryptBytes` the file.
4. Build the thumbnail (downscale image, or `video_thumbnail` poster frame);
   encrypt it.
5. `RequestUpload` over WS → `UploadGranted`.
6. HTTP PUT the ciphertext directly to R2 (progress + cancel + retry).
7. Build the `kind:"file"` envelope; fan out per recipient via the existing
   `buildSendFrame` path; enqueue in the existing outbox; `Send`.

The optimistic local bubble shows the local thumbnail immediately with a
progress ring (mockup screen 3), then the clock/heart status once enqueued and
acked.

### 6.2 Receive

1. `Message` arrives → decrypt body → envelope.
2. `kind:"text"` → text bubble (unchanged). `kind:"file"` → media tile: decrypt
   `thumb` and render the preview instantly.
3. On tap → `RequestDownload` → `DownloadGranted` → HTTP GET ciphertext from R2
   → `decryptBytes` → write plaintext to a `blob_key`-named file in app-support
   cache → show image lightbox or `video_player` (mockup screen 6).
4. The decrypted file is cached on disk by `blob_key` so re-opening is instant.

### 6.3 New client module `app/lib/attachment/`

- `attachment_descriptor.dart` — the envelope type + JSON round-trip + the
  text/file `kind` discrimination used by send/receive.
- `attachment_upload.dart` — encrypt + RequestUpload + PUT + progress.
- `attachment_download.dart` — RequestDownload + GET + decrypt + local cache.
- `send_fanout.dart` / `message_store.dart` switch to encrypt/decrypt the
  envelope rather than a bare string.
- `conversation_page.dart` renders text vs. media tile by `kind`.

## 7. Reliability &amp; outbox

The durable outbox is **unchanged**. The `Send` is enqueued only *after* the
blob upload succeeds, so an outbox row always references a blob that already
exists in R2. An upload that fails before enqueue surfaces as a failed
attachment in the composer with a retry button; nothing half-sent enters the
queue. The existing "remove on echoed `MessageFrame`" drain semantics hold.

## 8. Infra &amp; lifecycle

- R2 bucket provisioned via the existing `infra/cloudflare` Terraform; API token
  scoped to the bucket; secrets set on Railway.
- No CORS config needed — the iOS client uses native HTTP, not a browser origin.
- **Orphan blobs** (upload granted but `Send` never landed) are a documented
  deferral for the 2-person alpha; volume is negligible. A periodic sweep of
  `committed=false AND created_at < now()-N days` rows + R2 deletes is future
  work, not in this iteration.

## 9. Testing

**Server:**
- `RequestUpload` rejects non-members and `byte_size &gt; 500 MiB`.
- `RequestDownload` denies a requester who is not a member of the blob's room
  (cross-room access denied).
- `attachments` migration schema test (mirrors `migration_0006_schema.rs`).

**On-device (manual, iOS):**
- Send + receive a file at/near the 500 MiB cap on a real iPhone; watch peak
  memory. If the app approaches jetsam limits, drop the cap to 256 MiB per §4.

**Crypto (Dart):**
- `encryptBytes`/`decryptBytes` round-trip on binary data.
- Envelope JSON round-trip for both kinds.

**Client:**
- Envelope text-vs-file discrimination; a `kind:"text"` envelope renders as a
  text bubble; a `kind:"file"` envelope renders a media tile with the inline
  thumbnail.

## 10. Non-goals (this iteration)

- Camera capture (picker only).
- Voice memos / voice / video calls.
- Multipart / resumable uploads &gt; 500 MiB (and the chunked streaming AEAD
  that would accompany them).
- Blob reaper / server-side cleanup job.
- Edit/delete of a sent attachment.
- macOS / Windows clients.
- Read receipts on media (follows the existing message-status roadmap).

## 11. UI reference

See `docs/mocks/attachments.html`. Decisions reflected there and approved:
sent media sits in a faint twilight bubble (received on the pale partner
bubble); time + heart status float as a translucent chip over the bottom-right
of the media (iMessage-style) rather than below it; videos show a centered play
overlay + duration chip.

## 12. Architecture validation (sources, 2026-06-16)

The core decisions were checked against current references:

- **Encrypt-once + key-in-message + ciphertext-in-blob-store** is the
  industry-standard E2EE attachment pattern (WhatsApp/Signal).
  — WhatsApp Security Whitepaper:
  https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf
  — Matrix encrypted attachments:
  https://github.com/matrix-org/matrix-encrypt-attachment
- **XChaCha20-Poly1305 for file bytes** — 192-bit nonce, ~256 GB/message,
  random-nonce safe; a true AEAD (stronger than Matrix's AES-CTR).
  — libsodium XChaCha20-Poly1305:
  https://libsodium.gitbook.io/doc/secret-key_cryptography/aead/chacha20-poly1305/xchacha20-poly1305_construction
- **R2 presigned URLs** — S3 SigV4, PUT/GET, 7-day max TTL, path-style required.
  — Cloudflare R2 presigned URLs:
  https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- **Rust presigning crates** — `rusty-s3` / `s3-presign` (presign-only),
  `rust-s3` (has an R2 example).
  — rust-s3: https://crates.io/crates/rust-s3
  — s3-presign: https://crates.io/crates/s3-presign

Open follow-up not re-verified via search (transient outage during research):
current versions of `image_picker` / `video_player` / `video_thumbnail` — these
are the canonical iOS Flutter packages; confirm exact versions at
implementation time.
