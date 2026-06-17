# iOS Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a partner sends a message and the recipient's app has no live WebSocket session, deliver a content-free, brand-styled iOS push that — on tap — opens the specific room.

**Architecture:** The Rust/Axum server gains a `device_push_tokens` table, two new WebSocket frames to register/unregister an APNs token, and a `push` module (behind a `PushSender` trait so it's testable with a fake) wired into the existing `handle_send` hook — a push fires only when `routing.deliver` reached zero sessions. iOS gains remote-notification registration in `AppDelegate`, an App Group, and a Notification Service Extension that attaches palette artwork resolved on-device. Flutter bridges the APNs token to the server over the live socket and routes notification taps to a single open-room handler.

**Tech Stack:** Rust (axum 0.7, sqlx 0.7/Postgres, tokio), the `a2` crate 0.10 (APNs token auth), Swift (UIKit, UserNotifications, UNNotificationServiceExtension, XCTest), Flutter/Dart (flutter_riverpod, MethodChannel, flutter_secure_storage), PostgreSQL.

## Global Constraints

- **Couples-only.** Every room is exactly the two partners; "the recipient" is one person; the sender is always "your partner". Never put a name or message content in a push.
- **E2EE.** Server stores ciphertext only. Push payloads carry NO message content. The only metadata in a payload is the opaque `room_id` (for deep-linking) under custom data.
- **Notification copy (verbatim):** title `Little Love`, body `💜 Your partner sent you a message`.
- **No Firebase / no Google.** APNs is reached directly from Rust via the `a2` crate with token auth (`.p8`).
- **Push disabled when unconfigured.** If the `APNS_*` env vars are unset, the server runs exactly as today (no push). Local dev and existing tests must not require APNs keys.
- **Migrations are schema-only** (per CLAUDE.md): `CREATE TABLE` / `CREATE INDEX` only — no `UPDATE`/`INSERT`/`DELETE`/backfill in migration files.
- **iOS-only MVP.** Bundle id `dev.littlelove.littlelove`; team `9PVUX2535W`; App Group `group.dev.littlelove.littlelove`; APNs topic = the bundle id.
- **Run full CI lint before pushing:** `cargo fmt`, `cargo clippy`, `dart format`, `flutter analyze`, and the test suites — per-file checks miss CI failures.
- **Server tests need a DB:** integration tests under `server/tests/` require `DATABASE_URL` (run `./scripts/dev-up.sh` first) and use `mod common;` helpers (`fresh_store`, `seed_couple_room`, `handshake_as`, `spawn_server`, `next_frame`, `drain_rooms`). They are `#[serial_test::serial]`.

---

## Task ordering

1. Migration: `device_push_tokens` table
2. Store: token CRUD methods
3. Wire: `RegisterPush` / `UnregisterPush` frames (+ parse tests)
4. Push module: `PushSender` trait, payload builder, token-hygiene classifier (pure unit tests)
5. Config: `ApnsConfig::from_env`
6. `a2`-backed `ApnsSender` (real impl; not unit-tested)
7. Wire push into `AppState` + `main.rs` + test harness; handle the new frames; fire push from `handle_send` (WS integration test with a fake sender)
8. iOS: App Group + Push capability + entitlements (Xcode setup)
9. iOS: `AppDelegate` remote-notification registration + foreground suppression + tap forwarding (MethodChannel)
10. iOS: `PaletteArtwork` pure type + the Notification Service Extension target
11. iOS: `RunnerTests` XCTest for `PaletteArtwork.resolve`
12. Dart: `PushService` MethodChannel wrapper (unit test)
13. Dart: stable `device_id` + registration provider wired to the live socket
14. Dart: permission prompt after pairing + tap → open-room handler
15. Docs + manual on-device verification

---

### Task 1: Migration — `device_push_tokens` table

**Files:**
- Create: `server/migrations/0012_device_push_tokens.sql`
- Test: `server/tests/migration_0012_schema.rs`

**Interfaces:**
- Produces: table `device_push_tokens (account_id BIGINT, device_id TEXT, apns_token TEXT, environment TEXT, updated_at TIMESTAMPTZ)`, PK `(account_id, device_id)`, index `device_push_tokens_account_idx`.

- [ ] **Step 1: Write the failing schema test**

Create `server/tests/migration_0012_schema.rs`:

```rust
mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_creates_device_push_tokens_table() {
    let store = common::fresh_store().await;
    let cols: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='device_push_tokens'
           AND column_name IN ('account_id','device_id','apns_token','environment','updated_at')",
    )
    .fetch_all(store.pool())
    .await
    .unwrap();
    assert_eq!(cols.len(), 5, "expected all 5 columns, got {cols:?}");
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `cd server && DATABASE_URL=$DATABASE_URL cargo test --test migration_0012_schema -- --nocapture`
Expected: FAIL — table `device_push_tokens` does not exist (migration not yet added). (Ensure `./scripts/dev-up.sh` has run and `DATABASE_URL` is exported.)

- [ ] **Step 3: Write the migration**

Create `server/migrations/0012_device_push_tokens.sql`:

```sql
-- APNs device tokens, one row per (account, device). Schema-only: no backfill.
CREATE TABLE device_push_tokens (
  account_id   BIGINT      NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    TEXT        NOT NULL,
  apns_token   TEXT        NOT NULL,
  environment  TEXT        NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);

CREATE INDEX device_push_tokens_account_idx ON device_push_tokens (account_id);
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `cd server && cargo test --test migration_0012_schema`
Expected: PASS. (`fresh_store` runs `sqlx::migrate!` which applies `0012`.)

- [ ] **Step 5: Commit**

```bash
git add server/migrations/0012_device_push_tokens.sql server/tests/migration_0012_schema.rs
git commit -m "feat(server): device_push_tokens table (schema-only)"
```

---

### Task 2: Store — token CRUD

**Files:**
- Create: `server/src/push_tokens.rs`
- Modify: `server/src/lib.rs` (add `pub mod push_tokens;`)
- Test: `server/tests/push_tokens_store.rs`

**Interfaces:**
- Consumes: `Store::pool()` (`&PgPool`), `seed_two_humans` / `seed_couple_room` from `common`.
- Produces:
  - `pub struct DeviceToken { pub apns_token: String, pub environment: String }`
  - `pub async fn upsert_token(pool: &PgPool, account_id: i64, device_id: &str, apns_token: &str, environment: &str) -> anyhow::Result<()>`
  - `pub async fn delete_token(pool: &PgPool, account_id: i64, device_id: &str) -> anyhow::Result<()>`
  - `pub async fn tokens_for_account(pool: &PgPool, account_id: i64) -> anyhow::Result<Vec<DeviceToken>>`
  - `pub async fn delete_token_value(pool: &PgPool, account_id: i64, apns_token: &str) -> anyhow::Result<()>` (used by token hygiene)

- [ ] **Step 1: Write the failing store test**

Create `server/tests/push_tokens_store.rs`:

```rust
//! Store-level device push token CRUD: upsert is idempotent per (account,
//! device) and updates the token; delete removes it; load returns a couple's
//! own tokens only.

mod common;

use littlelove_api::push_tokens::{
    delete_token, delete_token_value, tokens_for_account, upsert_token,
};

#[tokio::test]
#[serial_test::serial]
async fn upsert_is_idempotent_and_updates_token() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;

    upsert_token(store.pool(), court, "dev-1", "tokenAAAA", "sandbox")
        .await
        .unwrap();
    // Re-register same device with a refreshed token: still one row, new value.
    upsert_token(store.pool(), court, "dev-1", "tokenBBBB", "production")
        .await
        .unwrap();

    let tokens = tokens_for_account(store.pool(), court).await.unwrap();
    assert_eq!(tokens.len(), 1, "one row per (account, device)");
    assert_eq!(tokens[0].apns_token, "tokenBBBB");
    assert_eq!(tokens[0].environment, "production");
}

#[tokio::test]
#[serial_test::serial]
async fn delete_by_device_and_by_value() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;

    upsert_token(store.pool(), court, "dev-1", "tokAAA", "sandbox")
        .await
        .unwrap();
    upsert_token(store.pool(), court, "dev-2", "tokBBB", "sandbox")
        .await
        .unwrap();

    delete_token(store.pool(), court, "dev-1").await.unwrap();
    let after = tokens_for_account(store.pool(), court).await.unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].apns_token, "tokBBB");

    // Token-hygiene path: delete by the token value (device id unknown to APNs).
    delete_token_value(store.pool(), court, "tokBBB").await.unwrap();
    assert!(tokens_for_account(store.pool(), court).await.unwrap().is_empty());
}
```

- [ ] **Step 2: Run it; verify it fails to compile**

Run: `cd server && cargo test --test push_tokens_store`
Expected: FAIL — `unresolved import littlelove_api::push_tokens`.

- [ ] **Step 3: Write the store module**

Create `server/src/push_tokens.rs`:

```rust
//! Persistence for APNs device push tokens. One row per (account, device);
//! re-registering a device upserts its current token + environment.

use sqlx::PgPool;

#[derive(Debug, Clone)]
pub struct DeviceToken {
    pub apns_token: String,
    pub environment: String,
}

/// Insert or refresh the token for one (account, device). Idempotent: a second
/// call for the same device updates the token, environment, and timestamp.
pub async fn upsert_token(
    pool: &PgPool,
    account_id: i64,
    device_id: &str,
    apns_token: &str,
    environment: &str,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO device_push_tokens (account_id, device_id, apns_token, environment, updated_at)
         VALUES ($1, $2, $3, $4, now())
         ON CONFLICT (account_id, device_id)
         DO UPDATE SET apns_token = EXCLUDED.apns_token,
                       environment = EXCLUDED.environment,
                       updated_at = now()",
    )
    .bind(account_id)
    .bind(device_id)
    .bind(apns_token)
    .bind(environment)
    .execute(pool)
    .await?;
    Ok(())
}

/// Remove a device's token (explicit unregister / logout).
pub async fn delete_token(pool: &PgPool, account_id: i64, device_id: &str) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM device_push_tokens WHERE account_id = $1 AND device_id = $2")
        .bind(account_id)
        .bind(device_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Token hygiene: APNs reports a token as dead by its value, not device id.
pub async fn delete_token_value(
    pool: &PgPool,
    account_id: i64,
    apns_token: &str,
) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM device_push_tokens WHERE account_id = $1 AND apns_token = $2")
        .bind(account_id)
        .bind(apns_token)
        .execute(pool)
        .await?;
    Ok(())
}

/// All registered tokens for an account (across the human's devices).
pub async fn tokens_for_account(pool: &PgPool, account_id: i64) -> anyhow::Result<Vec<DeviceToken>> {
    let rows = sqlx::query_as::<_, (String, String)>(
        "SELECT apns_token, environment FROM device_push_tokens WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(apns_token, environment)| DeviceToken {
            apns_token,
            environment,
        })
        .collect())
}
```

- [ ] **Step 4: Register the module**

In `server/src/lib.rs`, add the module in alphabetical position (after `pub mod invites;`):

```rust
pub mod push_tokens;
```

- [ ] **Step 5: Run the test; verify it passes**

Run: `cd server && cargo test --test push_tokens_store`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add server/src/push_tokens.rs server/src/lib.rs server/tests/push_tokens_store.rs
git commit -m "feat(server): device push token store CRUD"
```

---

### Task 3: Wire — `RegisterPush` / `UnregisterPush` frames

**Files:**
- Modify: `server/src/wire.rs` (add two `RoomClientFrame` variants + 2 parse tests)

**Interfaces:**
- Produces: `RoomClientFrame::RegisterPush { device_id: String, apns_token: String, environment: String }` and `RoomClientFrame::UnregisterPush { device_id: String }` (kind-tagged: `"RegisterPush"`, `"UnregisterPush"`).

- [ ] **Step 1: Write the failing parse tests**

In `server/src/wire.rs`, inside `mod tests`, add:

```rust
#[test]
fn parses_register_push_frame() {
    let raw = r#"{"kind":"RegisterPush","device_id":"dev-1","apns_token":"abcd","environment":"sandbox"}"#;
    let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
    match frame {
        RoomClientFrame::RegisterPush {
            device_id,
            apns_token,
            environment,
        } => {
            assert_eq!(device_id, "dev-1");
            assert_eq!(apns_token, "abcd");
            assert_eq!(environment, "sandbox");
        }
        _ => panic!("expected RegisterPush"),
    }
}

#[test]
fn parses_unregister_push_frame() {
    let raw = r#"{"kind":"UnregisterPush","device_id":"dev-1"}"#;
    let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
    assert!(matches!(frame, RoomClientFrame::UnregisterPush { device_id } if device_id == "dev-1"));
}
```

- [ ] **Step 2: Run; verify it fails to compile**

Run: `cd server && cargo test --lib wire::tests::parses_register_push_frame`
Expected: FAIL — no variant `RegisterPush`.

- [ ] **Step 3: Add the variants**

In `server/src/wire.rs`, in `enum RoomClientFrame`, after the `MarkRead { … }` variant add:

```rust
    /// Register (or refresh) this device's APNs token for the authenticated
    /// account. Sent after the OS grants notification permission and on token
    /// refresh.
    RegisterPush {
        device_id: String,
        apns_token: String,
        environment: String,
    },
    /// Drop this device's APNs token (logout / permission revoked).
    UnregisterPush {
        device_id: String,
    },
```

- [ ] **Step 4: Run; verify it passes**

Run: `cd server && cargo test --lib wire::tests::parses_register_push_frame wire::tests::parses_unregister_push_frame`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/wire.rs
git commit -m "feat(server): RegisterPush/UnregisterPush wire frames"
```

---

### Task 4: Push module — trait, payload builder, token-hygiene classifier

**Files:**
- Create: `server/src/push.rs`
- Modify: `server/src/lib.rs` (add `pub mod push;`)

**Interfaces:**
- Produces:
  - `pub const PUSH_TITLE: &str = "Little Love";`
  - `pub const PUSH_BODY: &str = "💜 Your partner sent you a message";`
  - `pub struct PushMessage { pub token: String, pub environment: String, pub room_id: String }`
  - `pub enum SendOutcome { Delivered, DropToken, Transient }`
  - `#[async_trait::async_trait] pub trait PushSender: Send + Sync { async fn send(&self, msg: &PushMessage) -> SendOutcome; }`
  - `pub fn should_push(delivered_sessions: usize) -> bool` (true iff 0)
  - `pub fn classify(code: u16, reason: Option<&str>) -> SendOutcome` (token-hygiene mapping)
- Consumes: nothing yet (the orchestration that ties this to the store/routing is Task 7).

This task adds the `async-trait` dependency.

- [ ] **Step 1: Add `async-trait` to Cargo**

In `server/Cargo.toml`, under `[dependencies]` (alphabetical, before `axum`... place after `anyhow.workspace = true`):

```toml
async-trait = "0.1"
```

- [ ] **Step 2: Write the failing unit tests**

Create `server/src/push.rs` with ONLY the tests + type stubs missing, OR write the full module then the tests. Write the module body (Step 3) first is fine, but TDD: add this `#[cfg(test)]` block to the file you create in Step 3 and confirm it fails before the functions exist. The tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pushes_only_when_no_live_session() {
        assert!(should_push(0));
        assert!(!should_push(1));
        assert!(!should_push(3));
    }

    #[test]
    fn classify_410_drops_the_token() {
        assert!(matches!(classify(410, Some("Unregistered")), SendOutcome::DropToken));
    }

    #[test]
    fn classify_bad_device_token_drops() {
        assert!(matches!(classify(400, Some("BadDeviceToken")), SendOutcome::DropToken));
        assert!(matches!(
            classify(400, Some("DeviceTokenNotForTopic")),
            SendOutcome::DropToken
        ));
    }

    #[test]
    fn classify_200_is_delivered() {
        assert!(matches!(classify(200, None), SendOutcome::Delivered));
    }

    #[test]
    fn classify_other_errors_are_transient() {
        assert!(matches!(classify(429, Some("TooManyRequests")), SendOutcome::Transient));
        assert!(matches!(classify(500, None), SendOutcome::Transient));
    }
}
```

- [ ] **Step 3: Write the module**

Create `server/src/push.rs`:

```rust
//! Push-notification composition + the `PushSender` seam. The actual APNs
//! transport (`ApnsSender`) lives behind the `PushSender` trait so the
//! send-trigger and token-hygiene logic is testable without a network.

use async_trait::async_trait;

/// Notification copy — generic and content-free (E2EE: the server never sees
/// the message, and we deliberately don't show content).
pub const PUSH_TITLE: &str = "Little Love";
pub const PUSH_BODY: &str = "💜 Your partner sent you a message";

/// One addressed push: the device token, its APNs environment, and the opaque
/// room id carried as custom data for tap deep-linking.
#[derive(Debug, Clone)]
pub struct PushMessage {
    pub token: String,
    pub environment: String,
    pub room_id: String,
}

/// What to do after a single send attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    /// APNs accepted the notification.
    Delivered,
    /// The token is permanently invalid — delete it.
    DropToken,
    /// A retryable / non-fatal error — keep the token, try again next time.
    Transient,
}

/// The transport seam. `ApnsSender` implements this over `a2`; tests use a fake.
#[async_trait]
pub trait PushSender: Send + Sync {
    async fn send(&self, msg: &PushMessage) -> SendOutcome;
}

/// We push only when the live fan-out reached zero sessions: an online partner
/// already got the message in-app and must not get a redundant banner.
pub fn should_push(delivered_sessions: usize) -> bool {
    delivered_sessions == 0
}

/// Map an APNs HTTP status + reason string to an action. 410 Unregistered and
/// the 400 "bad/foreign token" reasons mean the token is dead; everything else
/// non-2xx is transient.
pub fn classify(code: u16, reason: Option<&str>) -> SendOutcome {
    match (code, reason) {
        (200, _) => SendOutcome::Delivered,
        (410, _) => SendOutcome::DropToken,
        (400, Some("BadDeviceToken")) | (400, Some("DeviceTokenNotForTopic")) => {
            SendOutcome::DropToken
        }
        _ => SendOutcome::Transient,
    }
}
```

- [ ] **Step 4: Register the module**

In `server/src/lib.rs`, add (alphabetical, after `pub mod invites;`, before `pub mod push_tokens;`):

```rust
pub mod push;
```

- [ ] **Step 5: Run the tests; verify they pass**

Run: `cd server && cargo test --lib push::tests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add server/Cargo.toml server/src/push.rs server/src/lib.rs
git commit -m "feat(server): push module — PushSender trait, copy, trigger + hygiene logic"
```

---

### Task 5: Config — `ApnsConfig::from_env`

**Files:**
- Modify: `server/src/config.rs` (add `ApnsConfig`, field on `ServerConfig`, env parsing + a serial test)

**Interfaces:**
- Consumes: `ServerConfig::from_env`.
- Produces: `pub struct ApnsConfig { pub key_p8: String, pub key_id: String, pub team_id: String, pub topic: String, pub environment: String }`; `ServerConfig.apns: Option<ApnsConfig>`.

- [ ] **Step 1: Write the failing test**

In `server/src/config.rs`, inside `mod tests`, add (note: `#[serial]` like the others):

```rust
#[test]
#[serial]
fn apns_config_present_when_all_vars_set() {
    for (k, v) in [
        ("APNS_KEY_P8", "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----"),
        ("APNS_KEY_ID", "KEY123"),
        ("APNS_TEAM_ID", "TEAM456"),
        ("APNS_TOPIC", "dev.littlelove.littlelove"),
        ("APNS_ENV", "sandbox"),
    ] {
        std::env::set_var(k, v);
    }
    let cfg = ServerConfig::from_env();
    let apns = cfg.apns.expect("apns config Some when all vars set");
    assert_eq!(apns.key_id, "KEY123");
    assert_eq!(apns.topic, "dev.littlelove.littlelove");
    assert_eq!(apns.environment, "sandbox");
    for k in ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_ENV"] {
        std::env::remove_var(k);
    }
}

#[test]
#[serial]
fn apns_config_absent_when_vars_missing() {
    for k in ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_ENV"] {
        std::env::remove_var(k);
    }
    assert!(ServerConfig::from_env().apns.is_none());
}
```

- [ ] **Step 2: Run; verify it fails to compile**

Run: `cd server && cargo test --lib config::tests::apns_config_present_when_all_vars_set`
Expected: FAIL — no field `apns` on `ServerConfig`.

- [ ] **Step 3: Add `ApnsConfig` + parsing**

In `server/src/config.rs`, add the struct after `R2Config`:

```rust
#[derive(Debug, Clone)]
pub struct ApnsConfig {
    /// Contents of the `.p8` APNs auth key (PEM). Provided directly, not a path,
    /// so it travels as a single deploy secret.
    pub key_p8: String,
    pub key_id: String,
    pub team_id: String,
    /// APNs topic — the app bundle id.
    pub topic: String,
    /// `sandbox` (dev builds) or `production`.
    pub environment: String,
}
```

Add the field to `ServerConfig`:

```rust
    pub apns: Option<ApnsConfig>,
```

In `ServerConfig::from_env`, after `let r2 = Self::r2_from_env();` add `let apns = Self::apns_from_env();` and include `apns` in the returned struct. Then add the parser method:

```rust
    fn apns_from_env() -> Option<ApnsConfig> {
        let get = |k: &str| std::env::var(k).ok().filter(|s| !s.is_empty());
        Some(ApnsConfig {
            key_p8: get("APNS_KEY_P8")?,
            key_id: get("APNS_KEY_ID")?,
            team_id: get("APNS_TEAM_ID")?,
            topic: get("APNS_TOPIC")?,
            environment: get("APNS_ENV").unwrap_or_else(|| "sandbox".to_string()),
        })
    }
```

- [ ] **Step 4: Run; verify it passes**

Run: `cd server && cargo test --lib config::tests`
Expected: PASS (all config tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add server/src/config.rs
git commit -m "feat(server): ApnsConfig::from_env (push disabled when unset)"
```

---

### Task 6: `a2`-backed `ApnsSender`

**Files:**
- Modify: `server/Cargo.toml` (add `a2`)
- Modify: `server/src/push.rs` (add `ApnsSender` + constructor)

**Interfaces:**
- Consumes: `ApnsConfig`, `PushMessage`, `SendOutcome`, `classify`, `PUSH_TITLE`, `PUSH_BODY`.
- Produces: `pub struct ApnsSender { … }` with `pub fn new(cfg: &ApnsConfig) -> anyhow::Result<Self>` implementing `PushSender`.

This task has no unit test (it wraps the network client); it's covered by manual on-device testing (Task 15) and compiled by `cargo build`.

- [ ] **Step 1: Add `a2` to Cargo**

In `server/Cargo.toml` `[dependencies]`, add (alphabetical, first entry):

```toml
a2 = "0.10"
```

- [ ] **Step 2: Implement `ApnsSender`**

Append to `server/src/push.rs` (above the `#[cfg(test)]` block):

```rust
use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions, PushType,
};
use std::sync::Arc;
use tracing::warn;

/// `a2`-backed APNs transport. Holds one HTTP/2 client per environment so a
/// couple's mixed sandbox/production tokens both work from a single sender.
pub struct ApnsSender {
    sandbox: Arc<Client>,
    production: Arc<Client>,
    topic: String,
}

impl ApnsSender {
    pub fn new(cfg: &crate::config::ApnsConfig) -> anyhow::Result<Self> {
        let mk = |endpoint: Endpoint| -> anyhow::Result<Client> {
            let mut pem = cfg.key_p8.as_bytes();
            let client = Client::token(
                &mut pem,
                &cfg.key_id,
                &cfg.team_id,
                ClientConfig::new(endpoint),
            )?;
            Ok(client)
        };
        Ok(Self {
            sandbox: Arc::new(mk(Endpoint::Sandbox)?),
            production: Arc::new(mk(Endpoint::Production)?),
            topic: cfg.topic.clone(),
        })
    }

    fn client_for(&self, environment: &str) -> &Client {
        if environment == "production" {
            &self.production
        } else {
            &self.sandbox
        }
    }
}

#[async_trait]
impl PushSender for ApnsSender {
    async fn send(&self, msg: &PushMessage) -> SendOutcome {
        let options = NotificationOptions {
            apns_topic: Some(self.topic.as_str()),
            apns_push_type: Some(PushType::Alert),
            ..Default::default()
        };
        let mut payload = DefaultNotificationBuilder::new()
            .set_title(PUSH_TITLE)
            .set_body(PUSH_BODY)
            .set_sound("default")
            .set_mutable_content()
            .build(msg.token.as_str(), options);
        // Opaque room id for the tap deep-link. No message content; E2EE intact.
        if let Err(e) = payload.add_custom_data("room_id", &msg.room_id) {
            warn!("push: add_custom_data failed: {e}");
            return SendOutcome::Transient;
        }

        match self.client_for(&msg.environment).send(payload).await {
            Ok(resp) => classify(resp.code, None),
            Err(a2::Error::ResponseError(resp)) => {
                let reason = resp.error.as_ref().map(|e| format!("{:?}", e.reason));
                classify(resp.code, reason.as_deref())
            }
            Err(e) => {
                warn!("push: APNs send error: {e}");
                SendOutcome::Transient
            }
        }
    }
}
```

> Implementer note: `a2` 0.10 — `Client::token(&mut impl Read, key_id, team_id, ClientConfig)`, `DefaultNotificationBuilder::{set_title,set_body,set_sound,set_mutable_content,build}`, `build(device_token, NotificationOptions)`, `Payload::add_custom_data(root_key, &Serialize)`, `Client::send(payload) -> Result<Response, a2::Error>`. The error response is `a2::Error::ResponseError(Response)` with `Response { code: u16, error: Option<ErrorBody> }` and `ErrorBody { reason: ErrorReason }`. `classify` only needs `code` plus the `Debug`-rendered reason string (`"BadDeviceToken"`, `"DeviceTokenNotForTopic"`), so exact variant identifiers don't need importing. If a name differs in the pinned version, adjust the match in `classify`/here, not the trigger logic.

- [ ] **Step 3: Build; verify it compiles**

Run: `cd server && cargo build`
Expected: SUCCESS. If `a2`'s `Endpoint`/`ResponseError`/field names differ, fix per the implementer note until it builds. Re-run `cargo test --lib push::tests` — still PASS.

- [ ] **Step 4: Commit**

```bash
git add server/Cargo.toml server/Cargo.lock server/src/push.rs
git commit -m "feat(server): a2-backed ApnsSender behind PushSender"
```

---

### Task 7: Wire push into the send path

**Files:**
- Modify: `server/src/ws.rs` (`AppState` gets a `push` field; handle the two new frames; fire push from `handle_send`)
- Modify: `server/src/main.rs` (construct `ApnsSender` when configured)
- Modify: `server/tests/common/mod.rs` (`AppState` + `build_app`/`spawn_server` accept a `PushSender`)
- Test: `server/tests/push_send_ws.rs`

**Interfaces:**
- Consumes: `push::{PushSender, PushMessage, should_push}`, `push_tokens::{tokens_for_account, upsert_token, delete_token, delete_token_value}`, `Routing::deliver` (returns `usize`).
- Produces: `AppState.push: Option<std::sync::Arc<dyn PushSender>>`; behavior: a push fires for the recipient iff `deliver` returned 0 and the recipient has tokens.

- [ ] **Step 1: Write the failing WS integration test**

Create `server/tests/push_send_ws.rs`. It installs a fake `PushSender` that reports each call over a channel, registers a token for kaitlyn, then asserts: offline kaitlyn → push fired; online kaitlyn → no push.

```rust
//! End-to-end: a push fires for the recipient only when they have no live WS
//! session. Uses a fake PushSender (no network).

mod common;

use std::sync::Arc;

use littlelove_api::push::{PushMessage, PushSender, SendOutcome};
use littlelove_api::push_tokens::upsert_token;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMessage;

struct FakeSender {
    calls: mpsc::UnboundedSender<PushMessage>,
}

#[async_trait::async_trait]
impl PushSender for FakeSender {
    async fn send(&self, msg: &PushMessage) -> SendOutcome {
        let _ = self.calls.send(msg.clone());
        SendOutcome::Delivered
    }
}

#[tokio::test]
#[serial_test::serial]
async fn push_fires_when_recipient_offline_not_when_online() {
    let store = common::fresh_store().await;
    let (court_id, kait_id, room) = common::seed_couple_room(&store).await;

    // Kaitlyn has a registered device token.
    upsert_token(store.pool(), kait_id, "kait-dev", "kaitTOKEN", "sandbox")
        .await
        .unwrap();

    let (tx, mut rx) = mpsc::unbounded_channel::<PushMessage>();
    let fake: Arc<dyn PushSender> = Arc::new(FakeSender { calls: tx });
    let addr = common::spawn_server_with_push(Some(store.clone()), Some(fake)).await;

    let court_sk = common::signing_key_from_seed([10u8; 32]); // matches seed bytes? use helper
    // ... (see note) ...
    let _ = (court_id, room);

    // court connects and sends while kaitlyn is OFFLINE.
    let mut court = common::handshake_as(addr, "court", &court_sk).await;
    common::drain_rooms(&mut court).await;
    let body = common::send_one_text(&mut court, &room, &store, court_id, kait_id).await;
    let _ = body;

    // The push should have fired for kaitlyn (offline → 0 sessions delivered).
    let got = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
        .await
        .expect("a push should fire for the offline recipient")
        .unwrap();
    assert_eq!(got.token, "kaitTOKEN");
    assert_eq!(got.room_id, room);

    // Now kaitlyn comes ONLINE; a second send must NOT push.
    let kait_sk = common::signing_key_from_seed([20u8; 32]);
    let mut kait = common::handshake_as(addr, "kaitlyn", &kait_sk).await;
    common::drain_rooms(&mut kait).await;
    // kaitlyn subscribes so she's a live session for the room.
    kait.send(WsMessage::Text(
        serde_json::json!({"kind":"Subscribe","room_id":room,"since_message_id":null}).to_string(),
    ))
    .await
    .unwrap();

    common::send_one_text(&mut court, &room, &store, court_id, kait_id).await;

    // No push within a short window.
    let none = tokio::time::timeout(std::time::Duration::from_millis(500), rx.recv()).await;
    assert!(none.is_err(), "online recipient must not get a push");
}
```

> Note: the existing `common` helpers seed accounts with deterministic ed25519 bytes (`vec![10u8;32]` for court, `vec![20u8;32]` for kaitlyn) that are NOT valid signing keys for `handshake_as`. This test needs real keys. Add a helper `seed_couple_room_with_keys` OR reuse the approach in `tests/read_receipts_ws.rs`. **Before writing this test, open `server/tests/read_receipts_ws.rs` and copy its exact two-client setup** (it already solves "two real signing keys + a couple room + send + observe"), then add the token registration + fake sender on top. Implement `common::send_one_text(...)` as a thin wrapper around whatever that file does to send one message, returning the body. If `read_receipts_ws.rs` inserts messages via the store rather than a `Send` frame, drive the real `Send` frame here instead so the `handle_send` hook actually runs.

- [ ] **Step 2: Add the `PushSender` seam to the test harness**

In `server/tests/common/mod.rs`:
- import `use littlelove_api::push::PushSender;` and `use std::sync::Arc;`
- change `build_app` to accept `push: Option<Arc<dyn PushSender>>` and set it on `AppState`.
- keep the old zero-arg ergonomics by adding `spawn_server_with_push(store, push)` and making `spawn_server(store)` call it with `None`.

```rust
pub fn build_app_with_push(
    store: Option<Store>,
    push: Option<Arc<dyn PushSender>>,
) -> Router {
    let state = AppState {
        routing: Routing::new(),
        store,
        r2: Some(test_presigner()),
        push,
    };
    Router::new()
        .route("/accounts", post(create_account))
        .route("/accounts/by-username/:username", get(get_account_by_username))
        .route("/invites/:code/preview", post(preview_invite))
        .route("/ws", get(ws_handler))
        .with_state(state)
}

pub fn build_app(store: Option<Store>) -> Router {
    build_app_with_push(store, None)
}

pub async fn spawn_server_with_push(
    store: Option<Store>,
    push: Option<Arc<dyn PushSender>>,
) -> SocketAddr {
    let app = build_app_with_push(store, push);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    addr
}
```

- [ ] **Step 3: Add the field to `AppState` and the send hook**

In `server/src/ws.rs`:

Add the field and imports. At the top, extend the `use crate::...` lines:

```rust
use crate::push::{should_push, PushMessage, PushSender};
use crate::push_tokens::{delete_token, delete_token_value, tokens_for_account, upsert_token};
use std::sync::Arc;
```

Change `AppState`:

```rust
#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
    pub r2: Option<crate::r2::R2Presigner>,
    pub push: Option<Arc<dyn PushSender>>,
}
```

In `handle_send`, replace the per-member live-delivery loop (currently lines ~712-731, the `for m in &members { … state.routing.deliver(&m.username, frame).await; }`) with one that captures the delivered count and fires a push when it was zero:

```rust
    for m in &members {
        if m.account_id == me.id {
            continue;
        }
        let key = B64.encode(&m.x25519_pub);
        let Some(body) = bodies.get(&key) else {
            continue;
        };
        let frame = RoomServerFrame::Message {
            id: id.clone(),
            room_id: room_id.to_string(),
            from: me.username.clone(),
            ts,
            body: body.clone(),
            replayed: false,
            read: false,
            client_msg_id: None,
        };
        let delivered = state.routing.deliver(&m.username, frame).await;
        // Offline recipient → notify their registered devices. Spawned so the
        // APNs round-trip never blocks the sender's ack.
        if should_push(delivered) {
            if let (Some(sender), Some(store)) = (state.push.clone(), state.store.clone()) {
                let recipient_id = m.account_id;
                let room = room_id.to_string();
                tokio::spawn(async move {
                    notify_recipient(&sender, &store, recipient_id, &room).await;
                });
            }
        }
    }
```

Add the helper at the end of `ws.rs` (above `#[cfg(test)]`):

```rust
/// Fan a single content-free push out to every registered device of an offline
/// recipient, deleting any token APNs reports as permanently dead.
async fn notify_recipient(
    sender: &Arc<dyn PushSender>,
    store: &Store,
    recipient_account_id: i64,
    room_id: &str,
) {
    let tokens = match tokens_for_account(store.pool(), recipient_account_id).await {
        Ok(t) => t,
        Err(e) => {
            warn!("push: tokens_for_account failed: {e}");
            return;
        }
    };
    for t in tokens {
        let msg = PushMessage {
            token: t.apns_token.clone(),
            environment: t.environment,
            room_id: room_id.to_string(),
        };
        if let crate::push::SendOutcome::DropToken = sender.send(&msg).await {
            if let Err(e) =
                delete_token_value(store.pool(), recipient_account_id, &t.apns_token).await
            {
                warn!("push: delete_token_value failed: {e}");
            }
        }
    }
}
```

- [ ] **Step 4: Handle the two new frames in the WS loop**

In `handle_socket`'s `match serde_json::from_str::<RoomClientFrame>(&text)`, add two arms (after the `MarkRead` arm):

```rust
                Ok(RoomClientFrame::RegisterPush {
                    device_id,
                    apns_token,
                    environment,
                }) => {
                    if let Some(store) = state.store.as_ref() {
                        if let Err(e) =
                            upsert_token(store.pool(), me.id, &device_id, &apns_token, &environment)
                                .await
                        {
                            warn!("RegisterPush upsert failed: {e}");
                        }
                    }
                }
                Ok(RoomClientFrame::UnregisterPush { device_id }) => {
                    if let Some(store) = state.store.as_ref() {
                        if let Err(e) = delete_token(store.pool(), me.id, &device_id).await {
                            warn!("UnregisterPush delete failed: {e}");
                        }
                    }
                }
```

- [ ] **Step 5: Construct the sender in `main.rs`**

In `server/src/main.rs`, after the `r2` block and before `let state = AppState { … }`, add:

```rust
    let push: Option<std::sync::Arc<dyn littlelove_api::push::PushSender>> =
        match cfg.apns.as_ref() {
            Some(apnscfg) => match littlelove_api::push::ApnsSender::new(apnscfg) {
                Ok(s) => Some(std::sync::Arc::new(s)),
                Err(e) => {
                    tracing::warn!("APNs sender init failed; push disabled: {e}");
                    None
                }
            },
            None => {
                tracing::warn!("APNS_* env unset; push notifications disabled");
                None
            }
        };
```

and add `push,` to the `AppState { … }` initializer.

- [ ] **Step 6: Run everything; verify green**

Run:
```
cd server && cargo build && \
cargo test --lib push::tests && \
cargo test --test push_send_ws && \
cargo test --test read_receipts_ws --test rooms_routing
```
Expected: PASS. (The last two confirm the `build_app` signature change didn't break existing WS tests.)

- [ ] **Step 7: Lint + commit**

```bash
cd server && cargo fmt && cargo clippy --all-targets -- -D warnings
git add server/src/ws.rs server/src/main.rs server/tests/common/mod.rs server/tests/push_send_ws.rs
git commit -m "feat(server): fire content-free push when recipient has no live session"
```

---

### Task 8: iOS — App Group, Push capability, entitlements (Xcode setup)

**Files:**
- Create: `app/ios/Runner/Runner.entitlements`
- Modify: `app/ios/Runner.xcodeproj/project.pbxproj` (via Xcode UI — capabilities)

This is GUI setup; there's no automated test. The deliverable is verified by a clean build with the capabilities present.

- [ ] **Step 1: Add capabilities in Xcode**

Open `app/ios/Runner.xcworkspace` in Xcode. Select the **Runner** target → **Signing & Capabilities**:
- Confirm Team is `9PVUX2535W` and bundle id `dev.littlelove.littlelove`.
- Click **+ Capability** → add **Push Notifications**.
- Click **+ Capability** → add **App Groups**; add group **`group.dev.littlelove.littlelove`** (check it on).

This creates/updates `app/ios/Runner/Runner.entitlements`.

- [ ] **Step 2: Verify the entitlements file**

`app/ios/Runner/Runner.entitlements` should contain at least:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.dev.littlelove.littlelove</string>
    </array>
</dict>
</plist>
```

(`aps-environment` is `development` for dev/sandbox; the release build flips it to `production` — Xcode manages this via the build setting, leave it as Xcode wrote it.)

- [ ] **Step 3: Build to confirm capabilities compile**

Run: `cd app && flutter build ios --config-only` then build in Xcode (⌘B) targeting a connected device, OR `./scripts/ios-deploy.sh --server <dev-url>` (a full build). Expected: build succeeds with no signing/entitlement errors.

- [ ] **Step 4: Commit**

```bash
git add app/ios/Runner/Runner.entitlements app/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): Push Notifications + App Group capabilities"
```

---

### Task 9: iOS — `AppDelegate` registration, foreground suppression, tap forwarding

**Files:**
- Modify: `app/ios/Runner/AppDelegate.swift`

**Interfaces:**
- Produces: a Flutter `MethodChannel` named `little_love/push` with:
  - host→Dart method `onToken` (arg: hex token string), `onTap` (arg: room_id string)
  - Dart→host methods `requestPermission` (returns Bool granted), `takePendingLaunchRoom` (returns room_id String? once)
- Consumes: nothing from other tasks.

- [ ] **Step 1: Replace `AppDelegate.swift`**

```swift
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  /// A room id captured from a notification tap that cold-launched the app,
  /// held until Dart asks for it once the inbox is ready.
  private var pendingLaunchRoomId: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.pluginRegistry.messenger()
    let channel = FlutterMethodChannel(name: "little_love/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "requestPermission":
        self.requestPermission(result)
      case "takePendingLaunchRoom":
        let room = self.pendingLaunchRoomId
        self.pendingLaunchRoomId = nil
        result(room)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.pushChannel = channel
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, _ in
      if granted {
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
      }
      result(granted)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod("onToken", arguments: hex)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("little_love: remote notification registration failed: \(error)")
  }

  // Foreground: suppress the banner — the in-app UI already shows the message.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  // Tap: deep-link to the room. Buffer it if Dart isn't ready (cold launch).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let roomId = response.notification.request.content.userInfo["room_id"] as? String {
      pendingLaunchRoomId = roomId
      pushChannel?.invokeMethod("onTap", arguments: roomId)
    }
    completionHandler()
  }
}
```

- [ ] **Step 2: Build; verify it compiles**

Run: `cd app && flutter build ios --config-only` then ⌘B in Xcode (or `./scripts/ios-deploy.sh`).
Expected: compiles. (Behavior is verified end-to-end in Task 15.)

- [ ] **Step 3: Commit**

```bash
git add app/ios/Runner/AppDelegate.swift
git commit -m "feat(ios): APNs registration, foreground suppression, tap→room channel"
```

---

### Task 10: iOS — `PaletteArtwork` + Notification Service Extension

**Files:**
- Create: `app/ios/Shared/PaletteArtwork.swift` (target membership: Runner + the extension)
- Create: `app/ios/NotificationService/NotificationService.swift`
- Create: `app/ios/NotificationService/Info.plist` (Xcode generates)
- Create: `app/ios/NotificationService/NotificationService.entitlements` (App Group)
- Add the extension's palette asset(s) (one: `twilight`) to the extension's asset catalog
- Modify: `app/ios/Runner.xcodeproj/project.pbxproj` (new target — via Xcode UI)

**Interfaces:**
- Produces: `enum PaletteArtwork { static func resolve(forKey key: String?) -> String }` returning an asset name; default `"twilight"`.
- Consumes: App Group `group.dev.littlelove.littlelove`, the palette key written by Dart under `UserDefaults(suiteName:)` key `selected_palette`.

- [ ] **Step 1: Create the pure, testable `PaletteArtwork`**

Create `app/ios/Shared/PaletteArtwork.swift`:

```swift
import Foundation

/// Maps a palette key (written by the app into the shared App Group) to the
/// bundled artwork asset name the Notification Service Extension attaches.
/// Pure and dependency-free so it is unit-testable in isolation. Today only
/// `twilight` ships; future palettes add a case here + an asset.
enum PaletteArtwork {
  static let appGroupId = "group.dev.littlelove.littlelove"
  static let paletteDefaultsKey = "selected_palette"
  static let defaultAsset = "twilight"

  /// Resolve a palette key to an asset name. Unknown / missing keys fall back
  /// to the default — never crash, never return empty.
  static func resolve(forKey key: String?) -> String {
    switch key {
    case "twilight":
      return "twilight"
    default:
      return defaultAsset
    }
  }
}
```

In Xcode, set this file's **Target Membership** to BOTH `Runner` and `NotificationService` (after the extension target exists in Step 3). It lives under `app/ios/Shared/` so neither target "owns" it exclusively.

- [ ] **Step 2: Add the Notification Service Extension target (Xcode UI)**

In Xcode: **File → New → Target… → Notification Service Extension**. Name it **NotificationService**. Product bundle id will be `dev.littlelove.littlelove.NotificationService`, Team `9PVUX2535W`. When prompted to activate the scheme, click Activate.

Then select the **NotificationService** target → **Signing & Capabilities** → **+ Capability → App Groups** → check **`group.dev.littlelove.littlelove`**. This writes `NotificationService.entitlements`.

- [ ] **Step 3: Implement the extension**

Replace the generated `app/ios/NotificationService/NotificationService.swift`:

```swift
import UserNotifications

/// Runs on each incoming push (the server sets `mutable-content: 1`). Reads the
/// currently-selected palette from the shared App Group and attaches the
/// matching bundled artwork. On any failure it delivers the original content
/// unchanged (graceful degradation — the push still shows as plain text).
class NotificationService: UNNotificationServiceExtension {
  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
    self.bestAttempt = mutable
    guard let content = mutable else {
      contentHandler(request.content)
      return
    }

    let defaults = UserDefaults(suiteName: PaletteArtwork.appGroupId)
    let key = defaults?.string(forKey: PaletteArtwork.paletteDefaultsKey)
    let asset = PaletteArtwork.resolve(forKey: key)

    if let attachment = Self.attachment(named: asset) {
      content.attachments = [attachment]
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }

  /// Build a notification attachment from a bundled image asset. Returns nil on
  /// any failure so the caller falls back to the plain notification.
  private static func attachment(named asset: String) -> UNNotificationAttachment? {
    guard let image = UIImage(named: asset),
      let data = image.pngData()
    else { return nil }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent("\(asset).png")
      try data.write(to: url)
      return try UNNotificationAttachment(identifier: asset, url: url, options: nil)
    } catch {
      return nil
    }
  }
}
```

Add `import UIKit` at the top if `UIImage` isn't resolved by `UserNotifications` alone.

- [ ] **Step 4: Add the palette asset**

In the **NotificationService** target's asset catalog (`Assets.xcassets`), add an image set named **`twilight`** with the brand artwork (a square PNG drawn in the Twilight palette — e.g. a mauve heart card). One entry only for now.

- [ ] **Step 5: Build; verify it compiles**

Run: ⌘B in Xcode (or `./scripts/ios-deploy.sh`). Expected: both Runner and NotificationService compile and `PaletteArtwork.swift` is in both targets.

- [ ] **Step 6: Commit**

```bash
git add app/ios/Shared/PaletteArtwork.swift app/ios/NotificationService app/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): Notification Service Extension + palette artwork resolution"
```

---

### Task 11: iOS — XCTest for `PaletteArtwork.resolve`

**Files:**
- Create: `app/ios/RunnerTests/PaletteArtworkTests.swift` (in the existing `RunnerTests` target)

**Interfaces:**
- Consumes: `PaletteArtwork.resolve` (via `@testable import Runner` — `PaletteArtwork.swift` is a member of the Runner target).

- [ ] **Step 1: Write the failing test**

Create `app/ios/RunnerTests/PaletteArtworkTests.swift`:

```swift
import XCTest
@testable import Runner

final class PaletteArtworkTests: XCTestCase {
  func testKnownKeyResolvesToItsAsset() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: "twilight"), "twilight")
  }

  func testUnknownKeyFallsBackToDefault() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: "midnight-future-palette"), PaletteArtwork.defaultAsset)
  }

  func testNilKeyFallsBackToDefault() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: nil), PaletteArtwork.defaultAsset)
  }

  func testEmptyKeyFallsBackToDefault() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: ""), PaletteArtwork.defaultAsset)
  }
}
```

- [ ] **Step 2: Run; verify it passes (the type already exists from Task 10)**

Run (a connected simulator or device must be available):
```
cd app/ios && xcodebuild test \
  -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:RunnerTests/PaletteArtworkTests
```
Expected: TEST SUCCEEDED (4 tests). If `PaletteArtwork` isn't visible to `@testable import Runner`, confirm `PaletteArtwork.swift` has Runner target membership.

- [ ] **Step 3: Commit**

```bash
git add app/ios/RunnerTests/PaletteArtworkTests.swift
git commit -m "test(ios): PaletteArtwork.resolve fallback behavior"
```

---

### Task 12: Dart — `PushService` MethodChannel wrapper

**Files:**
- Create: `app/lib/push/push_service.dart`
- Test: `app/test/push/push_service_test.dart`

**Interfaces:**
- Produces:
  - `class PushService` wrapping `MethodChannel('little_love/push')`:
    - `Future<bool> requestPermission()`
    - `Future<String?> takePendingLaunchRoom()`
    - `void onToken(void Function(String hexToken) cb)`
    - `void onTap(void Function(String roomId) cb)`
  - constructor `PushService({MethodChannel? channel})` for test injection.

- [ ] **Step 1: Write the failing test**

Create `app/test/push/push_service_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/push/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('little_love/push');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('requestPermission returns the native grant result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestPermission') return true;
      return null;
    });
    final svc = PushService();
    expect(await svc.requestPermission(), isTrue);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('takePendingLaunchRoom forwards the native value', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingLaunchRoom') return '01ROOM';
      return null;
    });
    final svc = PushService();
    expect(await svc.takePendingLaunchRoom(), '01ROOM');
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('onToken fires when native invokes onToken', () async {
    final svc = PushService();
    String? got;
    svc.onToken((t) => got = t);
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('onToken', 'deadbeef')),
      (_) {},
    );
    expect(got, 'deadbeef');
  });
}
```

- [ ] **Step 2: Run; verify it fails**

Run: `cd app && flutter test test/push/push_service_test.dart`
Expected: FAIL — `package:littlelove/push/push_service.dart` not found.

- [ ] **Step 3: Implement `PushService`**

Create `app/lib/push/push_service.dart`:

```dart
import 'package:flutter/services.dart';

/// Dart side of the native push bridge (`little_love/push`). Wraps permission
/// requests, the cold-launch room handoff, and the host→Dart token/tap events.
class PushService {
  PushService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('little_love/push') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  void Function(String hexToken)? _onToken;
  void Function(String roomId)? _onTap;

  /// Ask the OS for notification permission. Returns whether it was granted.
  Future<bool> requestPermission() async {
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }

  /// Drain a room id captured from a notification tap that cold-launched the
  /// app. Returns null if there was none.
  Future<String?> takePendingLaunchRoom() =>
      _channel.invokeMethod<String?>('takePendingLaunchRoom');

  /// Register a callback for APNs token delivery / refresh.
  void onToken(void Function(String hexToken) cb) => _onToken = cb;

  /// Register a callback for a live notification tap (app already running).
  void onTap(void Function(String roomId) cb) => _onTap = cb;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final t = call.arguments as String?;
        if (t != null) _onToken?.call(t);
        return null;
      case 'onTap':
        final r = call.arguments as String?;
        if (r != null) _onTap?.call(r);
        return null;
      default:
        return null;
    }
  }
}
```

- [ ] **Step 4: Run; verify it passes**

Run: `cd app && flutter test test/push/push_service_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/push/push_service.dart app/test/push/push_service_test.dart
git commit -m "feat(app): PushService MethodChannel wrapper"
```

---

### Task 13: Dart — stable device id, palette write, registration provider

**Files:**
- Create: `app/lib/push/push_registration.dart`
- Test: `app/test/push/device_id_test.dart`

**Interfaces:**
- Consumes: `PushService` (Task 12); `liveConnectionProvider` (`app/lib/wire/live_connection.dart`); `flutter_secure_storage`; `RegisterPushFrame` / `UnregisterPushFrame` (added below to `frames.dart`).
- Produces:
  - in `app/lib/wire/frames.dart`: `RegisterPushFrame { deviceId, apnsToken, environment }.toJson()` and `UnregisterPushFrame { deviceId }.toJson()`
  - `Future<String> stableDeviceId(FlutterSecureStorage storage)` — persistent per-install UUID
  - `final pushRegistrationProvider = Provider<PushRegistration>(...)` that, given the live connection + a token from `PushService.onToken`, sends `RegisterPush`.

- [ ] **Step 1: Add the outbound frames**

In `app/lib/wire/frames.dart`, under `// ---------- Outbound ----------`, add:

```dart
class RegisterPushFrame {
  const RegisterPushFrame({
    required this.deviceId,
    required this.apnsToken,
    required this.environment,
  });
  final String deviceId;
  final String apnsToken;
  final String environment;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RegisterPush',
    'device_id': deviceId,
    'apns_token': apnsToken,
    'environment': environment,
  };
}

class UnregisterPushFrame {
  const UnregisterPushFrame({required this.deviceId});
  final String deviceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'UnregisterPush',
    'device_id': deviceId,
  };
}
```

- [ ] **Step 2: Write the failing device-id test**

Create `app/test/push/device_id_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/push/push_registration.dart';

class _MapStore implements DeviceIdStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

void main() {
  test('stableDeviceId persists across calls', () async {
    final store = _MapStore();
    final first = await stableDeviceId(store);
    final second = await stableDeviceId(store);
    expect(first, isNotEmpty);
    expect(first, second, reason: 'device id must be stable per install');
  });
}
```

- [ ] **Step 3: Implement registration**

Create `app/lib/push/push_registration.dart`:

```dart
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'push_service.dart';

/// Minimal key/value seam so the device-id logic is testable without the
/// platform keychain.
abstract class DeviceIdStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureDeviceIdStore implements DeviceIdStore {
  SecureDeviceIdStore(this._storage);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

const _deviceIdKey = 'push_device_id';

/// A UUID minted once per install and reused thereafter. Identifies this
/// device's token row server-side so re-registration upserts in place.
Future<String> stableDeviceId(DeviceIdStore store) async {
  final existing = await store.read(_deviceIdKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final fresh = const Uuid().v4();
  await store.write(_deviceIdKey, fresh);
  return fresh;
}

/// Sandbox for debug/profile builds, production for release. APNs tokens are
/// environment-specific, so we tell the server which to send through.
String currentApnsEnvironment() {
  // Release (no asserts) → production; debug/profile → sandbox.
  var inDebug = false;
  assert(() {
    inDebug = true;
    return true;
  }());
  return inDebug ? 'sandbox' : 'production';
}

/// Wires the native token stream to the live socket: when a token arrives,
/// send a RegisterPush over the current connection. No-op while offline; the
/// next token delivery (or app resume) re-sends.
class PushRegistration {
  PushRegistration(this._ref, this._push, this._deviceIdStore);

  final Ref _ref;
  final PushService _push;
  final DeviceIdStore _deviceIdStore;
  String? _lastToken;

  void start() {
    _push.onToken((hexToken) {
      _lastToken = hexToken;
      _sendRegister(hexToken);
    });
  }

  Future<void> _sendRegister(String hexToken) async {
    final conn = _ref.read(liveConnectionProvider).valueOrNull;
    if (conn == null) return;
    final deviceId = await stableDeviceId(_deviceIdStore);
    conn.send(
      RegisterPushFrame(
        deviceId: deviceId,
        apnsToken: hexToken,
        environment: currentApnsEnvironment(),
      ).toJson(),
    );
  }

  /// Re-send the last known token (call on reconnect / app resume).
  Future<void> resend() async {
    final t = _lastToken;
    if (t != null) await _sendRegister(t);
  }

  Future<void> unregister() async {
    final conn = _ref.read(liveConnectionProvider).valueOrNull;
    if (conn == null) return;
    final deviceId = await stableDeviceId(_deviceIdStore);
    conn.send(UnregisterPushFrame(deviceId: deviceId).toJson());
  }
}

final pushServiceProvider = Provider<PushService>((_) => PushService());

final pushRegistrationProvider = Provider<PushRegistration>((ref) {
  final reg = PushRegistration(
    ref,
    ref.watch(pushServiceProvider),
    SecureDeviceIdStore(const FlutterSecureStorage()),
  );
  reg.start();
  return reg;
});
```

> Implementer note: `import 'dart:io' show Platform;` is only needed if you later branch on platform; if `flutter analyze` flags it as unused, delete that line.

- [ ] **Step 4: Run; verify it passes**

Run: `cd app && flutter test test/push/device_id_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/wire/frames.dart app/lib/push/push_registration.dart app/test/push/device_id_test.dart
git commit -m "feat(app): RegisterPush frames, stable device id, registration provider"
```

---

### Task 14: Dart — permission prompt after pairing + tap → open-room + palette write

**Files:**
- Modify: `app/lib/inbox/inbox_shell.dart` (request permission on first entry to a paired inbox; start registration; wire `onTap` + drain pending launch room → `selectAndMarkRead`)
- Modify: the iOS palette writer is native; the Dart side just ensures the App Group default is set. Add: `app/lib/push/palette_bridge.dart` writing the current palette key via a tiny channel method, OR (simpler) write it from native at launch. **Chosen: write from Dart via a `setPalette` channel method** so the future switcher has a Dart entry point.

**Interfaces:**
- Consumes: `pushRegistrationProvider`, `pushServiceProvider`, `selectAndMarkRead` (`app/lib/inbox/select_room.dart`), `inboxStateProvider`.
- Produces: app behavior — permission asked once after pairing; taps open the right room; palette key `twilight` written to the App Group on launch via channel method `setPalette`.

This task's behavior is integration-level; the unit-testable piece (`PushService`) is already covered. Verify by build + Task 15 manual test. Keep edits minimal and follow existing `inbox_shell.dart` patterns.

- [ ] **Step 1: Add the `setPalette` channel method (native)**

In `app/ios/Runner/AppDelegate.swift`, add a case to the `setMethodCallHandler` switch:

```swift
      case "setPalette":
        if let key = call.arguments as? String {
          UserDefaults(suiteName: "group.dev.littlelove.littlelove")?
            .set(key, forKey: "selected_palette")
        }
        result(nil)
```

- [ ] **Step 2: Add a Dart helper to write the palette**

In `app/lib/push/push_service.dart`, add a method to `PushService`:

```dart
  /// Write the selected palette key into the shared App Group so the
  /// Notification Service Extension renders the matching artwork. Today always
  /// 'twilight'; the future palette switcher calls this with the new key.
  Future<void> setPalette(String key) =>
      _channel.invokeMethod<void>('setPalette', key);
```

And extend the test in `app/test/push/push_service_test.dart` with:

```dart
  test('setPalette sends the key to native', () async {
    Object? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setPalette') sent = call.arguments;
      return null;
    });
    await PushService().setPalette('twilight');
    expect(sent, 'twilight');
    messenger.setMockMethodCallHandler(channel, null);
  });
```

Run: `cd app && flutter test test/push/push_service_test.dart` → PASS (4 tests).

- [ ] **Step 3: Wire it into `inbox_shell.dart`**

Open `app/lib/inbox/inbox_shell.dart`. In the stateful widget that hosts the paired inbox (the one that already reads `inboxStateProvider` and builds `ConversationPage`), add an `initState`/post-frame hook that runs ONCE when the inbox first has a partner room:

```dart
  bool _pushBootstrapped = false;

  void _bootstrapPushIfPaired(WidgetRef ref) {
    if (_pushBootstrapped) return;
    final rooms = ref.read(inboxStateProvider).rooms;
    if (rooms.isEmpty) return; // wait until paired (a room exists)
    _pushBootstrapped = true;

    final push = ref.read(pushServiceProvider);
    final reg = ref.read(pushRegistrationProvider); // starts onToken listener
    // Palette: one palette today; future switcher overwrites this.
    push.setPalette('twilight');
    // Ask permission, then register happens via onToken once granted.
    push.requestPermission();

    // Live taps → open the room.
    push.onTap((roomId) => _openRoomById(ref, roomId));
    // Cold-launch tap → drain the buffered room once the inbox is ready.
    push.takePendingLaunchRoom().then((roomId) {
      if (roomId != null) _openRoomById(ref, roomId);
    });
    // Keep `reg` referenced.
    assert(reg is PushRegistration);
  }

  void _openRoomById(WidgetRef ref, String roomId) {
    final rooms = ref.read(inboxStateProvider).rooms;
    if (rooms.any((r) => r.roomId == roomId)) {
      selectAndMarkRead(ref, roomId);
    }
    // If the room isn't loaded yet, the next Rooms frame will include it; a
    // simple approach is to retry once after a short delay.
  }
```

Call `_bootstrapPushIfPaired(ref)` from the existing `build` (or a post-frame callback) where `ref`/rooms are available — match how `inbox_shell.dart` already accesses providers (it's a `ConsumerStatefulWidget`/`ConsumerWidget`; use `ref` accordingly). Add imports:

```dart
import '../push/push_service.dart';
import '../push/push_registration.dart';
```

> Implementer note: `inbox_shell.dart` already exists and has an established structure — read it first and integrate following its conventions (where it watches providers, how `selectAndMarkRead` is already called for switcher taps). Do NOT restructure the file; add the smallest hook that runs the bootstrap once after a partner room appears. If `_openRoomById` is called before the room is in the inbox (rare race on cold launch), a single delayed retry (`Future.delayed(const Duration(milliseconds: 400))`) is acceptable.

- [ ] **Step 4: Analyze + build**

Run: `cd app && flutter analyze && flutter build ios --config-only`
Expected: no analyzer errors; build config succeeds.

- [ ] **Step 5: Commit**

```bash
git add app/lib/inbox/inbox_shell.dart app/lib/push/push_service.dart app/test/push/push_service_test.dart app/ios/Runner/AppDelegate.swift
git commit -m "feat(app): request push permission after pairing, deep-link taps, write palette key"
```

---

### Task 15: Docs + manual on-device verification

**Files:**
- Modify: `server/.env.example` or the deploy docs (document `APNS_*`); if no `.env.example`, add a short section to `README`/ops notes.
- Verify on two physical iPhones.

- [ ] **Step 1: Document the server secrets**

Add (to wherever R2_* is documented; if nowhere, create `server/PUSH.md`):

```
APNs push (optional; unset → push disabled):
  APNS_KEY_P8   contents of the .p8 auth key (PEM)
  APNS_KEY_ID   the key id from the Apple Developer portal
  APNS_TEAM_ID  9PVUX2535W
  APNS_TOPIC    dev.littlelove.littlelove
  APNS_ENV      sandbox | production
```

- [ ] **Step 2: Deploy the server with APNs configured**

Provision the `APNS_*` env vars (sandbox key) in the dev/staging server. Confirm the log line on boot does NOT say "APNS_* env unset" (i.e., the sender initialized).

- [ ] **Step 3: Build to two devices**

Run: `./scripts/ios-deploy.sh --server <dev-url>` on both phones (preserves keychain identity — see CLAUDE.md). Grant the notification permission prompt when it appears (after pairing / entering the inbox).

- [ ] **Step 4: Manual test matrix — confirm each**

- [ ] Partner A (foreground) sends → Partner B **backgrounded** → B gets a banner "💜 Your partner sent you a message", with the palette artwork attached.
- [ ] B **foregrounded** in the room → A sends → **no banner** (in-app message only).
- [ ] B **force-killed** → A sends → B still gets the banner.
- [ ] Tap the banner from **backgrounded** B → opens the correct room at the newest message.
- [ ] Tap the banner from **killed** B (cold launch) → app launches and opens the correct room.
- [ ] No message text ever appears in any notification.

- [ ] **Step 5: Commit docs**

```bash
git add server/PUSH.md
git commit -m "docs: APNs server configuration + manual verification matrix"
```

---

## Self-Review

**Spec coverage:**
- Generic content-free alert + exact copy → Tasks 4 (constants), 6 (builder), 15 (verify). ✓
- Native APNs, no Firebase → Tasks 5, 6. ✓
- `device_push_tokens` table + WS register/unregister → Tasks 1, 2, 3, 7. ✓
- Push only when no live session → Task 4 (`should_push`), Task 7 (hook on `deliver` count), Task 7 test. ✓
- Token hygiene (410/bad token) → Task 4 (`classify`), Task 7 (`notify_recipient` deletes). ✓
- Push disabled when unconfigured → Task 5 (`Option`), Task 7 (`main.rs` None path). ✓
- App Group + capabilities + entitlements → Task 8. ✓
- AppDelegate registration + foreground suppression + tap forwarding → Task 9. ✓
- Notification Service Extension + palette resolution + graceful degradation → Task 10. ✓
- One palette now, swap plumbing (App Group key + resolve) → Tasks 10, 13 (write key), 14 (`setPalette`). ✓
- Swift XCTest for `PaletteArtwork.resolve` → Task 11. ✓
- Dart registration + permission-after-pairing + deep-link tap (newest message) → Tasks 12, 13, 14. ✓
- Cold-launch tap buffering → Task 9 (`pendingLaunchRoomId`/`takePendingLaunchRoom`), Task 14 (drain). ✓
- Manual on-device matrix → Task 15. ✓
- Out-of-scope (content, badges, unread divider #23, VoIP) → not implemented, by design. ✓

**Placeholder scan:** No "TBD"/"implement later". Two implementer notes (Task 7 test setup, Task 14 integration) point at concrete existing files to copy patterns from rather than leaving logic unspecified — acceptable because the surrounding code already exists and must be matched, not invented.

**Type consistency:** `PushSender`/`PushMessage`/`SendOutcome` defined in Task 4 and consumed unchanged in Tasks 6, 7. `should_push`/`classify` signatures match between definition (Task 4) and use (Task 7). `RegisterPush { device_id, apns_token, environment }` identical across Rust wire (Task 3), Rust handler (Task 7), Dart frame (Task 13). MethodChannel name `little_love/push` and methods (`requestPermission`, `takePendingLaunchRoom`, `onToken`, `onTap`, `setPalette`) consistent across Tasks 9, 12, 14. App Group `group.dev.littlelove.littlelove` and defaults key `selected_palette` consistent across Tasks 8, 10, 14. `PaletteArtwork.resolve`/`defaultAsset` consistent between Tasks 10 and 11.
