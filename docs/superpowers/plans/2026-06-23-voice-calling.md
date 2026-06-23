# Voice Calling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship 1:1 end-to-end-encrypted voice calls between the two partners in a room, with native CallKit ringing (background/killed), a full call log, and Cloudflare TURN for NAT traversal.

**Architecture:** Direct peer-to-peer WebRTC (DTLS-SRTP) carries the audio — E2EE by construction; Cloudflare's standalone TURN service only relays already-encrypted packets. Signaling (SDP/ICE) is encrypted under a per-call sub-key derived from the existing room key and rides the existing authenticated WebSocket. A content-free APNs VoIP push wakes the callee and surfaces CallKit. Call outcomes are recorded as ordinary room-key-encrypted messages through the existing send path.

**Tech Stack:** Rust (axum WebSocket, `a2` APNs, `reqwest`), Flutter (`flutter_webrtc`, `flutter_callkit_incoming`), iOS PushKit/CallKit, Cloudflare TURN, the existing `crypto` crate (X25519/HKDF/XChaCha20-Poly1305).

**Design spec:** `docs/superpowers/specs/2026-06-23-voice-calling-design.md` — read it before starting.

## Global Constraints

- **Migrations are schema-only.** No `UPDATE`/`INSERT`/`DELETE`/backfill in migration files. A new column on a non-empty table lands nullable, then a code backfill, then a follow-up `NOT NULL` migration.
- **E2EE invariant:** the server never sees plaintext media, SDP, ICE, or call-log content. SDP/ICE are encrypted under the per-call sig-key; the VoIP push carries only `{call_id, room_id}`.
- **Authorize body-borne actions at the apply layer.** A client receiving any `CallAnswer`/`CallIce`/`CallHangup` MUST verify the `call_id` belongs to an active call it is a party to, and ignore frames for unknown call_ids or the wrong room.
- **Per-call sig-key:** `HKDF-SHA256(salt="littlelove.v0.2.call-sig", ikm=room_key, info=call_id)` → 32 bytes, used with the existing XChaCha20-Poly1305 wire envelope.
- **Ring timeout:** 35 seconds.
- **Glare rule:** when both partners place a call simultaneously, the call placed by the partner with the lexicographically-smaller `username` wins; the other side cancels its outgoing and accepts the incoming.
- **iOS-13 VoIP rule:** every PushKit VoIP push MUST report a CallKit incoming call and call the PushKit `completion()` — never silently. `UIBackgroundModes` must include `voip`.
- **On-device build gate:** `flutter test`/`analyze` do NOT prove an iOS build. Any task adding/altering a native plugin ends with a build to **both** physical phones (Court's iPhone 17 Pro Max `0DC6E4DC-B58D-509A-A5B8-FD316A255D89` and iPhone 13 Pro Max `F031FD6D-9E3D-5005-918D-BB860CE37C26`), **one at a time**, via `./scripts/ios-deploy.sh --server <url> --device <udid>`. Never Kaitlyn's phone.
- **Never run `cargo test` against the dev DB.** Use the `littlelove_test` database (`feedback_never_test_against_dev_db`).
- **Pre-push CI parity:** run `cargo fmt`, `cargo clippy`, `dart format`, full `flutter analyze` + `flutter test` before pushing.

---

## File Structure

**Server (Rust)**
- `server/src/turn.rs` *(new)* — TURN ICE-server provider (Cloudflare API + static override).
- `server/src/config.rs` *(modify)* — `TurnConfig`; `.voip` APNs topic.
- `server/src/wire.rs` *(modify)* — new `Call*` frame variants.
- `server/src/ws.rs` *(modify)* — forward call frames, hold pending invites, trigger VoIP push, handle TURN requests.
- `server/src/push.rs` *(modify)* — VoIP push send path.
- `server/src/push_tokens.rs` *(modify)* — `voip`-kind token registration.
- `server/src/calls.rs` *(new)* — in-memory pending-call registry (ring-timeout TTL, glare bookkeeping seam).

**Client (Flutter/Dart)**
- `app/lib/calling/call_state.dart` *(new)* — call state machine (pure Dart).
- `app/lib/calling/call_signaling.dart` *(new)* — encode/decode + encrypt/decrypt `Call*` frames.
- `app/lib/calling/call_session.dart` *(new)* — `RTCPeerConnection` lifecycle glue.
- `app/lib/calling/call_controller.dart` *(new)* — orchestrates state machine + signaling + CallKit + session.
- `app/lib/calling/call_log.dart` *(new)* — `call` `MessageContent` kind codec.
- `app/lib/calling/call_screen.dart` *(new)* — in-call UI + debug ICE overlay.
- `app/lib/wire/frames.dart` *(modify)* — `Call*` frame models.
- `app/lib/push/voip_registration.dart` *(new)* — PushKit token registration.
- `app/ios/Runner/AppDelegate.swift` *(modify)* — `PKPushRegistry`, report-on-wake.
- `app/ios/Runner/Info.plist` *(modify)* — `UIBackgroundModes: voip`.
- `app/pubspec.yaml` *(modify)* — `flutter_webrtc`, `flutter_callkit_incoming`.

**Infra / scripts**
- `infra/cloudflare/turn.tf` *(new)* — TURN key (or documented API provisioning).
- `scripts/dev-voip-push.sh` *(new)* — synthetic VoIP push.
- `scripts/dev-phones.sh` *(modify)* — wire TURN + `.voip` APNs env.
- `docker-compose.coturn.yml` *(new, optional)* — offline TURN stand-in.

---

## Milestone A — Infra & plumbing

### Task A1: Provision the Cloudflare TURN key

**Files:**
- Create: `infra/cloudflare/turn.tf`
- Modify: `infra/cloudflare/variables.tf`, `infra/cloudflare/outputs.tf`, `.secrets.env.example`

**Interfaces:**
- Produces: env vars `TURN_KEY_ID`, `TURN_API_TOKEN` available to the server; a **dev** TURN key and a **prod** TURN key.

- [ ] **Step 1: Check Terraform provider support.** In `infra/cloudflare`, run `tofu providers` and search the pinned `cloudflare` 4.52.7 schema for a TURN resource: `tofu providers schema -json | jq '.provider_schemas[].resource_schemas | keys[]' | grep -i turn`. Expected: either a `cloudflare_turn_app`-style resource exists, or no match.
- [ ] **Step 2a (resource exists): add `turn.tf`.** Define the TURN key resource for dev + prod, output the key ids. `terraform.tfvars` already holds the account id.
- [ ] **Step 2b (no resource): provision via API + document.** Create the key with `curl -X POST https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/calls/turn_keys -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' -d '{"name":"littlelove-dev"}'`. Record the returned key id; mint a scoped API token for `generate-ice-servers`. Add a `turn.tf` comment block documenting that the key is API-provisioned (no TF resource in 4.52.7) and where the secrets live.
- [ ] **Step 3: Wire secrets.** Add `TURN_KEY_ID` and `TURN_API_TOKEN` to `.secrets.env` (dev) and `.secrets.env.example` (documented, empty). Add a note in `infra/cloudflare/README.md`.
- [ ] **Step 4: Commit.**

```bash
git add infra/cloudflare/turn.tf infra/cloudflare/variables.tf infra/cloudflare/outputs.tf infra/cloudflare/README.md .secrets.env.example
git commit -m "infra(turn): provision Cloudflare TURN key (dev + prod)"
```

> No automated test — this is a provisioning task. Verification: `curl` the `generate-ice-servers` endpoint with the dev key (done in Task B2 Step 6).

---

### Task A2: Add WebRTC + CallKit packages and iOS VoIP capability

**Files:**
- Modify: `app/pubspec.yaml`, `app/ios/Runner/Info.plist`, `app/ios/Runner/Runner.entitlements`

**Interfaces:**
- Produces: `flutter_webrtc` and `flutter_callkit_incoming` available to import; the app declares the `voip` background mode.

- [ ] **Step 1: Add dependencies.** In `app/pubspec.yaml` under `dependencies:` add `flutter_webrtc: ^0.12.0` and `flutter_callkit_incoming: ^2.0.0` (pin to the latest stable resolved by `flutter pub get`; record exact versions).
- [ ] **Step 2: Resolve.** Run `cd app && flutter pub get`. Expected: resolves without conflict. If a transitive federated package breaks iOS later, pin its `*_darwin` impl via `dependency_overrides` (per CLAUDE.md).
- [ ] **Step 3: Declare VoIP background mode.** In `app/ios/Runner/Info.plist` add to `UIBackgroundModes`: `<string>voip</string>` (and keep existing `remote-notification` if present). Add `NSMicrophoneUsageDescription` with copy: `Little Love uses your microphone for voice calls with your partner.`
- [ ] **Step 4: Add Push Notifications + microphone entitlement.** Ensure `Runner.entitlements` has `aps-environment` (already present for alert push). No new entitlement file needed for VoIP (PushKit uses the same APNs entitlement); CallKit needs no entitlement.
- [ ] **Step 5: On-device build gate.** Build to **both** phones, one at a time:

```bash
./scripts/ios-deploy.sh --server <dev-url> --device 0DC6E4DC-B58D-509A-A5B8-FD316A255D89
./scripts/ios-deploy.sh --server <dev-url> --device F031FD6D-9E3D-5005-918D-BB860CE37C26
```

Expected: both builds reach "App installed", app launches from home screen, `databaseUUID` unchanged (no forced re-signup). This proves the two native plugins compile and link on iOS.
- [ ] **Step 6: Commit.**

```bash
git add app/pubspec.yaml app/pubspec.lock app/ios/Runner/Info.plist app/ios/Runner/Runner.entitlements
git commit -m "feat(calling): add flutter_webrtc + flutter_callkit_incoming, declare VoIP mode"
```

---

## Milestone B — TURN credentials

### Task B1: Server `TurnConfig`

**Files:**
- Modify: `server/src/config.rs`
- Test: `server/src/config.rs` (`#[cfg(test)]` module)

**Interfaces:**
- Produces: `pub struct TurnConfig { pub key_id: String, pub api_token: String, pub ttl_secs: u64, pub ice_override: Option<String> }`; `ServerConfig.turn: Option<TurnConfig>`; `ServerConfig::turn_from_env()`.

- [ ] **Step 1: Write the failing test.** Add to the `config.rs` test module:

```rust
#[test]
fn turn_from_env_reads_key_and_token() {
    // SAFETY: single-threaded test; set then clear.
    std::env::set_var("TURN_KEY_ID", "k123");
    std::env::set_var("TURN_API_TOKEN", "tok");
    let cfg = ServerConfig::turn_from_env().expect("turn config");
    assert_eq!(cfg.key_id, "k123");
    assert_eq!(cfg.api_token, "tok");
    assert_eq!(cfg.ttl_secs, 86_400); // default
    assert!(cfg.ice_override.is_none());
    std::env::remove_var("TURN_KEY_ID");
    std::env::remove_var("TURN_API_TOKEN");
}

#[test]
fn turn_from_env_absent_is_none() {
    std::env::remove_var("TURN_KEY_ID");
    assert!(ServerConfig::turn_from_env().is_none());
}
```

- [ ] **Step 2: Run, verify it fails.** `cargo test -p server config::tests::turn_from_env -- --test-threads=1`. Expected: FAIL (no `turn_from_env`).
- [ ] **Step 3: Implement.** In `config.rs`:

```rust
#[derive(Debug, Clone)]
pub struct TurnConfig {
    pub key_id: String,
    pub api_token: String,
    pub ttl_secs: u64,
    /// When set, the server returns this JSON `iceServers` blob instead of
    /// calling Cloudflare (local coturn / offline). Mirrors R2_ENDPOINT→MinIO.
    pub ice_override: Option<String>,
}

impl ServerConfig {
    pub fn turn_from_env() -> Option<TurnConfig> {
        let get = |k: &str| std::env::var(k).ok().filter(|s| !s.is_empty());
        Some(TurnConfig {
            key_id: get("TURN_KEY_ID")?,
            api_token: get("TURN_API_TOKEN")?,
            ttl_secs: get("TURN_TTL_SECS").and_then(|s| s.parse().ok()).unwrap_or(86_400),
            ice_override: get("TURN_ICE_OVERRIDE"),
        })
    }
}
```

Add `pub turn: Option<TurnConfig>` to `ServerConfig` and set it in `from_env()` via `Self::turn_from_env()`.
- [ ] **Step 4: Run, verify pass.** `cargo test -p server config::tests::turn -- --test-threads=1`. Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add server/src/config.rs
git commit -m "feat(turn): add TurnConfig from env"
```

---

### Task B2: TURN ICE-server provider (`turn.rs`)

**Files:**
- Create: `server/src/turn.rs`
- Modify: `server/src/lib.rs` (`pub mod turn;`)
- Test: `server/src/turn.rs` (`#[cfg(test)]`)

**Interfaces:**
- Consumes: `TurnConfig` (Task B1).
- Produces: `pub async fn ice_servers(cfg: &TurnConfig, http: &reqwest::Client) -> anyhow::Result<serde_json::Value>` returning the `iceServers` JSON; `pub fn ice_servers_from_override(raw: &str) -> anyhow::Result<serde_json::Value>`.

- [ ] **Step 1: Confirm `reqwest` is available.** `grep -i reqwest Cargo.toml`. If absent, add `reqwest = { version = "0.12", features = ["json", "rustls-tls"] }` to `Cargo.toml` and `cargo build -p server`.
- [ ] **Step 2: Write the failing test** (override path — no network):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn override_path_parses_ice_servers() {
        let raw = r#"{"iceServers":[{"urls":"stun:example"}]}"#;
        let v = ice_servers_from_override(raw).unwrap();
        assert!(v.get("iceServers").is_some());
    }
    #[test]
    fn override_rejects_garbage() {
        assert!(ice_servers_from_override("not json").is_err());
    }
}
```

- [ ] **Step 3: Run, verify it fails.** `cargo test -p server turn::tests -- --test-threads=1`. Expected: FAIL (module missing).
- [ ] **Step 4: Implement.**

```rust
//! TURN ICE-server provider. Default: Cloudflare `generate-ice-servers`.
//! Override (`TURN_ICE_OVERRIDE`): a static iceServers JSON for local coturn.
use crate::config::TurnConfig;
use serde_json::Value;

pub fn ice_servers_from_override(raw: &str) -> anyhow::Result<Value> {
    Ok(serde_json::from_str(raw)?)
}

pub async fn ice_servers(cfg: &TurnConfig, http: &reqwest::Client) -> anyhow::Result<Value> {
    if let Some(raw) = &cfg.ice_override {
        return ice_servers_from_override(raw);
    }
    let url = format!(
        "https://rtc.live.cloudflare.com/v1/turn/keys/{}/credentials/generate-ice-servers",
        cfg.key_id
    );
    let resp = http
        .post(url)
        .bearer_auth(&cfg.api_token)
        .json(&serde_json::json!({ "ttl": cfg.ttl_secs }))
        .send()
        .await?
        .error_for_status()?;
    Ok(resp.json::<Value>().await?)
}
```

- [ ] **Step 5: Run, verify pass.** `cargo test -p server turn::tests -- --test-threads=1`. Expected: PASS.
- [ ] **Step 6: Live smoke (manual, dev key).** With `TURN_KEY_ID`/`TURN_API_TOKEN` exported, run a tiny throwaway `curl` (same as `ice_servers` builds) and confirm a `201` with an `iceServers` array containing `turn:`/`turns:` URLs + `username`/`credential`. This verifies Task A1 provisioning.
- [ ] **Step 7: Commit.**

```bash
git add server/src/turn.rs server/src/lib.rs Cargo.toml Cargo.lock
git commit -m "feat(turn): Cloudflare ICE-server provider with static override"
```

---

### Task B3: `CallTurnRequest`/`CallTurnGrant` frames + handler

**Files:**
- Modify: `server/src/wire.rs`, `server/src/ws.rs`
- Test: `server/tests/` (integration) or `ws.rs` unit where feasible

**Interfaces:**
- Consumes: `turn::ice_servers` (B2), the authenticated WS session.
- Produces: client can send `{kind:"CallTurnRequest", call_id}` and receive `{kind:"CallTurnGrant", call_id, ice_servers}`.

- [ ] **Step 1: Add frame variants.** In `wire.rs`, add to `RoomClientFrame`: `CallTurnRequest { call_id: String }`. Add to `RoomServerFrame`: `CallTurnGrant { call_id: String, ice_servers: serde_json::Value }`. Follow the existing `#[serde(tag = "kind")]` convention; mirror `UploadGranted`.
- [ ] **Step 2: Write the failing test** (serde round-trip, no network):

```rust
#[test]
fn call_turn_request_deserializes() {
    let f: RoomClientFrame =
        serde_json::from_str(r#"{"kind":"CallTurnRequest","call_id":"01J"}"#).unwrap();
    assert!(matches!(f, RoomClientFrame::CallTurnRequest { call_id } if call_id == "01J"));
}
```

- [ ] **Step 3: Run, verify it fails.** `cargo test -p server wire -- --test-threads=1`. Expected: FAIL.
- [ ] **Step 4: Implement handler.** In `ws.rs`, in the room-phase match, add a `CallTurnRequest { call_id }` arm: call `turn::ice_servers(turn_cfg, &http_client).await`; on Ok deliver `RoomServerFrame::CallTurnGrant { call_id, ice_servers }` to the requesting session; on Err log and deliver a `CallTurnGrant` with an empty `iceServers` (client falls back to STUN-less direct/our default STUN). Thread a shared `reqwest::Client` and `Option<TurnConfig>` into the WS state (build once at startup alongside `ApnsSender`). Mirror the existing `UploadGranted` delivery path.
- [ ] **Step 5: Run, verify pass.** `cargo test -p server wire -- --test-threads=1`. Expected: PASS.
- [ ] **Step 6: Commit.**

```bash
git add server/src/wire.rs server/src/ws.rs
git commit -m "feat(turn): CallTurnRequest/Grant over the authed WebSocket"
```

---

### Task B4: Dart — fetch ICE servers over the WS

**Files:**
- Modify: `app/lib/wire/frames.dart`
- Create: `app/lib/calling/turn_credentials.dart`
- Test: `app/test/calling/turn_credentials_test.dart`

**Interfaces:**
- Consumes: `LiveConnection` (`app/lib/wire/live_connection.dart`), `CallTurnGrant` frame.
- Produces: `Future<List<Map<String,dynamic>>> fetchIceServers(LiveConnection conn, String callId)` returning the list for `RTCConfiguration`.

- [ ] **Step 1: Add frame models.** In `frames.dart` add `CallTurnRequestFrame(callId)` (toJson) and parse `CallTurnGrant` into a `CallTurnGrantFrame(callId, iceServers)` in the `RoomServerFrame` decoder.
- [ ] **Step 2: Write the failing test.** Decode a `CallTurnGrant` JSON and assert `iceServers` maps through; assert `CallTurnRequestFrame.toJson()` has `kind:"CallTurnRequest"`.
- [ ] **Step 3: Run, verify it fails.** `cd app && flutter test test/calling/turn_credentials_test.dart`. Expected: FAIL.
- [ ] **Step 4: Implement.** `fetchIceServers` sends `CallTurnRequestFrame`, awaits the matching `CallTurnGrant` (by `callId`) off `conn.incoming`, returns `iceServers` as `List<Map<String,dynamic>>` shaped for `flutter_webrtc` (`{'urls':..,'username':..,'credential':..}`).
- [ ] **Step 5: Run, verify pass.** Expected: PASS.
- [ ] **Step 6: Commit.**

```bash
git add app/lib/wire/frames.dart app/lib/calling/turn_credentials.dart app/test/calling/turn_credentials_test.dart
git commit -m "feat(turn): Dart fetchIceServers over the WebSocket"
```

---

## Milestone C — VoIP push wake

### Task C1: `voip`-kind push token storage

**Files:**
- Modify: `server/src/push_tokens.rs`, plus a new migration `server/migrations/NNNN_voip_token_kind.sql`
- Test: `server/src/push_tokens.rs` / existing token test harness against `littlelove_test`

**Interfaces:**
- Produces: `push_tokens` rows carry a `kind` (`alert` | `voip`); `register_token(account_id, token, kind, environment)`; `voip_token_for(account_id) -> Option<(token, environment)>`.

- [ ] **Step 1: Migration (schema-only).** Add `server/migrations/NNNN_voip_token_kind.sql`:

```sql
ALTER TABLE push_tokens ADD COLUMN kind TEXT NOT NULL DEFAULT 'alert';
```

(Default makes it safe on existing rows without a data statement. New unique constraint, if any, becomes `(account_id, kind, token)` — adjust the existing constraint in the same migration with `ALTER TABLE ... DROP CONSTRAINT / ADD CONSTRAINT`, schema-only.)
- [ ] **Step 2: Write the failing test** (against `littlelove_test`): register a `voip` token, assert `voip_token_for` returns it and `alert` lookups ignore it.
- [ ] **Step 3: Run, verify it fails.** `DATABASE_URL=postgres://.../littlelove_test cargo test -p server push_tokens -- --test-threads=1`. Expected: FAIL.
- [ ] **Step 4: Implement** `kind` threading through `register_token` and a `voip_token_for` query.
- [ ] **Step 5: Run, verify pass.**
- [ ] **Step 6: Commit.**

```bash
git add server/migrations server/src/push_tokens.rs
git commit -m "feat(push): voip-kind device token storage"
```

---

### Task C2: VoIP push send path

**Files:**
- Modify: `server/src/push.rs`, `server/src/config.rs`
- Test: `server/src/push.rs` (`#[cfg(test)]` with the existing fake `PushSender`)

**Interfaces:**
- Consumes: `ApnsConfig` + a `.voip` topic.
- Produces: `PushMessage` gains `push_type: PushKind` (`Alert` | `Voip`) and optional `call_id`; `ApnsSender::send` chooses topic + `PushType` accordingly.

- [ ] **Step 1: Add `.voip` topic.** In `config.rs`, `ApnsConfig` gains `voip_topic: String` (from `APNS_VOIP_TOPIC`, defaulting to `format!("{topic}.voip")`).
- [ ] **Step 2: Write the failing test.** Extend the `classify`/builder tests: build a `PushMessage` with `push_type: PushKind::Voip, call_id: Some("01J")`, assert (via a thin testable helper `build_options(kind, topic)`) that `apns_push_type == Voip` and the topic ends with `.voip`.
- [ ] **Step 3: Run, verify it fails.** `cargo test -p server push -- --test-threads=1`. Expected: FAIL.
- [ ] **Step 4: Implement.** Add `PushKind`; extend `PushMessage`; in `send`, when `Voip`, set `apns_push_type: Some(PushType::Voip)`, `apns_topic: voip_topic`, and `add_custom_data("call_id", ...)` + `add_custom_data("room_id", ...)`; no alert/badge body (VoIP payload is data-only). Keep `classify`/token-hygiene shared.
- [ ] **Step 5: Run, verify pass.**
- [ ] **Step 6: Commit.**

```bash
git add server/src/push.rs server/src/config.rs
git commit -m "feat(push): APNs VoIP push send path (.voip topic, data-only)"
```

---

### Task C3: Dart VoIP-token registration

**Files:**
- Create: `app/lib/push/voip_registration.dart`
- Modify: `app/lib/push/push_bootstrap.dart`
- Test: `app/test/push/voip_registration_test.dart` (logic-level; token source mocked)

**Interfaces:**
- Consumes: `flutter_callkit_incoming` VoIP-token stream; the existing token-upload REST/WS path used by `push_registration.dart`.
- Produces: on VoIP token receipt, uploads it to the server with `kind: "voip"`.

- [ ] **Step 1: Write the failing test.** Given a fake token source emitting `"abc"`, assert the uploader is called with `(token:"abc", kind:"voip")`.
- [ ] **Step 2: Run, verify it fails.** `cd app && flutter test test/push/voip_registration_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Subscribe to `FlutterCallkitIncoming.onEvents` / the VoIP-token callback, dedupe, and call the same upload helper `push_registration.dart` uses, passing `kind:"voip"`. Wire it into `push_bootstrap.dart` after sign-in.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/lib/push/voip_registration.dart app/lib/push/push_bootstrap.dart app/test/push/voip_registration_test.dart
git commit -m "feat(push): register PushKit VoIP token (kind=voip)"
```

---

### Task C4: iOS PushKit registry + report-on-wake

**Files:**
- Modify: `app/ios/Runner/AppDelegate.swift`

**Interfaces:**
- Produces: a `PKPushRegistry` for `.voIP`; on incoming VoIP push, reports a CallKit incoming call (via `flutter_callkit_incoming`) and calls `completion()`.

- [ ] **Step 1: Add `PKPushRegistry`.** In `AppDelegate.swift`, create a `PKPushRegistry(queue: .main)`, set `desiredPushTypes = [.voIP]`, implement `didUpdate pushCredentials` to forward the token to Dart (via the plugin), and `didReceiveIncomingPushWith`/`didInvalidatePushTokenFor`.
- [ ] **Step 2: Report on wake (the iOS-13 contract).** In `didReceiveIncomingPushWith`, parse `call_id`/`room_id`, immediately call `flutter_callkit_incoming`'s show-incoming API (partner name as caller), then call `completion()`. Never return without reporting a call.
- [ ] **Step 3: On-device build gate.** Build to both phones (one at a time). Expected: builds succeed, app launches. (Wake behavior is verified in Task C5.)
- [ ] **Step 4: Commit.**

```bash
git add app/ios/Runner/AppDelegate.swift
git commit -m "feat(calling): iOS PushKit registry + report-on-wake to CallKit"
```

---

### Task C5: Synthetic VoIP push script + wake gate

**Files:**
- Create: `scripts/dev-voip-push.sh`
- Modify: `scripts/dev-phones.sh` (export `TURN_*` + `APNS_VOIP_TOPIC`)

**Interfaces:**
- Produces: `./scripts/dev-voip-push.sh <voip-device-token>` fires one APNs-sandbox VoIP push to a device, decoupled from the call flow.

- [ ] **Step 1: Write the script.** Use `curl --http2` to APNs sandbox (`https://api.sandbox.push.apple.com/3/device/<token>`) with headers `apns-push-type: voip`, `apns-topic: <bundle>.voip`, JWT auth built from `APNS_KEY_P8`/`APNS_KEY_ID`/`APNS_TEAM_ID` (reuse the same `.p8` token auth the server uses), body `{"call_id":"test-01J","room_id":"<room>"}`. Print the APNs status.
- [ ] **Step 2: Wire dev env.** In `dev-phones.sh`, export `TURN_KEY_ID`, `TURN_API_TOKEN`, and `APNS_VOIP_TOPIC` so the dev server can mint creds and the script can push.
- [ ] **Step 3: Wake gate (on-device).** Install the app on a phone, **force-quit it**, run `./scripts/dev-voip-push.sh <that-phone's-voip-token>`. Expected: the native CallKit incoming-call screen appears on the lock screen from a killed app. This proves the wake pipeline independent of WebRTC.
- [ ] **Step 4: Commit.**

```bash
git add scripts/dev-voip-push.sh scripts/dev-phones.sh
git commit -m "test(calling): synthetic VoIP push script + dev env wiring"
```

---

## Milestone D — Signaling & media (foreground call)

### Task D1: Signaling frames + pending-call hold (server)

**Files:**
- Modify: `server/src/wire.rs`, `server/src/ws.rs`
- Create: `server/src/calls.rs`
- Modify: `server/src/lib.rs`
- Test: `server/src/calls.rs` (`#[cfg(test)]`) + `wire.rs` serde tests

**Interfaces:**
- Produces: `RoomClientFrame::{CallInvite,CallAnswer,CallIce,CallHangup}` and matching `RoomServerFrame` (server adds `from`); `calls::PendingCalls` with `insert(call_id, room_id, from, offer, expires_at)`, `take(call_id) -> Option<Pending>`, `expire_due(now)`.

- [ ] **Step 1: Frame variants + serde tests.** Add the six client/server `Call*` variants per spec §4 (payloads are opaque base64 wire strings). Write a serde round-trip test for `CallInvite` and `CallHangup{reason}`. Run → FAIL → implement → PASS.
- [ ] **Step 2: `PendingCalls` test.** Insert a pending invite, `take` it (returns once, then `None`); `expire_due` drops entries past `expires_at`. Run → FAIL.
- [ ] **Step 3: Implement `calls.rs`** as an in-memory `Mutex<HashMap<String, Pending>>` with a 40s TTL (ring timeout + slack). Run → PASS.
- [ ] **Step 4: Forwarding in `ws.rs`.** On `CallInvite`: forward to the partner's online sessions via `routing.deliver` **and** `PendingCalls::insert` **and** send a VoIP push (Task C2) to the partner's `voip` token. On `CallAnswer`/`CallIce`/`CallHangup`: forward to the partner's sessions (add `from`). On partner WS (re)connect: deliver any non-expired pending `CallInvite` (mirror `announce_presence_on_connect`). Spawn a periodic `expire_due` sweep.
- [ ] **Step 5: Tests pass.** `cargo test -p server calls wire -- --test-threads=1`. Expected: PASS.
- [ ] **Step 6: Commit.**

```bash
git add server/src/wire.rs server/src/ws.rs server/src/calls.rs server/src/lib.rs
git commit -m "feat(calling): call signaling frames, pending-invite hold, VoIP trigger"
```

---

### Task D2: Dart signaling encode + per-call sig-key

**Files:**
- Create: `app/lib/calling/call_signaling.dart`
- Modify: `app/lib/wire/frames.dart`
- Test: `app/test/calling/call_signaling_test.dart`

**Interfaces:**
- Consumes: room key (`room_key_cache.dart`), `encryptOutgoing`/`decryptIncoming` (`app/lib/pairing/encryption.dart`), HKDF (existing in `app/lib/crypto`).
- Produces: `deriveSigKey(Uint8List roomKey, String callId) -> Uint8List`; `encryptSignal(sigKey, sdpOrCandidate) -> String`; `decryptSignal(sigKey, wire) -> String`; `Call*` frame models in `frames.dart`.

- [ ] **Step 1: Write the failing test.** `deriveSigKey` is deterministic and differs per `callId`; `decryptSignal(sigKey, encryptSignal(sigKey, "v=0..."))` round-trips; a wrong `callId` key fails to decrypt (returns the cannot-decrypt sentinel / throws).
- [ ] **Step 2: Run, verify it fails.** `cd app && flutter test test/calling/call_signaling_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** `deriveSigKey` = HKDF-SHA256(salt=`littlelove.v0.2.call-sig`, ikm=roomKey, info=utf8(callId)) → 32 bytes; `encryptSignal`/`decryptSignal` reuse the existing XChaCha20 envelope helpers. Add `CallInvite/Answer/Ice/Hangup` frame models (toJson + decode).
- [ ] **Step 4: Run, verify pass.** Mirror the Rust `aead` round-trip discipline.
- [ ] **Step 5: Commit.**

```bash
git add app/lib/calling/call_signaling.dart app/lib/wire/frames.dart app/test/calling/call_signaling_test.dart
git commit -m "feat(calling): per-call sig-key + encrypted signaling frames (Dart)"
```

---

### Task D3: Call state machine (pure Dart)

**Files:**
- Create: `app/lib/calling/call_state.dart`
- Test: `app/test/calling/call_state_test.dart`

**Interfaces:**
- Produces: `enum CallPhase { idle, dialing, ringing, connecting, active, ended }`; `class CallState` with pure transition methods `placeCall`, `incoming`, `accept`, `remoteAnswered`, `iceConnected`, `iceFailed`, `hangup(reason)`, `timeout`; each returns the next `CallState` and never performs I/O.

- [ ] **Step 1: Write the failing tests.** Exhaustively: `idle.placeCall → dialing`; `dialing.remoteAnswered → connecting`; `connecting.iceConnected → active`; `active.hangup → ended(hangup)`; `dialing.timeout → ended(missed)`; `ringing.accept → connecting`; `ringing.hangup(decline) → ended(declined)`; `connecting.iceFailed → ended(failed)`; illegal transitions (e.g. `idle.accept`) throw/no-op.
- [ ] **Step 2: Run, verify they fail.** Expected: FAIL.
- [ ] **Step 3: Implement** the transition table per spec §5. No timers, no sockets — pure.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/lib/calling/call_state.dart app/test/calling/call_state_test.dart
git commit -m "feat(calling): pure call state machine"
```

---

### Task D4: `RTCPeerConnection` session glue

**Files:**
- Create: `app/lib/calling/call_session.dart`
- Test: `app/test/calling/call_session_test.dart` (logic seams only; WebRTC mocked)

**Interfaces:**
- Consumes: `flutter_webrtc`, ICE servers (Task B4), `call_signaling.dart`.
- Produces: `CallSession` with `Future<String> createOffer()`, `Future<String> acceptOffer(String sdp)` (→ answer sdp), `setAnswer(String sdp)`, `addRemoteCandidate(Map)`, streams `onLocalCandidate`, `onConnectionState`, `onSelectedCandidatePair` (host/srflx/relay), `setForceRelay(bool)`, `dispose()`.

- [ ] **Step 1: Write seam tests.** With an injected fake peer-connection factory: `createOffer` sets local description and emits the offer string; `addRemoteCandidate` forwards to the pc; `setForceRelay(true)` makes the built `RTCConfiguration` carry `iceTransportPolicy:"relay"`. (Real SRTP is on-device only.)
- [ ] **Step 2: Run, verify they fail.** Expected: FAIL.
- [ ] **Step 3: Implement** `CallSession` wrapping `createPeerConnection(config)` with an audio-only `MediaStream` (`getUserMedia({audio:true})`), trickle ICE via `onIceCandidate`, expose connection + selected-candidate-pair state. Build `RTCConfiguration` from fetched ICE servers; honor `forceRelay`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/lib/calling/call_session.dart app/test/calling/call_session_test.dart
git commit -m "feat(calling): RTCPeerConnection session glue (audio, trickle ICE)"
```

---

### Task D5: Call controller + call screen — foreground call gate

**Files:**
- Create: `app/lib/calling/call_controller.dart`, `app/lib/calling/call_screen.dart`
- Modify: a call-entry point (chat header / chat-info page) to start a call
- Test: `app/test/calling/call_controller_test.dart` (orchestration with fakes)

**Interfaces:**
- Consumes: `CallState` (D3), `CallSession` (D4), `call_signaling` (D2), `LiveConnection`, `flutter_callkit_incoming`.
- Produces: `CallController` driving outgoing/incoming flows end to end; emits state for `call_screen.dart`.

- [ ] **Step 1: Write orchestration tests.** With fake session + fake connection: placing a call sends `CallInvite` with an encrypted offer; receiving `CallAnswer` calls `session.setAnswer` and transitions to `connecting`; receiving `CallIce` calls `addRemoteCandidate`; local candidates are sent as `CallIce`; `iceConnected` → `active`. Assert `call_id` validation drops frames for unknown ids (Global Constraint).
- [ ] **Step 2: Run, verify they fail.** Expected: FAIL.
- [ ] **Step 3: Implement** `CallController`: outgoing = fetch ICE → `createOffer` → encrypt → `CallInvite` → start CallKit outgoing → on `CallAnswer` set answer → trickle. Incoming = on `CallInvite`/CallKit-accept → fetch ICE → `acceptOffer` → `CallAnswer` → trickle. Build `call_screen.dart` (caller/callee names, mute, speaker, hang-up; debug overlay stubbed for Task F2).
- [ ] **Step 4: Run, verify pass.** `cd app && flutter test test/calling/`. Expected: PASS.
- [ ] **Step 5: FOREGROUND CALL GATE (on-device, both phones paired).** With both apps **open**, place a call A→B. Expected: B rings (in-app + CallKit), B answers, **two-way audio**, either side hangs up cleanly. Repeat B→A.
- [ ] **Step 6: Commit.**

```bash
git add app/lib/calling/call_controller.dart app/lib/calling/call_screen.dart app/lib/screens app/test/calling/call_controller_test.dart
git commit -m "feat(calling): call controller + screen; foreground call works on device"
```

---

## Milestone E — Background wake call, call log, glare, timeouts

### Task E1: Background/killed wake call — full path gate

**Files:**
- Modify: `app/lib/calling/call_controller.dart`, `app/ios/Runner/AppDelegate.swift` (accept → activate → connect WS → consume pending invite)

**Interfaces:**
- Consumes: the CallKit accept callback (Task C4), pending-invite delivery on WS connect (Task D1).

- [ ] **Step 1: Wire accept→connect.** On CallKit accept from a cold/background launch: ensure the `LiveConnection` is established and authenticated, then consume the server-delivered pending `CallInvite`, run the incoming flow (D5), and report CallKit connected when ICE reaches `active`.
- [ ] **Step 2: Audio-session coordination.** Ensure `flutter_webrtc` audio is configured for the CallKit-owned audio session (`configureAudioSession`/`onCallAccepted`) so the mic/route activate. Validate on device.
- [ ] **Step 3: BACKGROUND CALL GATE.** B **force-quits** the app. A calls B. Expected: VoIP push wakes B, CallKit shows on the lock screen, B accepts, **two-way audio** connects. Repeat with B merely backgrounded.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/calling/call_controller.dart app/ios/Runner/AppDelegate.swift
git commit -m "feat(calling): killed-app VoIP wake → CallKit accept → connected call"
```

---

### Task E2: Call-log `MessageContent` kind

**Files:**
- Create: `app/lib/calling/call_log.dart`
- Modify: `app/lib/conversation/room_message_router.dart` (handle `call` kind, dedupe by `call_id`), the message-content encoder, the bubble renderer
- Test: `app/test/calling/call_log_test.dart`

**Interfaces:**
- Consumes: the existing message send path (outbox → `Send`), `MessageContent.decode`.
- Produces: `encodeCallLog({callId, outcome, durationS, startedAt})` / `decodeCallLog`; router renders a call row and dedupes repeat `call_id`s.

- [ ] **Step 1: Write the failing test.** `decodeCallLog(encodeCallLog(...))` round-trips; the router, given two messages with the same `call_id`, keeps one timeline entry (reuse the `_read`/`_deleted`-style set discipline from `MessageStore`); direction renders relative to `from`.
- [ ] **Step 2: Run, verify it fails.** Expected: FAIL.
- [ ] **Step 3: Implement** the `call` kind in the content codec, dedupe-by-`call_id` in the router, and a call-log bubble (missed/declined/completed + duration). The terminating side emits one encrypted call-log message via the normal outbox path.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/lib/calling/call_log.dart app/lib/conversation/room_message_router.dart app/test/calling/call_log_test.dart
git commit -m "feat(calling): call-log message kind via existing E2EE send path"
```

---

### Task E3: Glare resolution + ring timeout → outcomes

**Files:**
- Modify: `app/lib/calling/call_controller.dart`, `app/lib/calling/call_state.dart`
- Test: `app/test/calling/glare_test.dart`, extend `call_state_test.dart`

**Interfaces:**
- Consumes: both partners' usernames (known from the room roster).
- Produces: `resolveGlare(myUsername, peerUsername) -> bool winnerIsMe`; a 35s ring timer that drives `timeout`.

- [ ] **Step 1: Write the failing tests.** `resolveGlare` returns the same winner on both sides (smaller username wins); when I lose, the controller cancels my outgoing `CallInvite` and accepts the incoming; ring timer firing at 35s drives `state.timeout` → `ended(missed)` and emits a "missed" call-log on the caller side.
- [ ] **Step 2: Run, verify they fail.** Expected: FAIL.
- [ ] **Step 3: Implement** the deterministic tiebreak and the timeout timer wiring (caller emits `CallHangup{timeout}` + missed log; callee dismisses CallKit).
- [ ] **Step 4: Run, verify pass.** `cd app && flutter test test/calling/`. Expected: PASS.
- [ ] **Step 5: GATES (on-device).** (a) Both tap call ~simultaneously → exactly one live call. (b) A calls, B ignores → after 35s B's CallKit dismisses and A shows "Missed call"; both timelines show the entry. (c) B declines → "Declined" entry both sides.
- [ ] **Step 6: Commit.**

```bash
git add app/lib/calling/call_controller.dart app/lib/calling/call_state.dart app/test/calling
git commit -m "feat(calling): glare resolution, ring timeout, missed/declined call log"
```

---

## Milestone F — Relay verification & polish

### Task F1: Optional offline coturn stand-in

**Files:**
- Create: `docker-compose.coturn.yml`
- Modify: `scripts/dev-phones.sh` (doc the `TURN_ICE_OVERRIDE` path)

**Interfaces:**
- Produces: a local `coturn` with static creds; setting `TURN_ICE_OVERRIDE` to its iceServers JSON routes the server's grant to it.

- [ ] **Step 1: Compose file.** Add `coturn/coturn` with a static long-term credential and a relay port range, bound to the host LAN IP.
- [ ] **Step 2: Document.** In `dev-phones.sh`, note that exporting `TURN_ICE_OVERRIDE='{"iceServers":[{"urls":"turn:<lan-ip>:3478","username":"dev","credential":"dev"}]}'` swaps Cloudflare for local coturn (offline parity with R2→MinIO).
- [ ] **Step 3: Commit.**

```bash
git add docker-compose.coturn.yml scripts/dev-phones.sh
git commit -m "test(calling): optional local coturn stand-in via TURN_ICE_OVERRIDE"
```

---

### Task F2: Force-relay toggle + ICE debug overlay — relay gate

**Files:**
- Modify: `app/lib/calling/call_screen.dart`, `app/lib/calling/call_session.dart`, a debug-settings provider

**Interfaces:**
- Consumes: `CallSession.setForceRelay`, `onSelectedCandidatePair`, `onConnectionState`.

- [ ] **Step 1: Force-relay toggle.** A debug setting that sets `iceTransportPolicy:"relay"` on new sessions.
- [ ] **Step 2: Debug overlay.** In `call_screen.dart`, when debug is on, show live connection state + selected candidate type (host/srflx/**relay**).
- [ ] **Step 3: RELAY GATE (on-device).** Enable force-relay, place a call. Expected: call connects and the overlay shows **relay** — proving the Cloudflare TURN leg. Then disable force-relay and place a cross-network call (one phone on cellular, one on Wi-Fi); confirm it connects (relay used when direct fails).
- [ ] **Step 4: Commit.**

```bash
git add app/lib/calling/call_screen.dart app/lib/calling/call_session.dart app/lib
git commit -m "test(calling): force-relay toggle + ICE debug overlay; relay path verified"
```

---

### Task F3: Final CI parity + cleanup

- [ ] **Step 1:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings`.
- [ ] **Step 2:** `cd app && dart format --set-exit-if-changed lib test && flutter analyze && flutter test`.
- [ ] **Step 3:** Re-run both on-device builds (both phones) on the final tree; confirm `databaseUUID` unchanged.
- [ ] **Step 4: Commit any fmt/lint fixes.**

```bash
git add -A
git commit -m "chore(calling): fmt, clippy, analyze clean"
```

---

## Spec Coverage Check

- §2.1 topology / E2EE → Tasks B1–B4 (TURN), D1–D5 (P2P media). ✓
- §2.2 encrypted signaling + per-call sig-key → D2. ✓
- §2.3 VoIP wake-only push → C2, C4, C5, D1, E1. ✓
- §4 signaling frames → B3, D1, D2. ✓
- §5 state machine + glare + timeout → D3, E3. ✓
- §6 VoIP/CallKit + iOS-13 contract → C1–C5, E1. ✓
- §7 TURN endpoint (pluggable) → B1–B3, F1. ✓
- §8 call log → E2. ✓
- §9 testing (synthetic push, force-relay, overlay) → C5, F2. ✓
- §10 security (apply-layer authz, replay) → D5 Step 1, D1. ✓
- §11 infra/config → A1, A2, C2, F1. ✓
- §13 open questions → A1 Step 1 (TF support), E3 (timeout), D5/E1 (foreground dedupe). ✓
