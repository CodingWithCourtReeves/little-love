# Voice Calling — Design

**Date:** 2026-06-23
**Status:** Design / awaiting review
**Scope:** 1:1 E2EE voice calls between the two partners in a room. Video is
explicitly deferred to a follow-up.

---

## 1. Goals & non-goals

### Goals

- **Native phone-call experience.** A call rings on the partner's phone even
  when the app is backgrounded or fully killed — the iOS CallKit full-screen /
  lock-screen incoming-call UI, not just an in-app banner.
- **End-to-end encrypted media.** Audio is encrypted endpoint-to-endpoint; no
  server (ours or Cloudflare's) can hear it. This must hold *by construction*,
  not by policy.
- **Full call log.** Every call — outgoing, incoming, missed, declined, with
  duration — threads into the conversation like a normal message, synced and
  badged through the existing E2EE message path.
- **Reuse existing infrastructure.** Signaling rides the existing authenticated
  WebSocket; push rides the existing APNs pipeline; encryption reuses the
  existing room key + XChaCha20-Poly1305 envelope.

### Non-goals (this worktree)

- **Video calling** — deferred. The architecture leaves room for it (add a
  video track to the same `RTCPeerConnection`) but we ship audio-only first.
- **Group calls** — N/A. Every room is exactly two partners
  (`project_couples_only_rooms`); there is never a third participant, so we
  never need an SFU.
- **Call recording, voicemail, Android** — out of scope (iOS-only MVP,
  `project_ios_only_mvp`).

---

## 2. Architecture overview

### 2.1 Topology: peer-to-peer WebRTC + Cloudflare standalone TURN

The two phones establish a **direct peer-to-peer `RTCPeerConnection`**. WebRTC
mandates DTLS-SRTP: the two endpoints perform a DTLS handshake, derive SRTP
keys, and encrypt every audio frame before it leaves the device. **This is the
E2EE — it is intrinsic to WebRTC, not bolted on.**

Cloudflare's role is **NAT traversal only**:

- **STUN** lets each phone discover its public address so they can try to
  connect directly.
- **TURN** is the fallback relay for when the two phones cannot reach each
  other directly (symmetric NATs, restrictive networks). The TURN relay
  forwards **already-encrypted SRTP packets**; it never holds the DTLS/SRTP
  keys and cannot decrypt media. Cloudflare sees only IP/port metadata.

This is the same trust boundary we already accept for message storage: the
server routes opaque ciphertext.

**Verified against primary sources (2026-06-23):**

- Cloudflare TURN is usable standalone (without the SFU) and is documented for
  point-to-point use.
  <https://developers.cloudflare.com/realtime/turn/faq/>
- Cloudflare: *"When Cloudflare Realtime TURN is used in conjunction with
  WebRTC, Cloudflare cannot access the contents of the media being relayed"* —
  it processes only connection metadata.
  <https://developers.cloudflare.com/realtime/turn/faq/>
- Independent confirmation that DTLS-SRTP protects media across a TURN relay
  (the relay cannot read plaintext); the documented exception — *SFUs* see
  decrypted media — is precisely the topology we avoid.
  <https://antmedia.io/webrtc-security/>,
  <https://webrtc-security.github.io/>
- Pricing: **$0.05/GB with 1,000 GB/month free.** Audio is tens of KB/s, TURN
  is only used on the relay-fallback path (direct P2P calls cost nothing), and
  there are two users — effectively free for the foreseeable future.
  <https://developers.cloudflare.com/realtime/turn/faq/>
- Protocol caveat: Cloudflare TURN relays **UDP only** (it does not honor a TCP
  `REQUESTED-TRANSPORT`), but the client→TURN leg is reachable over UDP/TCP/TLS,
  so restrictive networks are still covered. Fine for audio.

**Rejected alternatives:**

- **Cloudflare Realtime / Calls (SFU).** An SFU terminates DTLS at the server
  and re-encrypts — it *breaks* naive E2EE; reclaiming it requires
  insertable-streams / SFrame. Pointless for a 1:1 call where P2P is simpler,
  cheaper, and E2EE for free. SFUs earn their keep at 3+ participants, which
  this app never has.
- **Self-hosted coturn (in production).** Works, but it is an ops burden (a
  server to run, scale, secure) for zero benefit over Cloudflare's managed
  TURN. (We *do* keep coturn as an optional **local-dev** stand-in — see §9.)

### 2.2 Signaling: encrypted SDP/ICE over the existing WebSocket

The one thing we must protect ourselves is the **signaling channel**. The SDP
offer/answer carries each side's **DTLS fingerprint**; if an attacker could
tamper with it in flight, they could MITM the call by substituting their own
fingerprint.

We close this exactly the way messages are already protected: **the SDP offer,
answer, and ICE candidates are encrypted with the room key** and sent as new
frame types over the authenticated WebSocket. Only the two partners can derive
the room key (X25519 ECDH → HKDF, `crypto/src/ecdh.rs` /
`app/lib/crypto/ecdh.dart`), so a forged or tampered offer simply will not
decrypt, and the DTLS fingerprints are authenticated end-to-end. **No new trust
assumptions — the same crypto as messages.**

Domain separation: signaling payloads are encrypted under a **per-call
signaling sub-key** derived from the room key:

```
sig_key = HKDF-SHA256(salt="littlelove.v0.2.call-sig", ikm=room_key, info=call_id)
```

This keeps call-signaling ciphertext cryptographically separated from message
traffic and gives each call a fresh key. (Reusing the room key directly with
the existing `encryptOutgoing`/`decryptIncoming` is an acceptable simpler
fallback — XChaCha20 uses random 24-byte nonces, so there is no nonce-reuse
risk — but the sub-key is cheap and is the cleaner choice.)

### 2.3 VoIP push is a wake-up signal, not the call data

The VoIP push only says *"incoming call `call_id` in room `room_id` from your
partner."* It carries **no SDP and no media** — the encrypted SDP offer flows
over the WebSocket once the woken app connects. This keeps the call payload on
the E2EE channel and the push content-free, consistent with how message pushes
already avoid leaking content (`server/src/push.rs`, `PUSH_BODY`).

```
Caller                      Server                        Callee (killed)
  | CallInvite{call_id,        |                              |
  |   enc(offer)} --WS-------->|                              |
  |                            |-- hold pending(call_id) ---->|
  |                            |-- APNs VoIP push ----------->| iOS wakes app
  |                            |                              | PushKit -> CallKit
  |                            |                              | (rings on lock screen)
  |                            |<------ WS connect + auth -----|
  |                            |-- deliver pending CallInvite->|
  |                            |<----- CallTurnRequest --------|
  |                            |-- CallTurnGrant{iceServers}->|  (Cloudflare API)
  |<-- CallAnswer{enc(answer)}-|<----- CallAnswer ------------|
  |<-> CallIce (trickle, both ways, encrypted) <------------->|
  |======= DTLS-SRTP P2P media (Cloudflare never sees) =======|
```

---

## 3. Components

### 3.1 Server (Rust)

| Component | Location | Change |
|---|---|---|
| Signaling frames | `server/src/wire.rs` | New `RoomClientFrame` / `RoomServerFrame` variants (§4) |
| Frame handling | `server/src/ws.rs` | Forward call frames via `routing.deliver`; hold pending invites; trigger VoIP push (mirrors `handle_send` / presence / `UploadGranted`) |
| TURN credentials | `server/src/turn.rs` *(new)* | Call Cloudflare `generate-ice-servers`; pluggable for coturn/offline |
| VoIP push | `server/src/push.rs` | Extend `PushSender`/`PushMessage` for `PushType::Voip` + `.voip` topic |
| VoIP token storage | `server/src/push_tokens.rs` | Register a `voip`-kind device token alongside the alert token |
| Config | `server/src/config.rs` | Add `TurnConfig`; add `.voip` APNs topic |

### 3.2 Client (Flutter / iOS)

| Component | Location | Change |
|---|---|---|
| Media engine | `flutter_webrtc` *(new dep)* | `RTCPeerConnection`, mic capture, audio playout |
| CallKit + PushKit | `flutter_callkit_incoming` *(new dep)* | Native incoming-call UI; VoIP token; report-on-wake |
| Call signaling frames | `app/lib/wire/frames.dart`, `live_connection.dart` | New frame models matching §4 |
| SDP encryption | `app/lib/pairing/encryption.dart`, `room_key_cache.dart` | Encrypt/decrypt SDP+ICE under the per-call sub-key |
| Call state machine | `app/lib/calling/` *(new)* | Ringing → connecting → active → ended (§5) |
| VoIP token registration | `app/lib/push/` | Register PushKit token (kind=voip) with server |
| Native PushKit/CallKit glue | `app/ios/Runner/AppDelegate.swift` | `PKPushRegistry`, report incoming call on VoIP push |
| Call-screen UI + debug overlay | `app/lib/calling/` | In-call UI; debug ICE/candidate overlay (§9) |

---

## 4. Signaling frames

All SDP/ICE payloads are wire strings produced by encrypting under the per-call
sig-key (§2.2); the server treats them as opaque, exactly like message bodies.

**Client → server** (new `RoomClientFrame` variants):

- `CallInvite { room_id, call_id, offer }` — caller initiates. `offer` =
  enc(SDP offer).
- `CallAnswer { room_id, call_id, answer }` — callee accepts. `answer` =
  enc(SDP answer).
- `CallIce { room_id, call_id, candidate }` — trickle ICE, either side. enc.
- `CallHangup { room_id, call_id, reason }` — end/decline/cancel.
  `reason ∈ {hangup, decline, busy, timeout, cancel}`.
- `CallTurnRequest { call_id }` — ask the server to mint ICE credentials.

**Server → client** (new `RoomServerFrame` variants):

- `CallInvite { room_id, call_id, from, offer }` — forwarded to callee.
- `CallAnswer { room_id, call_id, answer }` — forwarded to caller.
- `CallIce { room_id, call_id, candidate }` — forwarded to peer.
- `CallHangup { room_id, call_id, reason }` — forwarded to peer.
- `CallTurnGrant { call_id, ice_servers }` — server's response to a TURN
  request (the Cloudflare `iceServers` object, or the coturn/offline override).

`call_id` is a random 26-char ULID minted by the caller. Frames are forwarded
only within the room (the two partners), reusing `routing.deliver`.

---

## 5. Call state machine

```
            place call                 partner answers
   idle ───────────────► dialing ─────────────────────► connecting ──► active
     ▲                      │  partner declines/busy         │  ICE/DTLS    │
     │                      │  or ring timeout               │  fails       │ hang up
     │                      ▼                                ▼              │ (either side)
     └──────────────────  ended  ◄──────────────────────────────────────────┘

   incoming (callee):
   idle ──VoIP push──► ringing ──accept──► connecting ──► active
                          │ decline / timeout / caller cancel
                          ▼
                        ended
```

- **Ring timeout:** ~35 s. Both sides run the timer. On expiry the caller emits
  `CallHangup{reason:timeout}`; the callee dismisses CallKit. Outcome: *missed*.
- **Decline:** callee taps decline on CallKit → `CallHangup{reason:decline}`.
- **Cancel:** caller hangs up before answer → `CallHangup{reason:cancel}`.
- **Busy:** callee already in a call → `CallHangup{reason:busy}`.
- **Active hang-up:** either side → `CallHangup{reason:hangup}`; record duration.

### Glare (both call at once)

Both phones place a call near-simultaneously, producing two `call_id`s. We
resolve deterministically with a tiebreak both sides can compute identically:
**the call initiated by the partner with the lexicographically-smaller username
wins.** Usernames are unique and known to both clients, so both converge: the
loser auto-cancels its outgoing call and accepts the winner's incoming call.

---

## 6. VoIP push & CallKit wake flow

### Hard iOS constraint (drives the whole push design)

**Since iOS 13, every PushKit VoIP push MUST result in a reported CallKit
incoming call** (`reportNewIncomingCall`) and MUST call the PushKit
`completion()` handler. If it doesn't, iOS terminates the app and eventually
**stops delivering VoIP pushes entirely.** Therefore our VoIP-push handler
*always* surfaces CallKit — even to immediately show then end a stale call —
never silently. (`flutter_callkit_incoming` is built around this contract.)
Requires `UIBackgroundModes: voip` in `Info.plist`.

### Token registration

The app registers a `PKPushRegistry` for `.voIP` and obtains a **VoIP device
token distinct from the alert token** it already registers. It sends this to
the server as a `voip`-kind token (`push_tokens`). The server uses it for call
pushes; the existing alert token continues to serve message pushes.

### Send path (server)

On `CallInvite`, the server sends an APNs push with `apns-push-type: voip` and
topic `<bundle>.voip` to the callee's VoIP token, custom data
`{call_id, room_id}`. The `a2` crate already exposes `PushType::Voip` and
per-send `apns_topic` override, so `ApnsSender` extends cleanly; `classify()`
and token-hygiene (drop on 410/BadDeviceToken) are reused unchanged.

### Receive path (iOS)

1. VoIP push wakes the app (even from cold start).
2. PushKit delegate fires → immediately report a CallKit incoming call with the
   push's `call_id` UUID, and call `completion()`.
3. CallKit shows the native incoming-call screen (lock screen included), naming
   the partner.
4. **Accept** → app activates → ensures WS is connected/authed → server delivers
   the held `CallInvite` → app requests TURN creds → builds
   `RTCPeerConnection`, `setRemoteDescription(offer)`, `createAnswer`, sends
   `CallAnswer` → ICE trickle → DTLS-SRTP → audio. Report CallKit connected.
5. **Decline** → `CallHangup{reason:decline}` → both sides log the outcome.

Audio session is owned by CallKit; `flutter_webrtc` must coordinate
(`configureAudioSession`) so the mic/route activate correctly — a known
integration gotcha to validate on device.

---

## 7. TURN credential endpoint

Delivered over the **authenticated WebSocket** as a `CallTurnRequest` →
`CallTurnGrant` pair, reusing the existing Ed25519-verified WS auth and
mirroring the existing `UploadGranted` / `DownloadGranted` grant pattern (no new
REST-auth surface needed).

On `CallTurnRequest`, the server (in `server/src/turn.rs`) resolves ICE servers
via a pluggable provider:

- **Cloudflare (default, dev & prod):**
  `POST https://rtc.live.cloudflare.com/v1/turn/keys/$TURN_KEY_ID/credentials/generate-ice-servers`,
  header `Authorization: Bearer $TURN_API_TOKEN`, body `{"ttl": <seconds>}` →
  `201` with an `iceServers` object (STUN + TURN URLs across UDP/TCP/TLS, plus
  `username`/`credential`). TTL is set comfortably longer than the longest
  expected call; the client may refresh mid-call via `setConfiguration()`.
  <https://developers.cloudflare.com/realtime/turn/generate-credentials/>
- **Static override (offline/CI):** if `TURN_ICE_OVERRIDE` is set, the server
  returns a static `iceServers` object pointing at a local `coturn` (see §9).
  This mirrors the existing R2→MinIO `R2_ENDPOINT` override pattern.

`CallTurnGrant.ice_servers` is passed straight into the client's
`RTCPeerConnection` config. (TURN creds are not E2EE-sensitive — they only
authorize relay use — so they need not be encrypted under the room key.)

---

## 8. Call log (E2EE message reuse)

A completed/missed/declined call is recorded as a **normal encrypted message**.
When a call ends, the terminating side encodes a content payload —

```json
{ "kind": "call", "call_id": "...", "outcome": "completed|missed|declined|cancelled",
  "duration_s": 272, "started_at": "<iso8601>" }
```

— encrypts it under the room key, and sends it through the **existing message
send path** (`outbox` → `Send` frame → fan-out, with a self-copy). It therefore
persists, syncs, badges, replays on reconnect, and renders in history with
**zero new server-side storage** and the server still blind to content.

- **Direction** is rendered client-side relative to `from` (the same payload
  renders "Outgoing" for the sender and "Incoming/Missed" for the receiver).
- **Emitter:** the side that terminates the call emits the log message.
  **Dedupe by `call_id`** in the message store so a race (both sides emit)
  collapses to one entry. This reuses the existing optimistic/reconcile
  discipline (`MessageStore`, `_read`/`_deleted` sets) — see the CLAUDE.md note
  on per-message status surviving the server-id reconcile.

This is `MessageContent.decode` gaining a `call` kind, handled in
`room_message_router.dart` alongside reactions/unsends — *not* a new transport.

---

## 9. Testing & verification

The riskiest parts (VoIP waking a killed app, mic audio actually flowing, the
TURN relay path) are exactly what `flutter test` and the simulator cannot prove.
We test in **layers** and **isolate** the two hard parts.

### Layer 1 — logic, no devices (CI)

- **Call state machine** (ringing→connecting→active→ended; missed/declined/
  timeout/glare) — exhaustive Dart unit tests.
- **Signaling encrypt/decrypt round-trip** — both directions, Dart and Rust,
  mirroring `crypto/src/aead.rs` tests.
- **TURN endpoint** (Rust) — integration test with the Cloudflare HTTP call
  mocked; assert `iceServers` shape and the `TURN_ICE_OVERRIDE` branch.
- **VoIP push send** (Rust) — extend the existing `PushSender` fake seam; assert
  the `.voip` topic / `PushType::Voip` path and `classify()` outcomes.

Green Layer 1 catches logic regressions but proves nothing about ringing or
audio.

### Layer 2 — simulator (UI iteration only)

Call-screen layout and CallKit UI render in the simulator. It **cannot** deliver
PushKit VoIP pushes and has **no mic**, so it never proves wake or audio.
UI-polish only.

### Layer 3 — two real phones (the actual proof)

Devices: **Court's iPhone 17 Pro Max** and the **iPhone 13 Pro Max** — never
Kaitlyn's (`project_test_devices`).

Setup:
1. **One-time pairing** between the two phones (existing invite flow). Because
   `ios-deploy.sh` preserves app data + keychain, they stay paired across
   rebuilds.
2. **Dev server** via `dev-phones.sh`, configured with the **dev TURN key** and
   a **sandbox APNs `.voip`** topic; both phones point at the same ngrok API
   URL so they share one backend and are each other's partner. (Confirm `:7707`
   is *this* worktree's server, not another worktree's —
   `reference_dev_server_swap_across_worktrees`.)
3. **Build one phone at a time** (`ios-deploy.sh` rewrites the shared
   `Release.xcconfig`; parallel release builds clobber).

Manual verification gate:

| Scenario | Proves |
|---|---|
| B foregrounded, A calls | Signaling over WS, ring, answer, two-way audio, hang up, call-log entry both sides |
| B backgrounded/force-quit, A calls | **The point:** VoIP push wakes B, native CallKit screen on lock screen, answer connects audio |
| B declines / rings out | "Declined" / "Missed call" in the timeline |
| Both call ~simultaneously | Glare resolves to exactly one live call |

### Isolating the two hard parts (first-class deliverables)

- **Synthetic VoIP push script** — `scripts/dev-voip-push.sh` (thin wrapper /
  small Rust bin) fires a VoIP push straight at one phone's token (APNs
  sandbox, `apns-push-type: voip`, `.voip` topic) **decoupled from the whole
  WebRTC flow.** If CallKit appears from a killed app, the wake pipeline works
  independently of whether media ever connects. Biggest debugging time-saver.
- **Force-relay debug toggle** — a debug setting that sets
  `iceTransportPolicy: 'relay'` on the `RTCPeerConnection`, forcing traffic
  through Cloudflare TURN. Two phones on the same Wi-Fi otherwise connect direct
  P2P and **never exercise the relay**, so a passing local call does not prove
  TURN. (Alternatively: one phone on cellular, one on Wi-Fi.)

### Observability

- **Debug overlay** showing live ICE/connection state and the **selected
  candidate type** (host / srflx / relay) — tells you instantly whether a call
  went P2P or through Cloudflare, and where it stalled.
- Server logs TURN-cred issuance and VoIP-push outcomes (reusing push
  classification).

### Build gate

Per CLAUDE.md, a newly-added native plugin (`flutter_webrtc`,
`flutter_callkit_incoming`) can break `flutter build ios` while
`flutter test`/`analyze` stay green. **An on-device build to both phones is a
hard gate** before any "it works" claim; a stale transitive federated package
is pinnable via `dependency_overrides`.

---

## 10. Security analysis

- **Media confidentiality:** DTLS-SRTP between the two phones; TURN relays only
  ciphertext (§2.1). Holds by construction.
- **Signaling integrity / anti-MITM:** SDP + DTLS fingerprints are encrypted
  under the per-call sig-key derived from the room key; a forged/tampered offer
  does not decrypt (§2.2).
- **Body-borne action authorization** (per CLAUDE.md E2EE semantics): both
  partners share the room key, so either can craft a valid call frame. The
  client MUST validate that any `CallAnswer`/`CallIce`/`CallHangup` names a
  `call_id` of an *active call it is a party to*, and ignore frames for unknown
  call_ids or the wrong room. Rooms are 2-person so the only forwardee is the
  partner, but the client enforces the invariant regardless.
- **Replay:** `call_id` is random per call; clients reject frames for
  already-ended or unknown calls.
- **Push privacy:** the VoIP push is content-free (call_id + room_id only),
  consistent with the existing content-free message push.

---

## 11. Infra & configuration changes

- **Cloudflare TURN key** — provision a TURN key (dev + prod). Verify whether
  the pinned `cloudflare` Terraform provider (4.52.7, `infra/cloudflare`)
  exposes a TURN-key resource; if not, provision via the Cloudflare API /
  dashboard and store the key id + API token as deploy secrets. *(Open item —
  §13.)*
- **Server config** (`config.rs`): add `TurnConfig { key_id, api_token, ttl }`
  from `TURN_KEY_ID` / `TURN_API_TOKEN`, plus optional `TURN_ICE_OVERRIDE`;
  add a `.voip` APNs topic (`APNS_VOIP_TOPIC`, or derive `${topic}.voip`).
- **iOS** (`app/ios`): `UIBackgroundModes += voip`; PushKit + CallKit
  capabilities; `PKPushRegistry` in `AppDelegate.swift`. (The existing
  `NotificationService` extension is for alert mutable-content and is unrelated
  to VoIP, which lives in the main app.)
- **Dependencies:** `pubspec.yaml` += `flutter_webrtc`, `flutter_callkit_incoming`;
  server gains an HTTP client for the Cloudflare call (reuse the existing one if
  present, else `reqwest`).
- **Dev:** `dev-phones.sh` wires TURN + `.voip` APNs env; optional `coturn`
  service in `docker-compose` for offline TURN (selected via
  `TURN_ICE_OVERRIDE`); new `scripts/dev-voip-push.sh`.

---

## 12. Build sequence (independently verifiable milestones)

1. **Plumbing.** Add packages, iOS capabilities/`Info.plist`/PushKit registry.
   *Gate:* app builds and launches on **both** phones (no calling yet).
2. **TURN creds.** `turn.rs` + `CallTurnRequest`/`CallTurnGrant` + Cloudflare
   call; client fetches and logs `iceServers`. *Gate:* unit/integration tests +
   creds logged on device.
3. **VoIP wake.** PushKit token registration + server VoIP push + CallKit on a
   **synthetic** push (`dev-voip-push.sh`). *Gate:* killed app rings from the
   synthetic push.
4. **Signaling + media.** Call frames, state machine, `RTCPeerConnection`,
   encrypted SDP/ICE. *Gate:* **foreground** call connects with two-way audio.
5. **End-to-end wake call.** Full killed-app → ring → answer → audio.
   *Gate:* two-phone **background** call.
6. **Call log + glare + timeouts.** Missed/declined/completed entries; glare
   resolution. *Gate:* correct log entries both sides; glare converges.
7. **Relay verification.** Force-relay toggle + ICE debug overlay; cross-network
   call. *Gate:* a call confirmed routing through Cloudflare TURN.

---

## 13. Open questions

1. **Cloudflare TURN Terraform support** in provider 4.52.7 — confirm a resource
   exists; otherwise provision via API/dashboard and document the secret.
2. **Ring-timeout duration** — default 35 s; confirm it feels right on device.
3. **Foreground push dedupe** — when the callee is already WS-connected
   (foreground), do we still send the VoIP push (CallKit dedupes by UUID) or
   show an in-app incoming UI and skip the push? Decide during implementation;
   leaning "always push, let CallKit own the incoming UI" for one code path.
