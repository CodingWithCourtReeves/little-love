# iOS push notifications — design

**Date:** 2026-06-17
**Status:** Approved, ready for implementation plan

## Goal

When your partner sends you a message and your app is **not** actively
connected (backgrounded, suspended, or killed), iOS shows a notification:

> **Little Love**
> 💜 Your partner sent you a message

The notification **never contains message content** — this is an E2EE product
and the server cannot read messages anyway. It is styled with the app's brand
(icon always; a palette-colored artwork attachment via a Notification Service
Extension) and is built so that a **future palette switcher** changes the
notification's colors with no server change and no rework.

This is the product's first push capability. Today the app only receives
messages over a live WebSocket while running in the foreground; a backgrounded
or killed app is silent.

## Constraints / context

- **Couples-only.** Every room contains exactly the two partners. "The
  recipient" is always one unambiguous person, and the *sender* is always "your
  partner" — so we never need a name in the notification. This both simplifies
  the copy and minimizes the metadata we hand to Apple.
- **E2EE.** The server stores ciphertext only and sees `(room_id,
  from_account_id, recipient_account_id, ts, size)` — never plaintext. The push
  is composed from this metadata alone. **No message content is ever placed in
  a push payload.**
- **iOS-only MVP.** Native Apple frameworks; prefer no third-party push SDK.
- **No Firebase / no Google.** We talk to APNs directly from the Rust server
  using a token-auth `.p8` key. Keeps Google out of a privacy-first stack and
  is the correct foundation for future **VoIP/CallKit calling** (PushKit is
  native-only).
- **Migrations are schema-only** (per CLAUDE.md). The new table is `CREATE
  TABLE` only — no data statements.
- **iOS banner appearance is owned by Apple.** Apps cannot recolor the banner
  card/background/system font. The only surfaces an app controls are the app
  **icon** and an **attachment image** (and, later, a custom content
  extension). Brand "theming" therefore means icon + a palette-colored
  attachment, *not* a recolored bubble.

## Behavior

- **Trigger:** a push is sent to the recipient when, and only when, a message
  is stored for them **and they have no live WebSocket session**. An online
  partner receives the message in-app and must not get a redundant banner.
  (A backgrounded/suspended iOS app has no live socket, so "no live session" is
  the right proxy for "needs a push.")
- **Content:** generic title + body, no sender name, no message content.
  Notifications group per-room via `thread-id = room_id`.
- **Foreground:** if a push ever arrives while the app is foreground, the
  `UNUserNotificationCenterDelegate` suppresses the banner (in-app UI already
  shows the message).
- **Palette:** the Notification Service Extension renders/attaches artwork for
  the **currently selected** palette, read on-device at notification time.
  Ships with exactly one palette (`twilight`). If the extension fails or times
  out, the push still shows as plain text (graceful degradation).
- **Permission prompt:** requested **after pairing**, when the user first lands
  in the paired inbox. Asking before a partner exists is pointless.

## Architecture

Four cooperating pieces: a server-side push sender + token store, an iOS native
layer (AppDelegate glue + a Notification Service Extension), a Dart
registration/permission layer, and an App Group bridge that carries the
selected palette key from app to extension.

```
partner A sends ──▶ ws.rs handle_send ──▶ store.insert_many (ciphertext)
                                              │
                                              ▼
                              recipient has live WS session?
                                   ├── yes ──▶ deliver in-app (no push)
                                   └── no  ──▶ push::notify(recipient tokens)
                                                     │  a2 crate, .p8 JWT
                                                     ▼
                                                   APNs
                                                     │ mutable-content:1
                                                     ▼
                              iOS Notification Service Extension (on device)
                                   reads palette key from App Group,
                                   attaches palette artwork
                                                     │
                                                     ▼
                                       banner: "💜 Your partner sent you a message"
```

## Data model (server)

New table, schema-only migration:

```sql
CREATE TABLE device_push_tokens (
  account_id   BIGINT      NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    TEXT        NOT NULL,            -- stable per-install id from the client
  apns_token   TEXT        NOT NULL,            -- hex device token from APNs
  environment  TEXT        NOT NULL,            -- 'sandbox' | 'production'
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);

CREATE INDEX device_push_tokens_account_idx ON device_push_tokens (account_id);
```

- One row per (account, device). Re-registering the same device upserts the
  token + environment + `updated_at`.
- `ON DELETE CASCADE` so deleting an account drops its tokens.
- No badge/unread tracking in this table — badges are out of scope (below).

## Wire protocol

Two new client→server frames on the existing authenticated WebSocket (reusing
the socket means **no new auth surface**):

- `RegisterPush { device_id, apns_token, environment }` — upsert into
  `device_push_tokens` for the authenticated account.
- `UnregisterPush { device_id }` — delete the row (logout / permission
  revoked).

No new server→client frames. No REST endpoints.

## Server push module

- New `push` module wrapping the **`a2`** crate (APNs, token-based JWT auth).
- Config via env secrets, loaded at startup; if unset, push is **disabled**
  (the feature degrades to today's behavior, and local dev without APNs keys
  still runs):
  - `APNS_KEY_P8` — the `.p8` key (path or contents)
  - `APNS_KEY_ID`
  - `APNS_TEAM_ID`
  - `APNS_TOPIC` — the app bundle id
  - `APNS_ENV` — `sandbox` | `production`
- `push::notify(recipient_account_id, room_id)`:
  1. load the recipient's tokens,
  2. build the payload (generic alert, `thread-id = room_id`,
     `mutable-content: 1`, `sound: default`),
  3. send to each token,
  4. on `410 Unregistered` / `BadDeviceToken`, delete that token row
     (token hygiene).
- **Hook point:** in `ws.rs handle_send`, immediately after `store.insert_many`
  succeeds, for the partner recipient (not the sender's self-copy): if
  `routing.deliver(...)` reached **zero** live sessions for that recipient, call
  `push::notify`. Sending is spawned/non-blocking so it never delays the send
  ack or holds the socket.

## iOS native (Swift)

- **AppDelegate**
  - `registerForRemoteNotifications()`; in
    `didRegisterForRemoteNotificationsWithDeviceToken`, hand the hex token to
    Dart over a `MethodChannel` (`little_love/push`).
  - Implement `UNUserNotificationCenterDelegate`; foreground presentation
    returns **no banner** (suppress when active).
- **Entitlements**
  - `aps-environment` (sandbox for dev builds, production for release).
  - **App Group** `group.<bundle>.shared`, shared by the app and the extension.
- **Notification Service Extension** (new target)
  - `didReceive` is a thin shell that calls a pure helper and attaches the
    resolved artwork; on any failure or timeout it delivers the original
    (plain-text) content unchanged.
  - **Pure, testable helper** `PaletteArtwork.resolve(forKey:) -> String`
    (asset name), with **no `UNNotification*` dependency**, so it is unit
    testable in isolation. The extension reads the palette key from the App
    Group `UserDefaults(suiteName:)` and passes it to this helper.
  - Bundles one artwork asset for `twilight`.
- **Palette writer (app side):** whenever the selected palette changes (today:
  once, at startup, always `twilight`), the app writes the palette key into the
  App Group `UserDefaults`. This is the single integration point the future
  palette switcher hooks into.

## Flutter (Dart)

- `MethodChannel("little_love/push")` for: request permission, receive the APNs
  token from native, surface registration/refresh events.
- Request notification permission **after pairing**, on first entry to the
  paired inbox.
- On receiving / refreshing the token, send `RegisterPush { device_id,
  apns_token, environment }` over the live WebSocket. `device_id` is a stable
  per-install id (persisted in secure storage; reused across launches).
- On logout / permission revocation, send `UnregisterPush { device_id }`.
- No `firebase_messaging`, no `flutter_local_notifications` — the server sends
  real alert pushes; the app only registers tokens and reacts.

## Palette swap — the guarantee

The one-palette-now / swap-later contract is satisfied by exactly two seams:

1. The app writes the **selected palette key** into the App Group.
2. The extension resolves that key → bundled artwork via
   `PaletteArtwork.resolve`.

Adding a palette later = drop in a new asset + add a case to
`PaletteArtwork.resolve` + have the switcher write the new key. **Zero server
changes, zero protocol changes.**

## Testing

- **Rust (unit):**
  - `device_push_tokens` store — upsert (re-register same device updates token),
    load-by-account, delete (unregister), cascade.
  - Push-trigger logic — given a stored message and a routing table, push is
    invoked **only** when the recipient has zero live sessions; sender's
    self-copy never triggers a push. APNs client is faked/injected so no network
    is hit.
  - Token hygiene — a faked `410 Unregistered` response deletes the offending
    token row.
- **Swift (XCTest):** `PaletteArtwork.resolve`
  - known key (`"twilight"`) → correct asset,
  - unknown/future key → default fallback, no crash,
  - missing/empty App Group value → default fallback, no crash.
  Added as an XCTest target that runs on the existing self-hosted macOS CI
  runner.
- **Dart:** token-registration flow — token from the channel produces a
  `RegisterPush` frame with a stable `device_id`; refresh re-sends; logout sends
  `UnregisterPush`.
- **Manual on-device** (via `./scripts/ios-deploy.sh`, sandbox APNs):
  backgrounded partner gets the banner; foregrounded partner does **not**;
  killed app still receives; tapping opens the right room.

## Out of scope (named to prevent scope creep)

- **Showing message content** in the notification — deliberately excluded; this
  is E2EE and the user does not want content shown.
- **Badge counts** — easy follow-up later (count unread `messages` rows for the
  recipient); not in this spec.
- **VoIP / CallKit calling** — a separate future workstream. This spec
  establishes its prerequisites (APNs auth key, native registration, entitlement
  discipline) but implements none of it.
- **Android / desktop push** — iOS-only MVP.

## Rollout / ops notes

- One-time Apple setup: generate an **APNs Auth Key (`.p8`)** in the Apple
  Developer portal; note Key ID + Team ID; enable the **Push Notifications**
  capability and the **App Group** in Xcode for both the app and the extension
  targets.
- Server secrets (`APNS_*`) provisioned in the deploy environment. With them
  unset, the build runs with push disabled — no hard dependency for local dev.
