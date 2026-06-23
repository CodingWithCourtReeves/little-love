# Profile page — design

**Date:** 2026-06-23
**Branch:** `worktree-profile-page`
**Status:** Approved (design), pending implementation plan

## Goal

Give each user a profile they control:

1. Upload a profile picture (avatar).
2. Set a **display name** (the friendly name shown in chat), distinct from their
   immutable `@username` handle.
3. A home for personal settings — move the **wallpaper** picker here, show the
   read-only **handle**, and surface **sign out**.

The only person who ever sees your avatar + display name is your partner
(couples app — one room, two people). Everything personal stays **end-to-end
encrypted**: the server never sees your photo or display name in plaintext.

## Non-goals (v1)

- Editable / renameable `username`. The handle stays fixed; the editable name is
  the new display name. (Sidesteps global-uniqueness + propagation.)
- Notification preferences. Deferred to a follow-up (more plumbing than value
  now).
- A crop/rotate editor. Picking a photo auto-squares it; no manual crop UI.
- Group/3-person semantics — out of scope by product definition.

## Core concept: Profile as its own unit

A **Profile** = `{ displayName: String?, avatar: <encrypted blob ref>? }`, owned
by an account, kept **separate** from the immutable `accounts` row. We do **not**
add `display_name` / `avatar` columns to `accounts` — those would be plaintext.

Three representations:

- **Local (yours):** persisted next to `LocalAccount`
  (`app/lib/identity/account_local.dart`). Add `displayName` and a local avatar
  image path. Editing is instant + local-first; sync happens in the background.
- **Server (ciphertext only):** one row per account holding the **latest
  encrypted profile envelope** + the avatar's R2 blob key for download
  authorization. Replaced on each update; pushed to the partner on connect.
- **Partner's copy (yours, decrypted):** a new `ProfileStore` / Riverpod provider
  keyed by account id, holding the decrypted partner display name + avatar so the
  room list, chat header, and chat-info page can render them.

## Data flow

### Setting your profile

```
ProfileScreen edit
  → save locally (LocalAccount.displayName + avatar file)        [instant]
  → if avatar changed: image_picker → downscale+center-crop 512²
      → encrypt with per-file content key → RequestUpload
      → presigned PUT to R2/MinIO (reuses attachment_upload.dart)
  → build profile envelope { displayName, avatarDescriptor }
      → encrypt with the shared room key
  → PublishProfile frame  (client → server)
      → server upserts account_profiles row (ciphertext + blob_key)
      → server relays a Profile frame to the partner if connected
```

`avatarDescriptor` reuses `AttachmentDescriptor`'s shape (blob_key, content_key,
nonce, mime, size, thumb) — the same E2EE descriptor already used for message
attachments.

### Receiving your partner's profile

```
On WS connect: server sends partner's latest Profile frame (durable — like
  presence, but persisted) → client decrypts envelope with room key
  → ProfileStore.upsert(accountId, displayName, avatarDescriptor)
  → lazily downloads + decrypts avatar blob (DownloadGranted flow), caches locally
Live update: partner sends PublishProfile → server relays Profile frame → same path
```

### Pre-pairing edge case

Before pairing there is **no room key and no partner**. A profile set then is
**local-only**; the first WS connection after pairing triggers a
`PublishProfile` (the client tracks a "profile not yet published for this room"
dirty flag). No editing is blocked on pairing.

## Backend changes

- **Migration `0013_profile.sql`** (schema-only, per project rules):
  ```sql
  CREATE TABLE account_profiles (
    account_id  BIGINT      PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    room_id     TEXT        NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    envelope    BYTEA       NOT NULL,   -- ciphertext: {displayName, avatarDescriptor}
    avatar_key  TEXT        REFERENCES attachments(blob_key),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE INDEX account_profiles_room_idx ON account_profiles (room_id);
  ```
  Server only ever reads/writes `envelope` as opaque bytes.
- **WS frames:**
  - `PublishProfile` (client → server): `{ envelope, avatar_key? }`. Validates the
    sender is a member of the room; upserts `account_profiles`; relays to partner.
  - `Profile` (server → client): `{ account_id/user, envelope, avatar_key? }`.
    Sent on connect (partner's latest, if any) and on live update. Mirrors the
    existing presence relay path (`announce_presence_on_connect`).
- Avatar upload itself needs **no new endpoint** — it rides the existing
  `RequestUpload` → `UploadGranted` → presigned-PUT pipeline. The avatar blob is
  committed like any attachment; `account_profiles.avatar_key` records the
  current one for download authorization.

## Flutter changes

- **Model/store:**
  - Extend `LocalAccount` with `displayName` (nullable) + avatar image path;
    bump the on-disk JSON (tolerant of missing fields for existing installs).
  - New `ProfileStore` + provider for the **partner's** decrypted profile,
    keyed by account id, with a username fallback.
  - New `ProfileEnvelope` codec (encrypt/decrypt `{displayName, avatarDescriptor}`
    with the room key) and wiring of the `PublishProfile` / `Profile` frames in
    `frames.dart` + the WS client.
- **Avatar widget:** reusable `Avatar` showing the image when present, else
  **initials on the `accentUser` palette color** as the fallback.
- **Rendering the partner's display name** (the bulk of the wiring): route
  `Room.displayName()`, the conversation header, and the room-list tiles through
  `ProfileStore` with a `username` fallback when no display name is set.
- **ProfileScreen** (new), pushed from tapping **your own avatar, top-left of the
  home/list screen**:
  - Large avatar (tap → `image_picker` → auto-square → upload) + display-name
    field at top.
  - **Wallpaper** section — move the existing gradient/doodles picker
    (`app/lib/wallpaper/`) here; stays local-only via SharedPreferences.
  - **Your handle** — `@username`, read-only, with a "this is how your partner
    found you" note.
  - **Sign out** at the bottom, behind a confirm dialog (wipes the local
    keystore identity / `AccountLocalStore.delete()`).
  - Add a self-avatar entry point (your own `Avatar`) to the home screen app bar.

## Error handling

- **Avatar upload fails:** display name still saves locally + publishes; avatar
  retries on next profile edit or next connect (dirty flag). Surface a quiet
  "couldn't sync photo" state, not a blocking error.
- **Envelope decrypt fails** (e.g. key rotation / corrupt frame): fall back to
  `@username` + initials avatar; log, don't crash.
- **Per-message-status lesson applies:** a `Profile` frame can arrive before the
  partner record is fully reconciled. `ProfileStore` keys by account id and is
  re-applied idempotently, so out-of-order arrival just overwrites with the
  latest `updated_at` — never lost.
- **Sign out:** confirm dialog; on confirm, delete local account + profile +
  cached avatars, return to auth gate.

## Testing

- **Rust:** `account_profiles` upsert + member-authorization on `PublishProfile`
  (a non-member can't publish into a room); connect-time relay sends the
  partner's latest envelope. Use the `littlelove_test` DB, never the dev DB.
- **Dart:** `ProfileEnvelope` encrypt→decrypt round-trip; `ProfileStore` ordering
  (later `updated_at` wins, out-of-order arrival idempotent); `Room.displayName()`
  prefers display name and falls back to `@username`; `LocalAccount` JSON
  back-compat (missing `displayName` loads fine).
- **Widget:** `Avatar` image vs. initials fallback; ProfileScreen edit flow.
- **On-device:** deploy to Court's iPhone 17 Pro Max + the iPhone 13 Pro Max (not
  Kaitlyn's) via `ios-deploy.sh`; verify a set avatar + display name appears on
  the partner phone, survives reconnect, and that `databaseUUID` is unchanged
  (no forced re-signup).

## Build sequence (for the plan)

1. Backend: migration + `PublishProfile`/`Profile` frames + relay + tests.
2. Flutter wire: frame codecs, `ProfileEnvelope`, WS client wiring.
3. Local model: `LocalAccount` extension + `ProfileStore` + `Avatar` widget.
4. Render partner display name + avatar across room list / header / chat-info.
5. ProfileScreen + home app-bar entry point; move wallpaper picker in.
6. Sign out + confirm.
7. On-device verification.
