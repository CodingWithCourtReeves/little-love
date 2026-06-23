# Profile Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each user a profile screen to set an avatar + display name (E2EE, synced to their partner) and house wallpaper, their read-only handle, and sign out.

**Architecture:** A profile is `{displayName, avatar}` owned by an account, kept separate from the immutable `accounts` row. The avatar rides the existing attachment upload pipeline (encrypt → presigned PUT). Display name + avatar descriptor are packed into a JSON envelope, encrypted with the **pairwise room key** the couple already derives for messages, and delivered to the partner via two new WS frames (`PublishProfile` client→server, `Profile` server→client) plus a per-account ciphertext row the server relays on connect — modeled exactly on the existing presence path. The server never sees plaintext.

**Tech Stack:** Rust (axum WS, sqlx/Postgres), Flutter/Dart (Riverpod), existing `RoomKeyCache`/`encryptOutgoing` crypto, existing attachment upload.

## Global Constraints

- **Migrations are schema-only.** No `UPDATE`/`INSERT`/`DELETE`/backfill in migration files. New columns on a non-empty table must be nullable or have a default. (`account_profiles` is a brand-new table, so this is moot for it.)
- **E2EE invariant:** authorize body-borne actions at the apply layer. The server stores only opaque `envelope` ciphertext; it never decodes profile contents.
- **Per-message-status lesson:** a `Profile` frame can arrive before the partner's room/member record reconciles. Key the partner profile by a stable id and re-apply idempotently (latest `updated_at` wins); never drop an update because the row isn't present yet.
- **Tests never touch the dev DB.** Rust tests use the `littlelove_test` database via `fresh_store()`; never the dev `littlelove` DB.
- **Display name vs handle:** `username` stays immutable (used for pairing/lookup). The editable, partner-visible name is `displayName`. Where a display name is absent, fall back to `@username`.
- **Avatar:** auto-squared to 512×512, JPEG; no manual crop UI in v1. Fallback when unset: initials on the `accentUser` palette color.
- **iOS-only MVP.** On-device verification deploys to Court's iPhone 17 Pro Max + the iPhone 13 Pro Max (NOT Kaitlyn's) via `./scripts/ios-deploy.sh`.

---

## File Structure

**Backend (Rust, `server/`)**
- Create `migrations/0013_profile.sql` — `account_profiles` table.
- Create `src/profiles.rs` — `upsert_profile`, `profile_for_account` DB helpers + the `StoredProfile` struct.
- Modify `src/wire.rs` — add `RoomClientFrame::PublishProfile` + `RoomServerFrame::Profile`.
- Modify `src/ws.rs` — dispatch arm + `handle_publish_profile` + send partner profile in `announce_presence_on_connect` (or a sibling `announce_profile_on_connect`).
- Modify `src/lib.rs` (or wherever modules are declared) — `mod profiles;`.

**Frontend (Dart, `app/lib/`)**
- Modify `wire/frames.dart` — `ProfileFrame` (inbound) + `PublishProfileFrame` (outbound).
- Create `profile/profile_envelope.dart` — encode/encrypt + decrypt/decode `{displayName, avatarDescriptor}`.
- Modify `identity/account_local.dart` — add `displayName` + `avatarPath` to `LocalAccount` (JSON back-compat).
- Create `profile/profile_store.dart` — partner-profile state (`ProfileStore` + provider), keyed by username, latest-wins.
- Create `profile/avatar.dart` — `Avatar` widget (image or initials fallback).
- Create `profile/profile_service.dart` — publish-on-change/connect, avatar upload, inbound `Profile` handling.
- Create `screens/profile/profile_screen.dart` — the screen.
- Modify `screens/inbox/home_screen.dart` — self-avatar entry point in the app bar; remove the sign-out popup item (moves into ProfileScreen).
- Modify `inbox/room.dart` — `displayName` takes an optional resolver for partner display names.

---

## Task 1: Backend — `account_profiles` table + DB helpers

**Files:**
- Create: `server/migrations/0013_profile.sql`
- Create: `server/src/profiles.rs`
- Modify: `server/src/lib.rs` (add `mod profiles;` next to the other `mod` lines)
- Test: `server/src/profiles.rs` (`#[cfg(test)]` module, mirroring `attachments.rs` test style)

**Interfaces:**
- Produces:
  - `pub struct StoredProfile { pub envelope: Vec<u8>, pub avatar_key: Option<String>, pub updated_at: DateTime<Utc> }`
  - `pub async fn upsert_profile(pool: &PgPool, account_id: i64, envelope: &[u8], avatar_key: Option<&str>) -> sqlx::Result<()>`
  - `pub async fn profile_for_account(pool: &PgPool, account_id: i64) -> sqlx::Result<Option<StoredProfile>>`

- [ ] **Step 1: Write the migration**

Create `server/migrations/0013_profile.sql`:

```sql
-- server/migrations/0013_profile.sql
-- Per-account E2EE profile (display name + avatar reference). The server stores
-- only opaque ciphertext in `envelope`; it never sees the display name or photo.
-- `avatar_key` references the attachments row holding the encrypted avatar blob,
-- whose download is authorized by room membership (couples share every room).
CREATE TABLE account_profiles (
  account_id  BIGINT      PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  envelope    BYTEA       NOT NULL,
  avatar_key  TEXT        REFERENCES attachments(blob_key),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- [ ] **Step 2: Declare the module**

In `server/src/lib.rs`, add `pub mod profiles;` alongside the existing `pub mod attachments;` line (match the existing visibility/ordering).

- [ ] **Step 3: Write the failing test**

Create `server/src/profiles.rs` with only the test module first:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::fresh_store; // same helper attachments.rs tests use

    #[tokio::test]
    async fn upsert_then_read_roundtrips_latest() {
        let store = fresh_store().await;
        let pool = store.pool();
        // Seed an account directly (accounts insert helper used elsewhere in tests).
        let account_id = crate::test_support::seed_account(pool, "alice").await;

        // Absent → None.
        assert!(profile_for_account(pool, account_id).await.unwrap().is_none());

        // Insert.
        upsert_profile(pool, account_id, b"env-1", None).await.unwrap();
        let got = profile_for_account(pool, account_id).await.unwrap().unwrap();
        assert_eq!(got.envelope, b"env-1");
        assert_eq!(got.avatar_key, None);

        // Update replaces envelope + sets avatar_key.
        // (attachments FK: insert an attachment row first so the FK holds.)
        let room_id = crate::test_support::seed_couple_room(pool, account_id).await;
        crate::attachments::insert_attachment(pool, "blob-xyz", &room_id, account_id, 10)
            .await
            .unwrap();
        upsert_profile(pool, account_id, b"env-2", Some("blob-xyz")).await.unwrap();
        let got = profile_for_account(pool, account_id).await.unwrap().unwrap();
        assert_eq!(got.envelope, b"env-2");
        assert_eq!(got.avatar_key.as_deref(), Some("blob-xyz"));
    }
}
```

> NOTE: `seed_account` / `seed_couple_room` — reuse whatever helpers the existing
> `attachments.rs` / `rooms.rs` tests use to create accounts and a room. If no
> named helper exists, inline the same `INSERT INTO accounts (...)` the other
> tests use. Read `server/src/attachments.rs` tests before writing this step and
> match their seeding approach exactly.

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd server && DATABASE_URL=postgres://...littlelove_test cargo test profiles::tests::upsert_then_read_roundtrips_latest`
Expected: FAIL — `upsert_profile` / `profile_for_account` / `StoredProfile` not found.

- [ ] **Step 5: Implement the helpers**

Prepend to `server/src/profiles.rs` (above the test module):

```rust
use chrono::{DateTime, Utc};
use sqlx::PgPool;

#[derive(Debug, Clone)]
pub struct StoredProfile {
    pub envelope: Vec<u8>,
    pub avatar_key: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// Insert or replace the caller's profile. Server stores `envelope` opaquely.
pub async fn upsert_profile(
    pool: &PgPool,
    account_id: i64,
    envelope: &[u8],
    avatar_key: Option<&str>,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO account_profiles (account_id, envelope, avatar_key, updated_at)
         VALUES ($1, $2, $3, now())
         ON CONFLICT (account_id)
         DO UPDATE SET envelope = EXCLUDED.envelope,
                       avatar_key = EXCLUDED.avatar_key,
                       updated_at = now()",
    )
    .bind(account_id)
    .bind(envelope)
    .bind(avatar_key)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn profile_for_account(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Option<StoredProfile>> {
    let row = sqlx::query_as::<_, (Vec<u8>, Option<String>, DateTime<Utc>)>(
        "SELECT envelope, avatar_key, updated_at FROM account_profiles WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(envelope, avatar_key, updated_at)| StoredProfile {
        envelope,
        avatar_key,
        updated_at,
    }))
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd server && DATABASE_URL=...littlelove_test cargo test profiles::tests::upsert_then_read_roundtrips_latest`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add server/migrations/0013_profile.sql server/src/profiles.rs server/src/lib.rs
git commit -m "feat(profile): account_profiles table + upsert/read helpers"
```

---

## Task 2: Backend — `PublishProfile`/`Profile` frames, handler, connect relay

**Files:**
- Modify: `server/src/wire.rs` (add to `RoomClientFrame` ~line 72-135 and `RoomServerFrame` ~line 140-239)
- Modify: `server/src/ws.rs` (dispatch loop ~line 280-330; new `handle_publish_profile`; connect relay near `announce_presence_on_connect` ~line 715)
- Test: `server/src/ws.rs` `#[cfg(test)]` (or the ws integration test module) — publish authorizes + relays; connect sends partner's stored profile.

**Interfaces:**
- Consumes: `upsert_profile`, `profile_for_account` (Task 1); existing `partner_account_id_for`, `partner_username_for` (in `accounts.rs`), `state.routing.deliver`.
- Produces (wire shapes, used by Dart Task 3):
  - Client→server: `PublishProfile { envelope: String, avatar_key: Option<String> }` (envelope is base64 of the ciphertext bytes — keep it a `String` on the wire like message `body`).
  - Server→client: `Profile { user: String, envelope: String, avatar_key: Option<String> }`.

- [ ] **Step 1: Write the failing test**

Add to the ws test module (mirror the existing presence/relay test that drives two authenticated sockets). Pseudocode of the assertion shape:

```rust
#[tokio::test]
async fn publish_profile_relays_to_partner_and_persists() {
    // Pair alice & bob (reuse the pairing test helper used by presence tests).
    let (mut alice, mut bob) = pair_two_clients().await;

    // Alice publishes a profile.
    alice.send_json(json!({
        "kind": "PublishProfile",
        "envelope": "ZW52", // base64("env")
        "avatar_key": null
    })).await;

    // Bob receives a Profile frame naming alice.
    let frame = bob.next_room_frame().await;
    assert_eq!(frame["kind"], "Profile");
    assert_eq!(frame["user"], "alice");
    assert_eq!(frame["envelope"], "ZW52");

    // Persisted: a fresh connection for bob replays alice's profile on connect.
    let mut bob2 = bob.reconnect().await;
    let onconnect = bob2.drain_until_kind("Profile").await;
    assert_eq!(onconnect["user"], "alice");
    assert_eq!(onconnect["envelope"], "ZW52");
}
```

> NOTE: match the actual two-client test harness in `ws.rs` tests (helper names
> like `pair_two_clients`, `next_room_frame` are illustrative — read the existing
> presence test and reuse its exact helpers).

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd server && DATABASE_URL=...littlelove_test cargo test publish_profile_relays_to_partner_and_persists`
Expected: FAIL — unknown frame kind `PublishProfile`.

- [ ] **Step 3: Add the wire variants**

In `server/src/wire.rs`, add to `enum RoomClientFrame` (after `Typing`):

```rust
    /// Publish my E2EE profile (display name + avatar ref). `envelope` is the
    /// base64 ciphertext, sealed with the pairwise room key; the server stores
    /// it opaquely and relays it to my partner.
    PublishProfile {
        envelope: String,
        #[serde(default)]
        avatar_key: Option<String>,
    },
```

Add to `enum RoomServerFrame` (after `Presence`):

```rust
    /// Relayed profile: `user` published a new profile. Delivered to the linked
    /// partner on publish and on connect (latest stored). `envelope` is opaque
    /// base64 ciphertext.
    Profile {
        user: String,
        envelope: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        avatar_key: Option<String>,
    },
```

- [ ] **Step 4: Implement the handler + dispatch + connect relay**

In `server/src/ws.rs` dispatch loop (alongside the other `Ok(RoomClientFrame::...)` arms):

```rust
                Ok(RoomClientFrame::PublishProfile { envelope, avatar_key }) => {
                    handle_publish_profile(&state, &me, &envelope, avatar_key.as_deref(), &tx).await;
                }
```

Add the handler (near `handle_typing`):

```rust
use crate::profiles::{profile_for_account, upsert_profile};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};

/// Persist my profile ciphertext and relay it to my linked partner. Authorized
/// by the `accounts.partner_account_id` link — the same authority presence uses.
async fn handle_publish_profile(
    state: &AppState,
    me: &AccountRecord,
    envelope_b64: &str,
    avatar_key: Option<&str>,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return,
    };
    let envelope = match B64.decode(envelope_b64) {
        Ok(b) => b,
        Err(_) => {
            send_error(tx, "BadCode", "");
            return;
        }
    };
    if let Err(e) = upsert_profile(store.pool(), me.id, &envelope, avatar_key).await {
        warn!("upsert_profile: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    match partner_username_for(store.pool(), me.id).await {
        Ok(Some(partner)) => {
            state
                .routing
                .deliver(
                    &partner,
                    RoomServerFrame::Profile {
                        user: me.username.clone(),
                        envelope: envelope_b64.to_string(),
                        avatar_key: avatar_key.map(str::to_string),
                    },
                )
                .await;
        }
        Ok(None) => {} // not paired yet — stored, relayed when they pair/connect
        Err(e) => warn!("partner_username_for (publish_profile): {e}"),
    }
}
```

In `announce_presence_on_connect` (after it sends the partner-presence frame to `tx`), append a fetch + send of the partner's stored profile:

```rust
    // Also replay my partner's latest profile, if any, to this fresh session.
    if let Ok(Some(partner_id)) = partner_account_id_for(store.pool(), me.id).await {
        if let Ok(Some(p)) = profile_for_account(store.pool(), partner_id).await {
            if let Ok(Some(partner_username)) = partner_username_for(store.pool(), me.id).await {
                let _ = tx.send(RoomServerFrame::Profile {
                    user: partner_username,
                    envelope: B64.encode(&p.envelope),
                    avatar_key: p.avatar_key,
                });
            }
        }
    }
```

> Ensure `partner_account_id_for` is imported in `ws.rs` (the presence code
> already imports `partner_username_for`; add `partner_account_id_for` to the
> `use crate::accounts::{...}` group if not already present).

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd server && DATABASE_URL=...littlelove_test cargo test publish_profile_relays_to_partner_and_persists`
Expected: PASS.

- [ ] **Step 6: Full backend gate**

Run: `cd server && cargo fmt && cargo clippy --all-targets -- -D warnings && DATABASE_URL=...littlelove_test cargo test`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add server/src/wire.rs server/src/ws.rs
git commit -m "feat(profile): PublishProfile/Profile frames, relay + connect replay"
```

---

## Task 3: Dart wire — `ProfileFrame` (in) + `PublishProfileFrame` (out)

**Files:**
- Modify: `app/lib/wire/frames.dart` (inbound parse ~line 201 `case 'Presence'`; inbound class ~line 348; outbound classes ~line 540)
- Test: `app/test/wire/frames_profile_test.dart`

**Interfaces:**
- Produces:
  - `class ProfileFrame extends RoomServerFrame { final String user; final String envelopeB64; final String? avatarKey; }`
  - `class PublishProfileFrame { final String envelopeB64; final String? avatarKey; Map<String,Object?> toJson(); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/wire/frames_profile_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/wire/frames.dart';

void main() {
  test('parses Profile frame', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'Profile',
      'user': 'alice',
      'envelope': 'ZW52',
      'avatar_key': 'blob-1',
    });
    expect(f, isA<ProfileFrame>());
    f as ProfileFrame;
    expect(f.user, 'alice');
    expect(f.envelopeB64, 'ZW52');
    expect(f.avatarKey, 'blob-1');
  });

  test('Profile frame tolerates missing avatar_key', () {
    final f = RoomServerFrame.fromJson(
            {'kind': 'Profile', 'user': 'bob', 'envelope': 'ZW52'})
        as ProfileFrame;
    expect(f.avatarKey, isNull);
  });

  test('PublishProfileFrame serializes', () {
    final json = PublishProfileFrame(envelopeB64: 'ZW52', avatarKey: 'blob-2')
        .toJson();
    expect(json, {
      'kind': 'PublishProfile',
      'envelope': 'ZW52',
      'avatar_key': 'blob-2',
    });
  });
}
```

> NOTE: confirm the package import prefix (`package:llove/...`) by checking an
> existing test in `app/test/wire/`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/wire/frames_profile_test.dart`
Expected: FAIL — `ProfileFrame` / `PublishProfileFrame` undefined.

- [ ] **Step 3: Implement**

In `frames.dart`, add to the `RoomServerFrame.fromJson` switch (after the `'Presence'` case):

```dart
      case 'Profile':
        return ProfileFrame(
          user: json['user']! as String,
          envelopeB64: json['envelope']! as String,
          avatarKey: json['avatar_key'] as String?,
        );
```

Add the inbound class (after `PresenceFrame`):

```dart
/// Relayed partner profile: [user] published a new E2EE profile. [envelopeB64]
/// is opaque ciphertext (decoded + decrypted with the pairwise room key).
class ProfileFrame extends RoomServerFrame {
  const ProfileFrame({
    required this.user,
    required this.envelopeB64,
    this.avatarKey,
  });
  final String user;
  final String envelopeB64;
  final String? avatarKey;
}
```

Add the outbound class (with the other outbound frames, e.g. after `TypingClientFrame`):

```dart
/// Publish my E2EE profile to the server (relayed to my partner). [envelopeB64]
/// is the base64 ciphertext sealed with the pairwise room key.
class PublishProfileFrame {
  const PublishProfileFrame({required this.envelopeB64, this.avatarKey});
  final String envelopeB64;
  final String? avatarKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'PublishProfile',
    'envelope': envelopeB64,
    'avatar_key': avatarKey,
  };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/wire/frames_profile_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/wire/frames.dart app/test/wire/frames_profile_test.dart
git commit -m "feat(profile): Dart Profile/PublishProfile wire frames"
```

---

## Task 4: Dart — `ProfileEnvelope` (encode/encrypt + decrypt/decode)

**Files:**
- Create: `app/lib/profile/profile_envelope.dart`
- Test: `app/test/profile/profile_envelope_test.dart`

**Interfaces:**
- Consumes: `encryptOutgoing(Uint8List key, String plaintext)` / `decryptIncoming(Uint8List key, String wire)` from `pairing/encryption.dart`; `AttachmentDescriptor` from `attachment/attachment_descriptor.dart`.
- Produces:
  - `class ProfileData { final String? displayName; final AttachmentDescriptor? avatar; }`
  - `Future<String> encodeProfileEnvelope(Uint8List roomKey, ProfileData data)` → base64 string for the wire `envelope`.
  - `Future<ProfileData?> decodeProfileEnvelope(Uint8List roomKey, String envelopeB64)` → null when undecryptable.

**Design note:** the envelope's plaintext is JSON `{ "display_name": String?, "avatar": <AttachmentDescriptor.toJson> | null }`. We reuse `encryptOutgoing`, which returns a wire-string body; we base64 that whole wire string so it survives as the frame's `envelope`. `decodeProfileEnvelope` base64-decodes back to the wire string, then `decryptIncoming`.

- [ ] **Step 1: Write the failing test**

Create `app/test/profile/profile_envelope_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/profile/profile_envelope.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

  test('round-trips display name with no avatar', () async {
    final env = await encodeProfileEnvelope(
        key, const ProfileData(displayName: 'Ali 🌹', avatar: null));
    expect(env, isNotEmpty);
    final back = await decodeProfileEnvelope(key, env);
    expect(back!.displayName, 'Ali 🌹');
    expect(back.avatar, isNull);
  });

  test('decode returns null under a wrong key', () async {
    final env = await encodeProfileEnvelope(
        key, const ProfileData(displayName: 'x', avatar: null));
    final wrong = Uint8List.fromList(List<int>.generate(32, (i) => 99 - i));
    expect(await decodeProfileEnvelope(wrong, env), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/profile/profile_envelope_test.dart`
Expected: FAIL — file/symbols missing.

- [ ] **Step 3: Implement**

Create `app/lib/profile/profile_envelope.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import '../attachment/attachment_descriptor.dart';
import '../pairing/encryption.dart';

/// The decrypted contents of a profile envelope.
class ProfileData {
  const ProfileData({required this.displayName, required this.avatar});
  final String? displayName;
  final AttachmentDescriptor? avatar;
}

Map<String, Object?> _toPlain(ProfileData d) => <String, Object?>{
      'display_name': d.displayName,
      'avatar': d.avatar?.toJson(),
    };

/// Seal [data] with the pairwise [roomKey]; returns base64 for the wire.
Future<String> encodeProfileEnvelope(Uint8List roomKey, ProfileData data) async {
  final wire = await encryptOutgoing(roomKey, jsonEncode(_toPlain(data)));
  return base64.encode(utf8.encode(wire));
}

/// Inverse of [encodeProfileEnvelope]. Returns null when undecryptable
/// (wrong/rotated key or corrupt frame) — callers fall back to @username.
Future<ProfileData?> decodeProfileEnvelope(
    Uint8List roomKey, String envelopeB64) async {
  final String wire;
  try {
    wire = utf8.decode(base64.decode(envelopeB64));
  } catch (_) {
    return null;
  }
  final plain = await decryptIncoming(roomKey, wire);
  if (plain == cannotDecryptSentinel) return null;
  final map = jsonDecode(plain) as Map<String, Object?>;
  final avatarJson = map['avatar'] as Map<String, Object?>?;
  return ProfileData(
    displayName: map['display_name'] as String?,
    avatar:
        avatarJson == null ? null : AttachmentDescriptor.fromJson(avatarJson),
  );
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/profile/profile_envelope_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/profile/profile_envelope.dart app/test/profile/profile_envelope_test.dart
git commit -m "feat(profile): E2EE profile envelope codec"
```

---

## Task 5: Dart — extend `LocalAccount` with `displayName` + `avatarPath`

**Files:**
- Modify: `app/lib/identity/account_local.dart`
- Test: `app/test/identity/account_local_profile_test.dart`

**Interfaces:**
- Produces: `LocalAccount` gains `final String? displayName;` and `final String? avatarPath;`, both optional in the constructor; `toJson`/`fromJson` updated; a `copyWith({String? displayName, String? avatarPath})`.
- Back-compat: `fromJson` tolerates missing keys (existing installs have neither).

- [ ] **Step 1: Write the failing test**

Create `app/test/identity/account_local_profile_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/identity/account_local.dart';

void main() {
  LocalAccount base() => LocalAccount(
        username: 'alice',
        ed25519PubBase64: 'e',
        x25519PubBase64: 'x',
        createdAt: DateTime.utc(2026),
      );

  test('defaults are null and survive JSON', () {
    final a = base();
    expect(a.displayName, isNull);
    expect(a.avatarPath, isNull);
    final back = LocalAccount.fromJson(a.toJson());
    expect(back.displayName, isNull);
  });

  test('back-compat: legacy JSON without profile keys loads', () {
    final legacy = {
      'username': 'bob',
      'ed25519_pub': 'e',
      'x25519_pub': 'x',
      'created_at': DateTime.utc(2026).toIso8601String(),
    };
    final a = LocalAccount.fromJson(legacy);
    expect(a.username, 'bob');
    expect(a.displayName, isNull);
  });

  test('copyWith sets fields and they round-trip', () {
    final a = base().copyWith(displayName: 'Ali', avatarPath: '/tmp/a.jpg');
    final back = LocalAccount.fromJson(a.toJson());
    expect(back.displayName, 'Ali');
    expect(back.avatarPath, '/tmp/a.jpg');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/identity/account_local_profile_test.dart`
Expected: FAIL — `displayName`/`avatarPath`/`copyWith` undefined.

- [ ] **Step 3: Implement**

In `account_local.dart`, update the `LocalAccount` class:

```dart
class LocalAccount {
  LocalAccount({
    required this.username,
    required this.ed25519PubBase64,
    required this.x25519PubBase64,
    required this.createdAt,
    this.displayName,
    this.avatarPath,
  });

  final String username;
  final String ed25519PubBase64;
  final String x25519PubBase64;
  final DateTime createdAt;

  /// Editable, partner-visible name. Null → fall back to `@username`.
  final String? displayName;

  /// Local filesystem path to my own avatar image (the squared JPEG). Null when
  /// unset. Not synced as a path — only the encrypted blob ref is shared.
  final String? avatarPath;

  LocalAccount copyWith({String? displayName, String? avatarPath}) =>
      LocalAccount(
        username: username,
        ed25519PubBase64: ed25519PubBase64,
        x25519PubBase64: x25519PubBase64,
        createdAt: createdAt,
        displayName: displayName ?? this.displayName,
        avatarPath: avatarPath ?? this.avatarPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'username': username,
        'ed25519_pub': ed25519PubBase64,
        'x25519_pub': x25519PubBase64,
        'created_at': createdAt.toUtc().toIso8601String(),
        if (displayName != null) 'display_name': displayName,
        if (avatarPath != null) 'avatar_path': avatarPath,
      };

  factory LocalAccount.fromJson(Map<String, Object?> json) => LocalAccount(
        username: json['username']! as String,
        ed25519PubBase64: json['ed25519_pub']! as String,
        x25519PubBase64: json['x25519_pub']! as String,
        createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
        displayName: json['display_name'] as String?,
        avatarPath: json['avatar_path'] as String?,
      );
}
```

> `copyWith` here uses `??` so it can't clear a field to null. That's fine for
> this feature (we only ever set non-null values; clearing an avatar is out of
> v1 scope). If clearing is needed later, switch to a sentinel.

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/identity/account_local_profile_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/identity/account_local.dart app/test/identity/account_local_profile_test.dart
git commit -m "feat(profile): LocalAccount gains displayName + avatarPath"
```

---

## Task 6: Dart — `ProfileStore` for the partner's profile

**Files:**
- Create: `app/lib/profile/profile_store.dart`
- Test: `app/test/profile/profile_store_test.dart`

**Interfaces:**
- Produces:
  - `class PartnerProfile { final String username; final String? displayName; final AttachmentDescriptor? avatar; final DateTime updatedAt; }`
  - `class ProfileStore extends ChangeNotifier { PartnerProfile? forUsername(String u); void apply(PartnerProfile p); }`
  - `final profileStoreProvider = ChangeNotifierProvider<ProfileStore>((_) => ProfileStore());`
- Behavior: `apply` keeps the entry with the **latest `updatedAt`** per username; an older or equal update is ignored (idempotent, out-of-order safe — the per-message-status lesson). `updatedAt` is the client receipt time when the frame is applied (monotonic enough for last-writer-wins within a session; the server's relay order is the tiebreaker across sessions).

- [ ] **Step 1: Write the failing test**

Create `app/test/profile/profile_store_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/profile/profile_store.dart';

void main() {
  PartnerProfile p(String name, DateTime t) =>
      PartnerProfile(username: 'bob', displayName: name, avatar: null, updatedAt: t);

  test('apply stores and reads back by username', () {
    final s = ProfileStore();
    s.apply(p('Bob', DateTime.utc(2026, 1, 1)));
    expect(s.forUsername('bob')!.displayName, 'Bob');
    expect(s.forUsername('nobody'), isNull);
  });

  test('latest updatedAt wins; stale update ignored', () {
    final s = ProfileStore();
    s.apply(p('New', DateTime.utc(2026, 1, 2)));
    s.apply(p('Old', DateTime.utc(2026, 1, 1))); // earlier → ignored
    expect(s.forUsername('bob')!.displayName, 'New');
  });

  test('notifies listeners on real change', () {
    final s = ProfileStore();
    var n = 0;
    s.addListener(() => n++);
    s.apply(p('Bob', DateTime.utc(2026, 1, 1)));
    expect(n, 1);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/profile/profile_store_test.dart`
Expected: FAIL — symbols missing.

- [ ] **Step 3: Implement**

Create `app/lib/profile/profile_store.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';

@immutable
class PartnerProfile {
  const PartnerProfile({
    required this.username,
    required this.displayName,
    required this.avatar,
    required this.updatedAt,
  });
  final String username;
  final String? displayName;
  final AttachmentDescriptor? avatar;
  final DateTime updatedAt;
}

/// Holds the decrypted profile of the partner, keyed by username. Last-writer-
/// wins by [PartnerProfile.updatedAt] so an out-of-order or replayed frame never
/// clobbers a newer one.
class ProfileStore extends ChangeNotifier {
  final Map<String, PartnerProfile> _byUsername = {};

  PartnerProfile? forUsername(String username) => _byUsername[username];

  void apply(PartnerProfile p) {
    final existing = _byUsername[p.username];
    if (existing != null && !p.updatedAt.isAfter(existing.updatedAt)) return;
    _byUsername[p.username] = p;
    notifyListeners();
  }
}

final profileStoreProvider =
    ChangeNotifierProvider<ProfileStore>((_) => ProfileStore());
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/profile/profile_store_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/profile/profile_store.dart app/test/profile/profile_store_test.dart
git commit -m "feat(profile): ProfileStore for partner profile (latest-wins)"
```

---

## Task 7: Dart — `Avatar` widget (image or initials fallback)

**Files:**
- Create: `app/lib/profile/avatar.dart`
- Test: `app/test/profile/avatar_test.dart`

**Interfaces:**
- Produces: `class Avatar extends StatelessWidget { const Avatar({required this.seedText, this.imageFile, this.radius = 20}); }`
  - `seedText`: the name used for both the initial letter and the deterministic accent color (username or display name).
  - `imageFile`: a `File?`; when non-null and exists, shows the image; otherwise initials.

- [ ] **Step 1: Write the failing test**

Create `app/test/profile/avatar_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/profile/avatar.dart';

void main() {
  testWidgets('shows the seed initial when no image', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Avatar(seedText: 'alice')),
    ));
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('empty seed renders without throwing', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Avatar(seedText: '')),
    ));
    expect(find.byType(Avatar), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/profile/avatar_test.dart`
Expected: FAIL — `Avatar` undefined.

- [ ] **Step 3: Implement**

Create `app/lib/profile/avatar.dart`:

```dart
import 'dart:io';
import 'package:flutter/material.dart';

/// Circular avatar: shows [imageFile] when present and readable, else the first
/// letter of [seedText] on a deterministic accent color. Used for self + partner.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.seedText,
    this.imageFile,
    this.radius = 20,
  });

  final String seedText;
  final File? imageFile;
  final double radius;

  static const _accents = <Color>[
    Color(0xFFE57373), Color(0xFF9575CD), Color(0xFF4DB6AC),
    Color(0xFF7986CB), Color(0xFFA1887F), Color(0xFF4FC3F7),
  ];

  Color _color() {
    if (seedText.isEmpty) return _accents.first;
    var h = 0;
    for (final c in seedText.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _accents[h % _accents.length];
  }

  @override
  Widget build(BuildContext context) {
    final file = imageFile;
    if (file != null && file.existsSync()) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
    }
    final initial = seedText.isEmpty ? '?' : seedText[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: _color(),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/profile/avatar_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/profile/avatar.dart app/test/profile/avatar_test.dart
git commit -m "feat(profile): Avatar widget with initials fallback"
```

---

## Task 8: Dart — partner display name in `Room.displayName`

**Files:**
- Modify: `app/lib/inbox/room.dart`
- Test: `app/test/inbox/room_display_name_test.dart`

**Interfaces:**
- Change: `String displayName(String selfUsername, {String Function(String username)? nameFor})`. When `nameFor` is provided, each other member's label is `nameFor(username)`; the default (no resolver, or resolver returns the username unchanged) preserves today's Title-Case behavior. Keeps the existing `name`-override and `'New chat'` empty fallback.

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/room_display_name_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/inbox/room.dart';
import 'package:llove/wire/frames.dart';

void main() {
  Room room() => Room(
        roomId: 'r',
        name: '',
        members: const [
          Member(username: 'alice', ed25519PubBase64: 'e', x25519PubBase64: 'xa'),
          Member(username: 'bob', ed25519PubBase64: 'e', x25519PubBase64: 'xb'),
        ],
        createdAt: DateTime.utc(2026),
      );

  test('falls back to capitalized username with no resolver', () {
    expect(room().displayName('alice'), 'Bob');
  });

  test('uses resolver display name when present', () {
    final r = room();
    String nameFor(String u) => u == 'bob' ? 'Bobby 🐻' : u;
    expect(r.displayName('alice', nameFor: nameFor), 'Bobby 🐻');
  });

  test('named room still wins over resolver', () {
    final r = Room(
      roomId: 'r', name: 'Date Night',
      members: room().members, createdAt: DateTime.utc(2026),
    );
    expect(r.displayName('alice', nameFor: (_) => 'X'), 'Date Night');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/inbox/room_display_name_test.dart`
Expected: FAIL — `displayName` doesn't accept `nameFor`.

- [ ] **Step 3: Implement**

In `room.dart`, replace `displayName`:

```dart
  /// Spec §7.1 derived display name. When `name` is non-empty, returns it
  /// verbatim. Otherwise joins the other members with " + ". [nameFor], when
  /// given, maps a member username to its partner display name (falling back to
  /// the username); without it, members are Title-Cased as before.
  String displayName(String selfUsername, {String Function(String username)? nameFor}) {
    if (name.isNotEmpty) return name;
    final others = members.where((m) => m.username != selfUsername);
    final labels = others
        .map((m) => nameFor != null ? nameFor(m.username) : _capitalize(m))
        .toList()
      ..sort();
    final derived = labels.join(' + ');
    return derived.isEmpty ? 'New chat' : derived;
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/inbox/room_display_name_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the resolver at call sites (no new behavior yet)**

In `home_screen.dart` `_roomList`, build a resolver from the profile store and pass it, so list tiles show display names:

```dart
    final profiles = ref.watch(profileStoreProvider);
    String nameFor(String username) =>
        profiles.forUsername(username)?.displayName ?? username;
    // ...
    Widget item(Room r) => ConversationListItem(
      key: Key('home-room-${r.roomId}'),
      label: r.displayName(_me, nameFor: nameFor),
      // ...
    );
```

Add `import '../../profile/profile_store.dart';` to `home_screen.dart`. (The conversation header gets the same treatment in Task 10's screen wiring; leave it for now if the header derives from `room.displayName` — update it there.)

- [ ] **Step 6: Run the focused tests**

Run: `cd app && flutter test test/inbox/room_display_name_test.dart`
Expected: PASS. (Full analyze/test runs in Task 10's gate.)

- [ ] **Step 7: Commit**

```bash
git add app/lib/inbox/room.dart app/lib/screens/inbox/home_screen.dart app/test/inbox/room_display_name_test.dart
git commit -m "feat(profile): resolve partner display name in Room.displayName"
```

---

## Task 9: Dart — `ProfileService` (publish + receive)

**Files:**
- Create: `app/lib/profile/profile_service.dart`
- Test: `app/test/profile/profile_service_test.dart`

**Interfaces:**
- Consumes: `LiveConnection` (`conn.send(Map)`, `conn.incoming` stream of `RoomServerFrame`), `RoomKeyCache`, `DerivedIdentity`, `uploadCiphertext`, `encodeProfileEnvelope`/`decodeProfileEnvelope`, `ProfileStore`, `AttachmentDescriptor`, `file_crypto` (the same per-file encrypt used by attachments).
- Produces:
  - `Future<void> publishProfile({required LiveConnection conn, required Room coupleRoom, required DerivedIdentity me, required String selfUsername, required ProfileData data, required RoomKeyCache cache})` — derives the pairwise key for the partner member, encodes the envelope, sends `PublishProfileFrame`.
  - `Future<void> handleIncomingProfile(ProfileFrame f, {required Room coupleRoom, required DerivedIdentity me, required String selfUsername, required RoomKeyCache cache, required ProfileStore store, required DateTime receivedAt})` — derives the pairwise key for `f.user`, decodes, applies to the store.

**Design note:** the pairwise key for the envelope is the **same** key `send_fanout.dart` derives: `cache.getOrDeriveFor(roomId: coupleRoom.roomId, peerX25519PubBase64: <partner x25519>, me: me)`. For publish, the peer is the partner member; for receive, the peer is `f.user`'s member. Avatar bytes (Task 10 wires the picker) are uploaded via `uploadCiphertext` to `coupleRoom.roomId`; the resulting `blobKey` becomes both `avatar_key` on the frame and the descriptor's `blobKey` inside the envelope.

- [ ] **Step 1: Write the failing test (envelope round-trip through the service)**

Create `app/test/profile/profile_service_test.dart`. Use a fake `LiveConnection` capturing sent frames; drive publish→handle with two derived identities so the pairwise keys match (reuse the test identities/util used by `send_fanout` tests — read that test first).

```dart
import 'package:flutter_test/flutter_test.dart';
// imports: profile_service, profile_store, room, frames, test crypto helpers

void main() {
  test('publish then handle reproduces display name in the store', () async {
    // 1. Build a couple room with alice (self) + bob (partner), and the two
    //    DerivedIdentity values whose ECDH yields a shared pairwise key.
    // 2. Capture the PublishProfileFrame alice sends (fake conn records send()).
    // 3. Feed it back as a ProfileFrame{user:'alice', envelope, avatar_key} into
    //    bob's handleIncomingProfile.
    // 4. Assert bob's ProfileStore.forUsername('alice').displayName == 'Ali'.
  });
}
```

> Flesh out the four steps with the concrete fakes from `send_fanout`'s test.
> The assertion is the contract: a published display name decodes on the other
> side and lands in the store.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/profile/profile_service_test.dart`
Expected: FAIL — service missing.

- [ ] **Step 3: Implement**

Create `app/lib/profile/profile_service.dart`:

```dart
import '../conversation/room_key_cache.dart';
import '../identity/keypair.dart';
import '../inbox/room.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'profile_envelope.dart';
import 'profile_store.dart';

String? _peerX25519(Room room, String selfUsername) {
  for (final m in room.members) {
    if (m.username != selfUsername) return m.x25519PubBase64;
  }
  return null;
}

/// Seal [data] with the pairwise key and send it to the server (relayed to the
/// partner). Caller has already uploaded the avatar blob and put its key on
/// [data].avatar (and passes the same blobKey as [avatarKey]).
Future<void> publishProfile({
  required LiveConnection conn,
  required Room coupleRoom,
  required DerivedIdentity me,
  required String selfUsername,
  required ProfileData data,
  required RoomKeyCache cache,
  String? avatarKey,
}) async {
  final peer = _peerX25519(coupleRoom, selfUsername);
  if (peer == null) return; // not paired yet — caller retries on next connect
  final key = await cache.getOrDeriveFor(
    roomId: coupleRoom.roomId,
    peerX25519PubBase64: peer,
    me: me,
  );
  final envelope = await encodeProfileEnvelope(key, data);
  conn.send(
    PublishProfileFrame(envelopeB64: envelope, avatarKey: avatarKey).toJson(),
  );
}

/// Decode an inbound partner profile and apply it to [store].
Future<void> handleIncomingProfile(
  ProfileFrame f, {
  required Room coupleRoom,
  required DerivedIdentity me,
  required String selfUsername,
  required RoomKeyCache cache,
  required ProfileStore store,
  required DateTime receivedAt,
}) async {
  final peer = _peerX25519(coupleRoom, selfUsername);
  if (peer == null) return;
  final key = await cache.getOrDeriveFor(
    roomId: coupleRoom.roomId,
    peerX25519PubBase64: peer,
    me: me,
  );
  final data = await decodeProfileEnvelope(key, f.envelopeB64);
  if (data == null) return; // undecryptable — keep @username fallback
  store.apply(PartnerProfile(
    username: f.user,
    displayName: data.displayName,
    avatar: data.avatar,
    updatedAt: receivedAt,
  ));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/profile/profile_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Subscribe to inbound `Profile` frames**

Find where the app fans `RoomServerFrame`s out of the live connection (the same place `MessageFrame`/`PresenceFrame` are handled — grep for `PresenceFrame` under `app/lib/`). Add a branch: on a `ProfileFrame`, call `handleIncomingProfile(...)` with the couple room, the derived identity, `receivedAt: DateTime.now()`, and the `profileStoreProvider` store.

> This wiring is glue; verify it by the on-device test in Task 11 (two phones)
> rather than a unit test, since it depends on the live-connection plumbing.

- [ ] **Step 6: Commit**

```bash
git add app/lib/profile/profile_service.dart app/test/profile/profile_service_test.dart app/lib/<live-frame-router-file>
git commit -m "feat(profile): publish + receive profile over the live connection"
```

---

## Task 10: Dart — `ProfileScreen`, home entry point, wallpaper move, sign out

**Files:**
- Create: `app/lib/screens/profile/profile_screen.dart`
- Modify: `app/lib/screens/inbox/home_screen.dart` (app-bar leading avatar; remove the `signout` popup item — moved into the screen)
- Move into the screen: the wallpaper picker from `app/lib/wallpaper/wallpaper_screen.dart` (embed the existing `WallpaperSelection`/picker widget as a section; do not duplicate its controller)
- Test: `app/test/screens/profile/profile_screen_test.dart` (widget test for the edit + sign-out affordances)

**Interfaces:**
- Consumes: `accountProvider` (self `LocalAccount`), `accountLocalStoreProvider` (persist edits), `profileStoreProvider`, `Avatar`, the existing wallpaper picker widget, `signOut(ref)` (already used by `home_screen._confirmSignOut`), `publishProfile` + avatar upload (Task 9), `image_picker` (already a dependency — used by `_pickMedia`).

- [ ] **Step 1: Write the failing widget test**

Create `app/test/screens/profile/profile_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llove/screens/profile/profile_screen.dart';
// + provider overrides for accountProvider returning a LocalAccount('alice')

void main() {
  testWidgets('shows handle read-only and a sign-out action', (tester) async {
    await tester.pumpWidget(/* ProviderScope(overrides:[...], child: MaterialApp(home: ProfileScreen())) */);
    await tester.pumpAndSettle();
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });
}
```

> Fill the override block using the pattern from an existing screen widget test
> under `app/test/screens/`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/screens/profile/profile_screen_test.dart`
Expected: FAIL — `ProfileScreen` undefined.

- [ ] **Step 3: Implement `ProfileScreen`**

Create `app/lib/screens/profile/profile_screen.dart` — a `ConsumerStatefulWidget` with these sections, top to bottom:

1. **Avatar + display name** — a large `Avatar(seedText: displayName ?? username, imageFile: avatarPath != null ? File(avatarPath) : null, radius: 48)`; tap → `image_picker` (gallery) → square+resize to 512² JPEG → save to app docs, `accountLocalStore.save(account.copyWith(avatarPath: ...))`. A `TextField` for display name (prefill `displayName ?? ''`, hint "Add a display name"); on submit, persist via `copyWith(displayName: ...)`. After either edit, if a couple room exists, encrypt the avatar bytes (reuse `file_crypto` per-file encryption from the attachment flow), `uploadCiphertext(...)` → blobKey, build the `AttachmentDescriptor`, then `publishProfile(...)`. If no couple room yet, set a "pending publish" flag in `SharedPreferences` (`profile.dirty=true`) that the connect path checks.
2. **Wallpaper** — embed the existing wallpaper picker widget as a section (heading "Wallpaper"). Reuse `wallpaperControllerProvider`; do not re-implement.
3. **Your handle** — a read-only tile: `@$username` with subtitle "This is how your partner found you. It can't be changed."
4. **Sign out** — a destructive-styled tile; on tap, show the same confirm dialog text used today and call `signOut(ref)` on confirm. Reuse the exact dialog copy from `home_screen._confirmSignOut`; extract it to a shared helper if convenient, otherwise duplicate the dialog here and delete the home-screen copy in Step 4.

- [ ] **Step 4: Add the home entry point + remove the popup sign-out**

In `home_screen.dart` `AppBar`:
- Set `leading:` to a tappable self-avatar:

```dart
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: GestureDetector(
            key: const Key('home-open-profile'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
            ),
            child: Center(child: Avatar(seedText: _me, radius: 16)),
          ),
        ),
```

- Remove the `PopupMenuButton` `signout` item (and the whole menu if it now has nothing else). Keep `_confirmSignOut`/`signOut` only if reused; otherwise the screen owns sign-out.

Add imports for `ProfileScreen` and `Avatar`.

- [ ] **Step 5: Run to verify it passes**

Run: `cd app && flutter test test/screens/profile/profile_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Full Flutter gate**

Run: `cd app && dart format . && flutter analyze && flutter test`
Expected: no analyzer issues; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/lib/screens/profile/ app/lib/screens/inbox/home_screen.dart app/test/screens/profile/
git commit -m "feat(profile): ProfileScreen with avatar, display name, wallpaper, handle, sign out"
```

---

## Task 11: On-device verification (two phones)

**Files:** none (manual verification per CLAUDE.md device rules).

- [ ] **Step 1: Full CI-parity gate locally**

Run: `cd server && cargo fmt --check && cargo clippy --all-targets -- -D warnings && DATABASE_URL=...littlelove_test cargo test`
Run: `cd app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test`
Expected: all green.

- [ ] **Step 2: Bring up the dev backend with the new migration**

Run: `./scripts/dev-phones.sh` (applies migrations including `0013_profile.sql`; prints `LLOVE_SERVER`). Confirm the migration applied (no startup error).

- [ ] **Step 3: Deploy to both phones (one at a time)**

Run (Court's iPhone 17 Pro Max):
`./scripts/ios-deploy.sh --server <LLOVE_SERVER> --device 0DC6E4DC-B58D-509A-A5B8-FD316A255D89`
Then (iPhone 13 Pro Max):
`./scripts/ios-deploy.sh --server <LLOVE_SERVER> --device F031FD6D-9E3D-5005-918D-BB860CE37C26`
Confirm each ends with "App installed" and an unchanged `databaseUUID` (no forced re-signup). Do NOT deploy to Kaitlyn's phone.

- [ ] **Step 4: Verify the feature on-device**

- Tap the top-left avatar on home → ProfileScreen opens.
- Set a display name + pick a photo on phone A. Confirm phone B's room list + chat header show A's display name and avatar within a moment.
- Force-quit and reopen phone B → A's profile still shows (connect-time replay).
- Confirm the wallpaper picker still works from its new home.
- Confirm `@username` is read-only and sign-out shows the confirm dialog.

- [ ] **Step 5: Commit any fixes, then finish the branch**

Commit on-device fixes as needed. When green on both phones, proceed to the finishing-a-development-branch skill to open the PR.

---

## Self-Review

**Spec coverage:**
- Avatar upload (E2EE) → Tasks 1,2,4,9,10. ✓
- Display name (E2EE, editable) → Tasks 4,5,6,8,9,10. ✓
- Wallpaper moved in → Task 10. ✓
- Read-only handle → Task 10. ✓
- Sign out → Task 10 (reuses existing `signOut`). ✓
- Pre-pairing edge case → Tasks 9 (publish returns early when unpaired) + 10 (dirty flag) + 2 (server stores; relays when paired). ✓
- Partner render across list/header/chat-info → Task 8 (+ header note in Task 10). ✓
- Out-of-order/idempotent (per-message-status lesson) → Task 6 latest-wins. ✓
- Schema-only migration → Task 1 (new table, no data statements). ✓
- Tests off the dev DB; two-phone deploy excluding Kaitlyn's → Tasks 1,2,11. ✓

**Deviations from the spec (intentional, noted):** dropped `room_id` from `account_profiles` (profile is per-account; avatar download authz rides the room-scoped `attachments` row). Sign-out reuses the existing `signOut(ref)` rather than a new path.

**Open glue items flagged for on-device verification rather than unit tests:** the live-connection inbound `Profile` branch (Task 9 Step 5) and the connect-time dirty-flag publish (Task 10 Step 3). These depend on live plumbing; Task 11 Step 4 exercises them.
