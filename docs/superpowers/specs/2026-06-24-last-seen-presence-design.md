# Last-seen presence — design

**Date:** 2026-06-24
**Status:** Approved (design), pending spec review
**Branch:** `worktree-last-seen-presence`

## Summary

Extend the existing online/offline/typing presence indicator so that, when a
partner is **offline**, the conversation header shows a Telegram-style
"last seen" line instead of a bare "Offline". Online and typing states are
unchanged.

Examples of the offline text:

- `last seen just now`
- `last seen 5 minutes ago`
- `last seen today at 9:14 PM`
- `last seen yesterday at 9:14 PM`
- `last seen 12/04/2026` (older than ~a week)

When online → `online`. When typing → `typing…` (unchanged, wins over
everything).

## Why this does not weaken E2EE

E2EE is a guarantee about **message content** — only the two endpoints can read
message bodies. "Who's online" and "when were they last online" are
**connection metadata**, which the server already observes because it manages
the WebSocket sessions. The server already tracks and broadcasts online/offline
in plaintext today; `last_seen_at` exposes nothing it doesn't already see at
connect/disconnect time.

This matches the industry pattern: WhatsApp and Telegram show last-seen as
server-observed metadata while still being E2EE for message content; the only
apps that "protect" last-seen (Signal, Session) do so by **not having the
feature at all**. For a two-person couples app where the only viewer is your
partner, last-seen is a feature, not a leak.

`last_seen_at` is stored plaintext (not E2EE), consistent with how
online/offline already works.

## Approach (chosen: A — persist + deliver in presence frame)

### Data model

Add a nullable column to `accounts`:

```sql
ALTER TABLE accounts ADD COLUMN last_seen_at timestamptz;
```

Schema-only migration (per project rule: no data UPDATE/INSERT in migrations).
Nullable so it can ship without a backfill; null is rendered as a graceful
fallback on the client (see below).

### Server (Rust)

When does `last_seen_at` get written?

- **On disconnect of the user's *last* WebSocket session** — write `now()`.
  This is the moment the user goes truly offline and is the value the partner
  cares about. The existing `announce_presence_on_disconnect()` path
  (`ws.rs` ~1190–1214) already runs only when the last session closes; the DB
  write hangs off the same condition.
- **On connect** — write `now()` as well, so the column is never null for an
  account that has connected at least once, and so a stale value can't outlive
  a reconnect. (While online the partner sees "online", so this value isn't
  displayed until the next disconnect.)

Because liveness timeout (40s) drives disconnect detection, a crashed/dropped
client's `last_seen_at` lands ≈ when they actually dropped (within the timeout
window). Acceptable.

### Wire protocol

Extend the server→client `Presence` frame (`wire.rs` ~275–278) to carry an
optional last-seen timestamp, only meaningful when `online: false`:

```rust
RoomServerFrame::Presence {
    user: String,
    online: bool,
    last_seen: Option<i64>, // unix epoch ms (or rfc3339); None when online or unknown
}
```

The two places that already emit `Presence` both get the new field:

1. **Connect-time announcement** (`ws.rs` ~1142–1186): when telling the
   connecting client their partner's current status, if the partner is offline,
   include the partner's `last_seen_at` read from the DB.
2. **Disconnect broadcast** (`ws.rs` ~1190–1214): when telling the partner
   "you are offline", include the just-written `last_seen_at` (≈ now).

Online announcements send `last_seen: None`.

### Frontend (Flutter)

- `presenceProvider` (`presence_state.dart`) currently holds a bare `bool`.
  Change it to hold both the online bool **and** the last-seen timestamp, e.g.
  a small `PartnerPresence { bool online; DateTime? lastSeen; }` value, keyed by
  username as today. (Family notifier shape stays the same; only the state type
  grows.)
- `room_message_router.dart` (`PresenceFrame` case ~103–110): parse the new
  `last_seen` field and pass it into the notifier.
- `_PartnerStatusLine` (`conversation_page.dart` ~1780–1830): when offline and
  `lastSeen != null`, render the Telegram-style string; when offline and
  `lastSeen == null`, fall back to the existing "Offline" text. Online and
  typing branches unchanged.
- **Live refresh:** the relative string ("5 minutes ago") should tick forward
  while the screen is open. A periodic rebuild (~once per minute) recomputes the
  label from the stored timestamp. No new network traffic — purely client-side
  formatting off the cached `lastSeen`.

### Formatting rules (client-side, Telegram-style)

Given `lastSeen` (local time):

- < 1 min ago → `last seen just now`
- < 60 min ago → `last seen N minute(s) ago`
- same calendar day → `last seen today at h:mm AM/PM`
- previous calendar day → `last seen yesterday at h:mm AM/PM`
- within ~last week → `last seen <Weekday> at h:mm AM/PM`
- older → `last seen MM/DD/YYYY`

(Exact thresholds are an implementation detail; this is the intended shape.)

## Components & boundaries

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| Migration `00XX_last_seen.sql` | Add nullable `last_seen_at` column | — |
| Server presence write | Stamp `last_seen_at` on connect + last-disconnect | DB, routing |
| `Presence` wire frame | Carry optional `last_seen` to the partner | — |
| `PartnerPresence` state + provider | Hold online + lastSeen per partner | wire frame |
| `last_seen` formatter | Pure fn: timestamp → Telegram-style label | — |
| `_PartnerStatusLine` | Choose typing / online / last-seen / offline text | provider, formatter |

The formatter is a pure function — unit-testable in isolation with no
network/DB. The server write is a small addition to two existing presence code
paths.

## Testing

- **Rust:** test against `littlelove_test` DB (never the dev DB). Verify
  `last_seen_at` is written on last-session disconnect and on connect; verify
  the connect-time `Presence` announcement for an offline partner includes a
  `last_seen` value, and that an online announcement sends `None`. Multi-session
  case: `last_seen` only stamped when the *last* session closes.
- **Flutter:** unit-test the formatter across all buckets (just now, minutes,
  today, yesterday, weekday, old date) using injected fixed "now" values.
  Widget test that `_PartnerStatusLine` shows `online` / `typing…` /
  `last seen …` / `Offline` (null fallback) for the right states.

## Out of scope (YAGNI)

- Privacy toggle / hiding last-seen from the partner (couples app, single
  viewer).
- Encrypting last-seen end-to-end (it's server-observed metadata by nature).
- "Away"/idle states, presence history/timeline, read-time analytics.

## Open questions

None blocking. Timestamp wire encoding (epoch ms vs rfc3339) to be finalized in
the implementation plan to match existing conventions in `wire.rs`.
