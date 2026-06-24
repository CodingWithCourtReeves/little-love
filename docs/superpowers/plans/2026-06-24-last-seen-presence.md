# Last-seen Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a partner is offline, show a Telegram-style "last seen …" line in the conversation header instead of a bare "offline".

**Architecture:** Persist a nullable `accounts.last_seen_at` timestamp, stamped on WebSocket connect and on the user's last disconnect. The existing server→client `Presence` frame gains an optional `last_seen` field, populated when the partner is offline. The Flutter client stores `{online, lastSeen}` per partner and formats the timestamp client-side, refreshing once a minute so the relative label ticks.

**Tech Stack:** Rust (axum, sqlx/Postgres, chrono, serde), Flutter (Riverpod), Postgres.

## Global Constraints

- **Migrations are schema-only.** No `UPDATE`/`INSERT`/`DELETE`/backfill in migration files. The new column is nullable so it ships without a backfill. (CLAUDE.md)
- **Never run `cargo test` against the dev DB.** Tests truncate tables; use the separate `littlelove_test` database. (memory: never-test-against-dev-db)
- **Last-seen is plaintext server metadata**, not E2EE — consistent with how online/offline already works. Message bodies stay E2EE. (spec)
- **Timestamp wire encoding:** `chrono::DateTime<Utc>` (serde → RFC3339 string), matching existing `wire.rs` timestamp fields (`ts`, `expires_at`, `created_at`).
- **Couples app:** every room is exactly the 2 partners; presence is 1:1 and partner-only. (memory: couples-only-rooms)
- Run full CI lint locally before pushing: `cargo fmt`, `cargo clippy`, `dart format`, `flutter analyze`, `flutter test`. (memory: run-full-ci-lint-before-push)

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `server/migrations/0016_last_seen.sql` | Add nullable `accounts.last_seen_at` column | 1 |
| `server/src/accounts.rs` | `touch_last_seen()` (write now()), `last_seen_for()` (read) | 2 |
| `server/src/wire.rs` | Add `last_seen: Option<DateTime<Utc>>` to `Presence` frame | 3 |
| `server/src/ws.rs` | Stamp last_seen on connect/disconnect; deliver partner's last_seen | 4 |
| `app/lib/wire/frames.dart` | `PresenceFrame.lastSeen` + parse `last_seen` | 5 |
| `app/lib/conversation/presence_state.dart` | `PartnerPresence{online,lastSeen}` + provider | 6 |
| `app/lib/conversation/last_seen_label.dart` | Pure formatter: timestamp → Telegram-style label | 7 |
| `app/lib/conversation/room_message_router.dart` | Pass lastSeen into the notifier | 8 |
| `app/lib/conversation/conversation_page.dart` | `_PartnerStatusLine` renders label; 1-min refresh | 9 |

---

## Task 1: Migration — add `last_seen_at` column

**Files:**
- Create: `server/migrations/0016_last_seen.sql`

**Interfaces:**
- Produces: `accounts.last_seen_at timestamptz NULL`

- [ ] **Step 1: Write the migration**

Create `server/migrations/0016_last_seen.sql`:

```sql
-- Last time an account had an active WebSocket session, stamped on connect and
-- on the account's last disconnect. Nullable: an account that has never
-- connected (or connected before this column existed) has no value, and the
-- client renders a graceful fallback. Schema-only — no backfill.
ALTER TABLE accounts ADD COLUMN last_seen_at timestamptz;
```

- [ ] **Step 2: Apply migrations against the test DB and confirm it runs**

Migrations run automatically when the store initializes. Confirm the file is well-formed by building (sqlx macros are not used here, so a `cargo build` is enough to catch nothing migration-specific; the real check is Task 2's test, which boots a store and runs migrations).

Run: `cargo build -p server` (or `cargo build` from `server/`)
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add server/migrations/0016_last_seen.sql
git commit -m "feat(db): add accounts.last_seen_at column"
```

---

## Task 2: Server store fns — write & read last_seen

**Files:**
- Modify: `server/src/accounts.rs` (add two fns near `partner_username_for`, ~line 122)
- Test: `server/src/accounts.rs` (a `#[cfg(test)]` test, or the crate's existing integration test module — match where account fns are currently tested)

**Interfaces:**
- Consumes: `accounts.last_seen_at` column (Task 1); `sqlx::PgPool`.
- Produces:
  - `pub async fn touch_last_seen(pool: &PgPool, account_id: i64) -> sqlx::Result<()>`
  - `pub async fn last_seen_for(pool: &PgPool, account_id: i64) -> sqlx::Result<Option<DateTime<Utc>>>`

- [ ] **Step 1: Write the failing test**

Find where `accounts.rs` fns are tested. If there's an existing test that creates an account against `littlelove_test` (look for a `fresh_store()` / test helper used by other account tests), mirror it. Add:

```rust
#[tokio::test]
async fn touch_and_read_last_seen() {
    let store = crate::test_support::fresh_store().await; // match the existing helper name
    let pool = store.pool();
    let id = /* create an account via the existing test helper */;

    // No session yet → null.
    assert!(last_seen_for(pool, id).await.unwrap().is_none());

    touch_last_seen(pool, id).await.unwrap();
    let t1 = last_seen_for(pool, id).await.unwrap().expect("stamped");

    touch_last_seen(pool, id).await.unwrap();
    let t2 = last_seen_for(pool, id).await.unwrap().unwrap();
    assert!(t2 >= t1, "second touch is not earlier");
}
```

> If no account-creation test helper exists, reuse the one the existing `partner_username_for` / account tests use. Do not hand-roll account inserts.

- [ ] **Step 2: Run the test to verify it fails**

Run (from `server/`, pointed at the test DB):
`DATABASE_URL=postgres://localhost/littlelove_test cargo test touch_and_read_last_seen -- --nocapture`
Expected: FAIL — `touch_last_seen` / `last_seen_for` not found.

- [ ] **Step 3: Implement the two fns**

In `server/src/accounts.rs`, ensure `use chrono::{DateTime, Utc};` is present (add if missing), then add after `partner_username_for` (~line 122):

```rust
/// Stamp `accounts.last_seen_at = now()` for `account_id`. Called when a
/// WebSocket session opens and when the account's last session closes, so the
/// partner can see "last seen …" while this account is offline.
pub async fn touch_last_seen(pool: &PgPool, account_id: i64) -> sqlx::Result<()> {
    sqlx::query("UPDATE accounts SET last_seen_at = now() WHERE id = $1")
        .bind(account_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Read `accounts.last_seen_at` for `account_id`. `None` if the account has
/// never had a session (column is NULL).
pub async fn last_seen_for(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Option<DateTime<Utc>>> {
    let row: Option<(Option<DateTime<Utc>>,)> =
        sqlx::query_as("SELECT last_seen_at FROM accounts WHERE id = $1")
            .bind(account_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(t,)| t))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DATABASE_URL=postgres://localhost/littlelove_test cargo test touch_and_read_last_seen`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/accounts.rs
git commit -m "feat(server): touch_last_seen / last_seen_for account helpers"
```

---

## Task 3: Wire frame — add optional `last_seen` to Presence

**Files:**
- Modify: `server/src/wire.rs` (the `Presence` variant, ~line 275)
- Modify: `server/src/ws.rs` (the 3 `RoomServerFrame::Presence { … }` construction sites — add `last_seen: None` so the crate compiles; real values come in Task 4)
- Test: `server/src/wire.rs` (`#[cfg(test)]` serde test, alongside the existing wire tests ~line 435/632)

**Interfaces:**
- Consumes: `chrono::DateTime<Utc>` (already imported in `wire.rs`).
- Produces: `RoomServerFrame::Presence { user: String, online: bool, last_seen: Option<DateTime<Utc>> }`. JSON key is `last_seen`; omitted when `None`.

- [ ] **Step 1: Write the failing serde test**

In `wire.rs` tests, add:

```rust
#[test]
fn presence_serializes_last_seen() {
    // Offline with a timestamp → key present.
    let t: DateTime<Utc> = "2026-06-24T17:00:00Z".parse().unwrap();
    let off = RoomServerFrame::Presence {
        user: "court".into(),
        online: false,
        last_seen: Some(t),
    };
    let j = serde_json::to_value(&off).unwrap();
    assert_eq!(j["kind"], "Presence");
    assert_eq!(j["online"], false);
    assert_eq!(j["last_seen"], "2026-06-24T17:00:00Z");

    // Online → key omitted entirely.
    let on = RoomServerFrame::Presence {
        user: "court".into(),
        online: true,
        last_seen: None,
    };
    let j = serde_json::to_value(&on).unwrap();
    assert!(j.get("last_seen").is_none(), "last_seen must be omitted when None");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p server presence_serializes_last_seen`
Expected: FAIL — `Presence` has no field `last_seen`.

- [ ] **Step 3: Add the field**

In `server/src/wire.rs`, change the `Presence` variant (~line 275) to:

```rust
    /// Partner presence: `user` is now online or offline. Server-authoritative —
    /// derived from the partner's authenticated WS sessions; clients never send
    /// this, and it is delivered only to the user's linked partner. Not
    /// persisted; a fresh connection learns current state on connect.
    /// `last_seen` is the partner's last-session timestamp, sent only when
    /// `online: false` (omitted otherwise).
    Presence {
        user: String,
        online: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last_seen: Option<DateTime<Utc>>,
    },
```

- [ ] **Step 4: Make the crate compile — add `last_seen: None` at all 3 ws.rs sites**

In `server/src/ws.rs` there are three `RoomServerFrame::Presence { … }` literals (connect: deliver-to-partner ~1163 and send-to-self ~1170; disconnect: deliver-to-partner ~1204). Add `last_seen: None,` to each for now (Task 4 replaces two of them with real values):

```rust
RoomServerFrame::Presence {
    user: me.username.clone(),
    online: true,
    last_seen: None,
},
```
(apply the analogous one-line addition to all three)

- [ ] **Step 5: Run the test + build to verify pass**

Run: `cargo test -p server presence_serializes_last_seen && cargo build -p server`
Expected: test PASS, build clean.

- [ ] **Step 6: Commit**

```bash
git add server/src/wire.rs server/src/ws.rs
git commit -m "feat(wire): add optional last_seen to Presence frame"
```

---

## Task 4: Server wiring — stamp & deliver last_seen

**Files:**
- Modify: `server/src/ws.rs` — `announce_presence_on_connect` (~1142) and `announce_presence_on_disconnect` (~1190)
- Test: server integration test exercising connect/disconnect presence (mirror the existing presence/typing integration test; find it via `grep -rn "Presence" server/src server/tests`)

**Interfaces:**
- Consumes: `touch_last_seen`, `last_seen_for`, `partner_account_id_for` (existing), `partner_username_for` (existing).
- Behavior produced:
  - On connect: `touch_last_seen(me)`; the self-directed `Presence` for an **offline** partner carries that partner's `last_seen_for`.
  - On last disconnect: `touch_last_seen(me)`; the partner-directed offline `Presence` carries `me`'s freshly stamped `last_seen`.

- [ ] **Step 1: Write the failing integration test**

Mirror the existing presence integration test. Two assertions:

```rust
#[tokio::test]
async fn offline_partner_presence_includes_last_seen() {
    // A and B are paired. A connects then disconnects (stamping last_seen).
    // Then B connects; B's connect-time Presence{user:A, online:false} must
    // carry a last_seen (Some).
    // ...set up paired accounts A,B via existing test harness...

    // A connects and disconnects.
    let a = connect_ws(&app, &a_token).await;
    drop(a); // or send close; wait for server to process disconnect

    // B connects, collect frames.
    let mut b = connect_ws(&app, &b_token).await;
    let presence = next_presence_for(&mut b, "A").await; // helper: find Presence{user:"A"}
    assert_eq!(presence.online, false);
    assert!(presence.last_seen.is_some(), "offline partner presence carries last_seen");
}

#[tokio::test]
async fn online_partner_presence_has_no_last_seen() {
    // A online; B connects → Presence{user:A, online:true, last_seen:None}.
    // Also: A connecting while B is online → B receives
    // Presence{user:A, online:true} with last_seen None.
}
```

> Match the real test harness: reuse whatever helper the existing presence test uses to open a WS, send the handshake, and read frames. Do not invent a new harness.

- [ ] **Step 2: Run to verify it fails**

Run: `DATABASE_URL=postgres://localhost/littlelove_test cargo test offline_partner_presence_includes_last_seen`
Expected: FAIL — `presence.last_seen` is `None` (server still sends `None` everywhere).

- [ ] **Step 3: Implement connect-side stamping + delivery**

In `announce_presence_on_connect` (`ws.rs` ~1142), after resolving `store` and `partner`, stamp self and read the partner's last_seen for the offline case:

```rust
    // Stamp our own last-seen as soon as a session opens, so a value always
    // exists for the partner to read once we go offline.
    if let Err(e) = touch_last_seen(store.pool(), me.id).await {
        warn!("touch_last_seen (connect): {e}");
    }

    state
        .routing
        .deliver(
            &partner,
            RoomServerFrame::Presence {
                user: me.username.clone(),
                online: true,
                last_seen: None, // we just came online
            },
        )
        .await;

    let partner_online = state.routing.is_online(&partner).await;
    // When the partner is offline, attach their last-seen so this fresh session
    // can render "last seen …" immediately.
    let partner_last_seen = if partner_online {
        None
    } else if let Ok(Some(pid)) = partner_account_id_for(store.pool(), me.id).await {
        last_seen_for(store.pool(), pid).await.unwrap_or(None)
    } else {
        None
    };
    let _ = tx.send(RoomServerFrame::Presence {
        user: partner.clone(),
        online: partner_online,
        last_seen: partner_last_seen,
    });
```

Add the needed imports at the top of `ws.rs` (extend the existing `accounts::{…}` / `rooms::{…}` use): `touch_last_seen`, `last_seen_for`, and ensure `partner_account_id_for` is in scope (it already is — used at ~1177).

- [ ] **Step 4: Implement disconnect-side stamping + delivery**

In `announce_presence_on_disconnect` (`ws.rs` ~1190), after the `is_online` early-return and resolving `store`, stamp self then read it back for the broadcast:

```rust
    // We're truly offline now (no other sessions). Stamp last-seen and tell the
    // partner, carrying the timestamp so they see "last seen just now".
    if let Err(e) = touch_last_seen(store.pool(), me.id).await {
        warn!("touch_last_seen (disconnect): {e}");
    }
    let last_seen = last_seen_for(store.pool(), me.id).await.unwrap_or(None);

    match partner_username_for(store.pool(), me.id).await {
        Ok(Some(partner)) => {
            state
                .routing
                .deliver(
                    &partner,
                    RoomServerFrame::Presence {
                        user: me.username.clone(),
                        online: false,
                        last_seen,
                    },
                )
                .await;
        }
        Ok(None) => {}
        Err(e) => warn!("partner_username_for (disconnect): {e}"),
    }
```

- [ ] **Step 5: Run tests to verify pass**

Run: `DATABASE_URL=postgres://localhost/littlelove_test cargo test offline_partner_presence_includes_last_seen online_partner_presence_has_no_last_seen`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cargo fmt && cargo clippy -p server --all-targets
git add server/src/ws.rs
git commit -m "feat(server): stamp and deliver last_seen on connect/disconnect"
```

---

## Task 5: Frontend frame — parse `last_seen`

**Files:**
- Modify: `app/lib/wire/frames.dart` (`PresenceFrame` ~386; parser `case 'Presence'` ~201)
- Test: `app/test/wire/frames_test.dart` (match existing frame-parse test location; `grep -rln "PresenceFrame\|parseRoomServerFrame" app/test`)

**Interfaces:**
- Consumes: JSON `{"kind":"Presence","user":..,"online":..,"last_seen":"<rfc3339>"?}`.
- Produces: `PresenceFrame { String user; bool online; DateTime? lastSeen; }` (`lastSeen` is UTC parsed, `null` when key absent).

- [ ] **Step 1: Write the failing test**

```dart
test('Presence parses last_seen when present, null when absent', () {
  final off = RoomServerFrame.fromJson({
    'kind': 'Presence',
    'user': 'court',
    'online': false,
    'last_seen': '2026-06-24T17:00:00Z',
  }) as PresenceFrame;
  expect(off.online, false);
  expect(off.lastSeen, DateTime.utc(2026, 6, 24, 17));

  final on = RoomServerFrame.fromJson({
    'kind': 'Presence',
    'user': 'court',
    'online': true,
  }) as PresenceFrame;
  expect(on.lastSeen, isNull);
});
```

> Use the actual parse entrypoint name from `frames.dart` (the `case 'Presence'` lives inside it — confirm whether it's `RoomServerFrame.fromJson` or similar and match it).

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/wire/frames_test.dart`
Expected: FAIL — `lastSeen` getter not defined.

- [ ] **Step 3: Implement**

In `frames.dart`, update `PresenceFrame` (~386):

```dart
class PresenceFrame extends RoomServerFrame {
  const PresenceFrame({required this.user, required this.online, this.lastSeen});
  final String user;
  final bool online;

  /// Partner's last-session time, sent only when [online] is false. UTC.
  final DateTime? lastSeen;
}
```

And the parser (`case 'Presence'` ~201):

```dart
      case 'Presence':
        final ls = json['last_seen'] as String?;
        return PresenceFrame(
          user: json['user']! as String,
          online: (json['online'] as bool?) ?? false,
          lastSeen: ls == null ? null : DateTime.parse(ls),
        );
```

(`DateTime.parse` of an RFC3339 `Z` string yields a UTC `DateTime`.)

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/wire/frames_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/wire/frames.dart app/test/wire/frames_test.dart
git commit -m "feat(app): parse last_seen on PresenceFrame"
```

---

## Task 6: Frontend state — `PartnerPresence`

**Files:**
- Modify: `app/lib/conversation/presence_state.dart`
- Test: `app/test/conversation/presence_state_test.dart` (create if absent)

**Interfaces:**
- Produces:
  - `class PartnerPresence { final bool online; final DateTime? lastSeen; const PartnerPresence({required this.online, this.lastSeen}); }`
  - `presenceProvider` now `NotifierProvider.family<PresenceNotifier, PartnerPresence, String>`
  - `PresenceNotifier.set(bool online, {DateTime? lastSeen})`
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

```dart
test('PresenceNotifier holds online + lastSeen, defaults offline/null', () {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  expect(c.read(presenceProvider('court')).online, false);
  expect(c.read(presenceProvider('court')).lastSeen, isNull);

  final t = DateTime.utc(2026, 6, 24, 17);
  c.read(presenceProvider('court').notifier).set(false, lastSeen: t);
  expect(c.read(presenceProvider('court')).online, false);
  expect(c.read(presenceProvider('court')).lastSeen, t);

  c.read(presenceProvider('court').notifier).set(true);
  expect(c.read(presenceProvider('court')).online, true);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/presence_state_test.dart`
Expected: FAIL — `PartnerPresence` / `.set` undefined.

- [ ] **Step 3: Implement**

Replace `presence_state.dart` contents:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A partner's presence: whether they're online, and (when offline) the time of
/// their last session. Server-authoritative and transient — defaults to offline
/// with no last-seen until the server says otherwise (on connect or change).
class PartnerPresence {
  const PartnerPresence({required this.online, this.lastSeen});
  final bool online;
  final DateTime? lastSeen;
}

class PresenceNotifier extends FamilyNotifier<PartnerPresence, String> {
  @override
  PartnerPresence build(String username) =>
      const PartnerPresence(online: false);

  /// Apply a server Presence frame. `lastSeen` is meaningful only when offline.
  void set(bool online, {DateTime? lastSeen}) =>
      state = PartnerPresence(online: online, lastSeen: lastSeen);
}

final presenceProvider =
    NotifierProvider.family<PresenceNotifier, PartnerPresence, String>(
      PresenceNotifier.new,
    );
```

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/presence_state_test.dart`
Expected: PASS. (Compile errors in `room_message_router.dart` / `conversation_page.dart` are expected until Tasks 8–9 — those files still call the old API. Run this single test file only.)

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/presence_state.dart app/test/conversation/presence_state_test.dart
git commit -m "feat(app): PartnerPresence state with lastSeen"
```

---

## Task 7: Frontend formatter — Telegram-style label

**Files:**
- Create: `app/lib/conversation/last_seen_label.dart`
- Test: `app/test/conversation/last_seen_label_test.dart`

**Interfaces:**
- Produces: `String lastSeenLabel(DateTime lastSeen, {required DateTime now})` — returns the offline status text (without a leading dot). `now` is injectable for tests; callers pass `DateTime.now()`. Inputs may be UTC; the fn compares in local time.

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/conversation/last_seen_label.dart';

void main() {
  // Use local wall-clock anchors so the "today/yesterday" calendar logic is
  // deterministic regardless of the test machine's zone.
  final now = DateTime(2026, 6, 24, 15, 0); // Wed 3:00 PM local

  test('under a minute → just now', () {
    expect(lastSeenLabel(now.subtract(const Duration(seconds: 30)), now: now),
        'last seen just now');
  });
  test('minutes ago', () {
    expect(lastSeenLabel(now.subtract(const Duration(minutes: 1)), now: now),
        'last seen 1 minute ago');
    expect(lastSeenLabel(now.subtract(const Duration(minutes: 5)), now: now),
        'last seen 5 minutes ago');
  });
  test('earlier today → today at time', () {
    final t = DateTime(2026, 6, 24, 9, 14); // same calendar day, >1h ago
    expect(lastSeenLabel(t, now: now), 'last seen today at 9:14 AM');
  });
  test('previous day → yesterday at time', () {
    final t = DateTime(2026, 6, 23, 21, 14);
    expect(lastSeenLabel(t, now: now), 'last seen yesterday at 9:14 PM');
  });
  test('within the past week → weekday at time', () {
    final t = DateTime(2026, 6, 21, 21, 14); // Sun
    expect(lastSeenLabel(t, now: now), 'last seen Sunday at 9:14 PM');
  });
  test('older than a week → date', () {
    final t = DateTime(2026, 6, 10, 21, 14);
    expect(lastSeenLabel(t, now: now), 'last seen 06/10/2026');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/last_seen_label_test.dart`
Expected: FAIL — file/function does not exist.

- [ ] **Step 3: Implement**

Create `app/lib/conversation/last_seen_label.dart`:

```dart
/// Telegram-style "last seen …" text for an offline partner. Pure function:
/// pass `now` so it is deterministic and testable. Compares in local time.
String lastSeenLabel(DateTime lastSeen, {required DateTime now}) {
  final seen = lastSeen.toLocal();
  final n = now.toLocal();
  final diff = n.difference(seen);

  if (diff.inMinutes < 1) return 'last seen just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return 'last seen $m ${m == 1 ? 'minute' : 'minutes'} ago';
  }

  final today = DateTime(n.year, n.month, n.day);
  final seenDay = DateTime(seen.year, seen.month, seen.day);
  final daysApart = today.difference(seenDay).inDays;
  final time = _time(seen);

  if (daysApart == 0) return 'last seen today at $time';
  if (daysApart == 1) return 'last seen yesterday at $time';
  if (daysApart < 7) return 'last seen ${_weekday(seen.weekday)} at $time';

  final mm = seen.month.toString().padLeft(2, '0');
  final dd = seen.day.toString().padLeft(2, '0');
  return 'last seen $mm/$dd/${seen.year}';
}

String _time(DateTime t) {
  final h24 = t.hour;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  var h = h24 % 12;
  if (h == 0) h = 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m $ampm';
}

String _weekday(int w) => const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][w - 1];
```

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/last_seen_label_test.dart`
Expected: PASS (all 6).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/last_seen_label.dart app/test/conversation/last_seen_label_test.dart
git commit -m "feat(app): Telegram-style last-seen label formatter"
```

---

## Task 8: Frontend router — pass lastSeen into the notifier

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart` (`case PresenceFrame` ~103-110)

**Interfaces:**
- Consumes: `PresenceFrame.lastSeen` (Task 5), `PresenceNotifier.set` (Task 6).

- [ ] **Step 1: Update the PresenceFrame case**

Change the `PresenceFrame` case to forward both fields:

```dart
    case PresenceFrame(:final user, :final online, :final lastSeen):
      // Server-authoritative partner online/offline + last-seen.
      ref.read(presenceProvider(user).notifier).set(online, lastSeen: lastSeen);
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd app && flutter analyze lib/conversation/room_message_router.dart`
Expected: no errors. (Full-app analyze still flags `conversation_page.dart` until Task 9.)

- [ ] **Step 3: Commit**

```bash
git add app/lib/conversation/room_message_router.dart
git commit -m "feat(app): route last_seen into presence state"
```

---

## Task 9: UI — render last-seen with a 1-minute refresh

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (`_PartnerStatusLine` ~1780-1836)
- Test: `app/test/conversation/partner_status_line_test.dart` (widget test; create if absent — match existing conversation widget-test setup)

**Interfaces:**
- Consumes: `presenceProvider` → `PartnerPresence` (Task 6), `lastSeenLabel` (Task 7).
- Behavior: offline + `lastSeen != null` → `last seen …`; offline + null → `offline`; online → `online`; typing → unchanged. Label recomputed ~once a minute while mounted.

- [ ] **Step 1: Write the failing widget test**

```dart
testWidgets('shows last-seen text when partner offline with timestamp',
    (tester) async {
  final t = DateTime.now().subtract(const Duration(minutes: 5));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // seed presence: offline, 5 min ago
    ],
    child: /* MaterialApp wrapping _PartnerStatusLine(roomId: 'r', partner: 'court') */,
  ));
  // set state via the container before/after pump as the existing widget tests do
  expect(find.textContaining('last seen 5 minutes ago'), findsOneWidget);
});

testWidgets('shows "offline" when no last-seen timestamp', (tester) async {
  // presence: offline, lastSeen null → 'offline'
  expect(find.text('offline'), findsOneWidget);
});
```

> Match how the repo's existing conversation widget tests seed Riverpod state and pump the page. If `_PartnerStatusLine` is private, test through the public conversation page or temporarily expose via `@visibleForTesting`, following existing conventions in that test dir.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/partner_status_line_test.dart`
Expected: FAIL — still renders `offline` for the timestamped case.

- [ ] **Step 3: Convert `_PartnerStatusLine` to stateful for the 1-min tick + render the label**

Replace `_PartnerStatusLine` (the idle/presence branch) so it (a) watches `PartnerPresence`, (b) computes the label via `lastSeenLabel`, (c) ticks every minute. Convert to a `ConsumerStatefulWidget` so it can hold the timer:

```dart
class _PartnerStatusLine extends ConsumerStatefulWidget {
  const _PartnerStatusLine({required this.roomId, required this.partner});
  final String roomId;
  final String? partner;

  @override
  ConsumerState<_PartnerStatusLine> createState() => _PartnerStatusLineState();
}

class _PartnerStatusLineState extends ConsumerState<_PartnerStatusLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Recompute the relative label once a minute so "5 minutes ago" advances.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = ref.watch(typingProvider(widget.roomId));
    if (typing) {
      return Row(
        key: const Key('typing-indicator'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'typing',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w500,
              color: context.palette.accentSage,
            ),
          ),
          const SizedBox(width: 5),
          const _PulsingDots(),
        ],
      );
    }
    if (widget.partner == null) return const SizedBox.shrink();

    final presence = ref.watch(presenceProvider(widget.partner!));
    final online = presence.online;
    final tone =
        online ? context.palette.accentSage : context.palette.textMuted;

    final String label;
    if (online) {
      label = 'online';
    } else if (presence.lastSeen != null) {
      label = lastSeenLabel(presence.lastSeen!, now: DateTime.now());
    } else {
      label = 'offline';
    }

    return Row(
      key: const Key('presence-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            letterSpacing: 0.3,
            fontWeight: FontWeight.w500,
            color: tone,
          ),
        ),
      ],
    );
  }
}
```

Add imports at the top of `conversation_page.dart` if missing: `dart:async` (Timer) and `last_seen_label.dart`. Confirm the call site constructing `_PartnerStatusLine` is unchanged (same named params).

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/partner_status_line_test.dart`
Expected: PASS.

- [ ] **Step 5: Full lint + test gate**

Run:
```bash
cd app && dart format lib test && flutter analyze && flutter test
```
Expected: formatted, analyze clean, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/partner_status_line_test.dart
git commit -m "feat(app): render Telegram-style last-seen in status line"
```

---

## Final verification (whole feature)

- [ ] Server: `cargo fmt && cargo clippy --all-targets && DATABASE_URL=postgres://localhost/littlelove_test cargo test`
- [ ] App: `cd app && dart format lib test && flutter analyze && flutter test`
- [ ] On-device smoke test per CLAUDE.md: deploy with `./scripts/ios-deploy.sh --server <dev url>` to **both** physical phones (Court's iPhone 17 Pro Max + iPhone 13 Pro Max, not Kaitlyn's), one at a time. With partner B's app closed, confirm A's header shows `last seen …`; bring B online → `online`; type → `typing…`. (A `flutter test` pass does not prove the iOS build — build to a device.)

## Notes for the implementer

- **Find real test harnesses, don't invent them.** Tasks 2 and 4 say "mirror the existing test" — locate the actual account-creation / WS-connect helpers (`grep -rn "fresh_store\|connect_ws\|Presence" server/src server/tests`) and reuse them verbatim. The test bodies above are intent, not copy-paste-final, for the harness-dependent parts.
- **Test DB only.** Every `cargo test` that touches the DB must use `littlelove_test` (set `DATABASE_URL` or the project's test env). Never the dev DB.
- **The `last_seen` JSON key** is snake_case on the wire (Rust field name, `RoomServerFrame` has `#[serde(tag = "kind")]`, no `rename_all`), matching the Dart parser's `json['last_seen']`.
