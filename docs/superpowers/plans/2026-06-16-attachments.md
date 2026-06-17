# Attachments (photo/video, iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send and receive end-to-end encrypted photo/video attachments in a conversation on iOS, with an instant inline preview thumbnail and tap-to-open full view.

**Architecture:** An attachment is a normal chat message whose decrypted plaintext is a versioned *content envelope* describing a file instead of text. The file is encrypted once with a random per-file key, the ciphertext is uploaded to Cloudflare R2 via a presigned URL brokered over the authenticated WS, and the small key + metadata + an inline encrypted thumbnail ride inside the existing per-recipient encrypted message body. Server fan-out, durable outbox, and WS relay are reused unchanged.

**Tech Stack:** Rust/Axum + sqlx/Postgres + `rusty-s3` (R2 presigning) on the server; Flutter/Dart + `image_picker`/`file_picker`/`image`/`video_thumbnail`/`video_player` + `cryptography` (XChaCha20-Poly1305) on the client.

**Spec:** `docs/superpowers/specs/2026-06-16-attachments-design.md`. **Mockup:** `docs/mocks/attachments.html`.

**Execution note:** Phases 1–2 (server) and 3–6 (client) are each independently buildable/testable. The client phases depend on the wire contract defined in Phase 2; implement server first.

---

## File Structure

**Server (new):**
- `server/migrations/0010_attachments.sql` — `attachments` table.
- `server/src/attachments.rs` — DB helpers (`insert_attachment`, `attachment_room`).
- `server/src/r2.rs` — `R2Presigner` (presigned PUT/GET URLs).
- `server/tests/attachments_presign.rs` — WS integration tests.
- `server/tests/migration_0010_schema.rs` — schema smoke test.

**Server (modified):**
- `server/Cargo.toml` — add `rusty-s3`.
- `server/src/lib.rs` — register `attachments`, `r2` modules.
- `server/src/config.rs` — `R2Config` + env wiring.
- `server/src/wire.rs` — 2 client frames + 2 server frames + error codes.
- `server/src/ws.rs` — `AppState.r2`, `MAX_ATTACHMENT_BYTES`, `MAX_BODY_BYTES`→96 KiB, 2 handlers + dispatch.
- `server/src/main.rs` — build `R2Presigner` into `AppState`.
- `server/tests/common/mod.rs` — `AppState.r2` in `build_app`, test presigner helper.

**Client (new):** `app/lib/attachment/attachment_descriptor.dart`, `app/lib/attachment/file_crypto.dart`, `app/lib/attachment/thumbnail.dart`, `app/lib/attachment/attachment_upload.dart`, `app/lib/attachment/attachment_download.dart`, `app/lib/conversation/message_content.dart`.

**Client (modified):** `app/pubspec.yaml`, `app/lib/wire/frames.dart`, `app/lib/wire/message.dart`, `app/lib/conversation/room_message_router.dart`, `app/lib/screens/inbox/inbox_shell.dart`, `app/lib/conversation/conversation_page.dart`.

---

## Phase 1 — Server: attachments table + R2 presigning

### Task 1: `attachments` migration

**Files:**
- Create: `server/migrations/0010_attachments.sql`
- Test: `server/tests/migration_0010_schema.rs`

- [ ] **Step 1: Write the migration (schema-only — project rule)**

```sql
-- server/migrations/0010_attachments.sql
-- Authorization + lifecycle ledger for E2EE blobs in R2. The server never sees
-- blob contents or the per-file key; this table only records which room a blob
-- belongs to (for download authorization) and who uploaded it.
CREATE TABLE attachments (
  blob_key            TEXT        PRIMARY KEY,
  room_id             TEXT        NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  uploader_account_id BIGINT      NOT NULL REFERENCES accounts(id),
  byte_size           BIGINT      NOT NULL,
  committed           BOOLEAN     NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX attachments_room_idx ON attachments (room_id);
```

- [ ] **Step 2: Write the schema smoke test**

```rust
// server/tests/migration_0010_schema.rs
mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_creates_attachments_table() {
    let store = common::fresh_store().await;
    let cols: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='attachments'
           AND column_name IN ('blob_key','room_id','uploader_account_id','byte_size','committed','created_at')",
    )
    .fetch_all(store.pool())
    .await
    .unwrap();
    assert_eq!(cols.len(), 6, "expected all 6 attachments columns, got {cols:?}");
}
```

- [ ] **Step 3: Add the `attachments` truncate to the test harness**

In `server/tests/common/mod.rs`, inside `fresh_store()`, add `"TRUNCATE TABLE attachments"` as the FIRST entry in the truncate array (it FKs rooms + accounts, so it must be cleared before them):

```rust
    for table in [
        "TRUNCATE TABLE attachments",
        "TRUNCATE TABLE messages",
        "TRUNCATE TABLE room_members",
        "TRUNCATE TABLE rooms CASCADE",
        "TRUNCATE TABLE invites",
        "TRUNCATE TABLE accounts RESTART IDENTITY CASCADE",
    ] {
```

- [ ] **Step 4: Run the schema test (requires a dev DB)**

Run: `./scripts/dev-up.sh && DATABASE_URL=$(grep DATABASE_URL .dev.env | cut -d= -f2-) cargo test -p littlelove-api --test migration_0010_schema`
Expected: PASS (1 test). If `dev-up.sh` already exported `DATABASE_URL`, the inline assignment is harmless.

- [ ] **Step 5: Commit**

```bash
git add server/migrations/0010_attachments.sql server/tests/migration_0010_schema.rs server/tests/common/mod.rs
git commit -m "feat(server): attachments table migration + schema test"
```

### Task 2: attachments DB helpers

**Files:**
- Create: `server/src/attachments.rs`
- Modify: `server/src/lib.rs` (register module)
- Test: in `server/src/attachments.rs` (`#[cfg(test)]`) — note these need a DB, so gate behind the same pattern as other integration paths; here we keep them as a tests/ file instead.
- Test: `server/tests/attachments_store.rs`

- [ ] **Step 1: Create the module**

```rust
// server/src/attachments.rs
//! DB helpers for the `attachments` ledger (migration 0010). The server records
//! blob → room ownership so it can authorize presigned download URLs. It never
//! stores or sees blob contents or the per-file content key.
use sqlx::PgPool;

pub async fn insert_attachment(
    pool: &PgPool,
    blob_key: &str,
    room_id: &str,
    uploader_account_id: i64,
    byte_size: i64,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO attachments (blob_key, room_id, uploader_account_id, byte_size)
         VALUES ($1, $2, $3, $4)",
    )
    .bind(blob_key)
    .bind(room_id)
    .bind(uploader_account_id)
    .bind(byte_size)
    .execute(pool)
    .await?;
    Ok(())
}

/// The room a blob belongs to, or `None` if no such blob. Used to authorize
/// download: the requester must be a member of this room.
pub async fn attachment_room(pool: &PgPool, blob_key: &str) -> sqlx::Result<Option<String>> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT room_id FROM attachments WHERE blob_key = $1")
            .bind(blob_key)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(r,)| r))
}
```

- [ ] **Step 2: Register the module** — add `pub mod attachments;` to `server/src/lib.rs` (alphabetical, after `pub mod accounts;`).

- [ ] **Step 3: Write the round-trip test**

```rust
// server/tests/attachments_store.rs
mod common;

use littlelove_api::attachments::{attachment_room, insert_attachment};

#[tokio::test]
#[serial_test::serial]
async fn insert_then_lookup_room() {
    let store = common::fresh_store().await;
    let (_court, _kait, _riley, room_id) = common::seed_trio_room(&store).await;
    let uploader = littlelove_api::rooms::account_id_by_username(store.pool(), "court")
        .await
        .unwrap()
        .unwrap();

    insert_attachment(store.pool(), "01JBLOBKEY", &room_id, uploader, 1234)
        .await
        .unwrap();

    let found = attachment_room(store.pool(), "01JBLOBKEY").await.unwrap();
    assert_eq!(found.as_deref(), Some(room_id.as_str()));
    assert!(attachment_room(store.pool(), "missing").await.unwrap().is_none());
}
```

- [ ] **Step 4: Run**

Run: `cargo test -p littlelove-api --test attachments_store`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add server/src/attachments.rs server/src/lib.rs server/tests/attachments_store.rs
git commit -m "feat(server): attachments DB helpers (insert + room lookup)"
```

### Task 3: R2 config from env

**Files:**
- Modify: `server/src/config.rs`

- [ ] **Step 1: Write the failing test** — append inside the existing `#[cfg(test)] mod tests` in `config.rs`:

```rust
    #[test]
    #[serial]
    fn r2_config_present_when_all_vars_set() {
        for (k, v) in [
            ("R2_ACCOUNT_ID", "acct123"),
            ("R2_BUCKET", "littlelove-media"),
            ("R2_ACCESS_KEY_ID", "akid"),
            ("R2_SECRET_ACCESS_KEY", "secret"),
        ] {
            std::env::set_var(k, v);
        }
        let cfg = ServerConfig::from_env();
        let r2 = cfg.r2.expect("r2 config should be Some when all vars set");
        assert_eq!(r2.account_id, "acct123");
        assert_eq!(r2.bucket, "littlelove-media");
        for k in ["R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"] {
            std::env::remove_var(k);
        }
    }

    #[test]
    #[serial]
    fn r2_config_absent_when_vars_missing() {
        for k in ["R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"] {
            std::env::remove_var(k);
        }
        assert!(ServerConfig::from_env().r2.is_none());
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cargo test -p littlelove-api --lib config::`
Expected: FAIL — `cfg.r2` field does not exist (compile error).

- [ ] **Step 3: Add `R2Config` and the field**

Replace the body of `server/src/config.rs` above the tests with:

```rust
use std::env;

#[derive(Debug, Clone)]
pub struct R2Config {
    pub account_id: String,
    pub bucket: String,
    pub access_key_id: String,
    pub secret_access_key: String,
}

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub database_url: Option<String>,
    pub r2: Option<R2Config>,
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let port = env::var("PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7707);
        let database_url = env::var("DATABASE_URL").ok().filter(|s| !s.is_empty());
        let r2 = Self::r2_from_env();
        Self { port, database_url, r2 }
    }

    fn r2_from_env() -> Option<R2Config> {
        let get = |k: &str| env::var(k).ok().filter(|s| !s.is_empty());
        Some(R2Config {
            account_id: get("R2_ACCOUNT_ID")?,
            bucket: get("R2_BUCKET")?,
            access_key_id: get("R2_ACCESS_KEY_ID")?,
            secret_access_key: get("R2_SECRET_ACCESS_KEY")?,
        })
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test -p littlelove-api --lib config::`
Expected: PASS (4 tests — the 2 originals + 2 new).

- [ ] **Step 5: Commit**

```bash
git add server/src/config.rs
git commit -m "feat(server): read R2 credentials from env"
```

### Task 4: R2 presigner

**Files:**
- Modify: `server/Cargo.toml` (add dependency)
- Create: `server/src/r2.rs`
- Modify: `server/src/lib.rs` (register module)

- [ ] **Step 1: Add the dependency**

Run: `cargo add --package littlelove-api rusty-s3`
This pins the latest `rusty-s3` (presign-only S3 crate). Note the resolved version; the API below targets the `Bucket`/`Credentials`/`*ObjectRequest` shape. If the installed version's method names differ, adapt — the contract is "given key + ttl, return a presigned URL string."

- [ ] **Step 2: Create the presigner with a unit test**

```rust
// server/src/r2.rs
//! R2 presigned-URL minting. Presigning is offline SigV4 — no network call to
//! R2 — so this is safe to unit-test with dummy credentials. R2 requires
//! PATH-style URLs (`<account>.r2.cloudflarestorage.com/<bucket>/<key>`); using
//! virtual-host style is the most common R2 presigning mistake.
use std::time::Duration;

use rusty_s3::{Bucket, Credentials, S3Action, UrlStyle};

use crate::config::R2Config;

#[derive(Clone)]
pub struct R2Presigner {
    bucket: Bucket,
    creds: Credentials,
}

impl R2Presigner {
    pub fn new(cfg: &R2Config) -> anyhow::Result<Self> {
        let endpoint = format!("https://{}.r2.cloudflarestorage.com", cfg.account_id)
            .parse()
            .map_err(|e| anyhow::anyhow!("bad R2 endpoint: {e}"))?;
        // R2 ignores the region but SigV4 requires one; "auto" is conventional.
        let bucket = Bucket::new(endpoint, UrlStyle::Path, cfg.bucket.clone(), "auto".to_string())
            .map_err(|e| anyhow::anyhow!("bad R2 bucket: {e}"))?;
        let creds = Credentials::new(cfg.access_key_id.clone(), cfg.secret_access_key.clone());
        Ok(Self { bucket, creds })
    }

    pub fn presign_put(&self, blob_key: &str, ttl: Duration) -> String {
        self.bucket
            .put_object(Some(&self.creds), blob_key)
            .sign(ttl)
            .to_string()
    }

    pub fn presign_get(&self, blob_key: &str, ttl: Duration) -> String {
        self.bucket
            .get_object(Some(&self.creds), blob_key)
            .sign(ttl)
            .to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn presigner() -> R2Presigner {
        R2Presigner::new(&R2Config {
            account_id: "acct123".into(),
            bucket: "littlelove-media".into(),
            access_key_id: "AKIDEXAMPLE".into(),
            secret_access_key: "secretexample".into(),
        })
        .unwrap()
    }

    #[test]
    fn put_url_is_path_style_signed() {
        let url = presigner().presign_put("01JBLOB", Duration::from_secs(600));
        assert!(url.contains("acct123.r2.cloudflarestorage.com"), "{url}");
        assert!(url.contains("/littlelove-media/01JBLOB"), "path-style: {url}");
        assert!(url.contains("X-Amz-Signature="), "{url}");
        assert!(url.contains("X-Amz-Expires=600"), "{url}");
    }

    #[test]
    fn get_url_is_signed() {
        let url = presigner().presign_get("01JBLOB", Duration::from_secs(600));
        assert!(url.contains("/littlelove-media/01JBLOB"), "{url}");
        assert!(url.contains("X-Amz-Signature="), "{url}");
    }
}
```

- [ ] **Step 3: Register the module** — add `pub mod r2;` to `server/src/lib.rs` (after `pub mod invites;`).

- [ ] **Step 4: Run the unit test**

Run: `cargo test -p littlelove-api --lib r2::`
Expected: PASS (2 tests). If a method name mismatches the installed `rusty-s3`, fix the call and re-run.

- [ ] **Step 5: Commit**

```bash
git add server/Cargo.toml Cargo.lock server/src/r2.rs server/src/lib.rs
git commit -m "feat(server): R2 presigner (path-style SigV4 PUT/GET URLs)"
```

---

## Phase 2 — Server: WS frames + handlers

### Task 5: wire frames for upload/download

**Files:**
- Modify: `server/src/wire.rs`

- [ ] **Step 1: Write failing serde tests** — append to `server/src/wire.rs`'s `#[cfg(test)] mod tests`:

```rust
    #[test]
    fn parses_request_upload_frame() {
        let raw = r#"{"kind":"RequestUpload","request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707","room_id":"01J","byte_size":1048576}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::RequestUpload { room_id, byte_size, .. } => {
                assert_eq!(room_id, "01J");
                assert_eq!(byte_size, 1_048_576);
            }
            _ => panic!("expected RequestUpload"),
        }
    }

    #[test]
    fn parses_request_download_frame() {
        let raw = r#"{"kind":"RequestDownload","blob_key":"01JBLOB"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        assert!(matches!(frame, RoomClientFrame::RequestDownload { blob_key } if blob_key == "01JBLOB"));
    }

    #[test]
    fn serializes_upload_granted_frame() {
        let f = RoomServerFrame::UploadGranted {
            request_id: Uuid::nil(),
            blob_key: "01JBLOB".into(),
            url: "https://r2/put".into(),
            expires_at: "2026-06-16T18:00:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"UploadGranted""#));
        assert!(s.contains(r#""blob_key":"01JBLOB""#));
    }

    #[test]
    fn serializes_download_granted_frame() {
        let f = RoomServerFrame::DownloadGranted {
            blob_key: "01JBLOB".into(),
            url: "https://r2/get".into(),
            expires_at: "2026-06-16T18:00:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"DownloadGranted""#));
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p littlelove-api --lib wire::`
Expected: FAIL — the new variants don't exist (compile error).

- [ ] **Step 3: Add the client frame variants** — in `RoomClientFrame`, after the `Send { .. }` variant:

```rust
    RequestUpload {
        request_id: Uuid,
        room_id: String,
        byte_size: i64,
    },
    RequestDownload {
        blob_key: String,
    },
```

- [ ] **Step 4: Add the server frame variants** — in `RoomServerFrame`, after the `Message { .. }` variant:

```rust
    UploadGranted {
        request_id: Uuid,
        blob_key: String,
        url: String,
        expires_at: DateTime<Utc>,
    },
    DownloadGranted {
        blob_key: String,
        url: String,
        expires_at: DateTime<Utc>,
    },
```

- [ ] **Step 5: Add error codes** — in `pub mod error_codes`, add:

```rust
    pub const BLOB_TOO_LARGE: &str = "BlobTooLarge";
    pub const UNKNOWN_BLOB: &str = "UnknownBlob";
    pub const R2_UNAVAILABLE: &str = "R2Unavailable";
```

- [ ] **Step 6: Run to verify pass**

Run: `cargo test -p littlelove-api --lib wire::`
Expected: PASS (all wire tests, including the 4 new ones).

- [ ] **Step 7: Commit**

```bash
git add server/src/wire.rs
git commit -m "feat(server): RequestUpload/RequestDownload + Granted wire frames"
```

### Task 6: AppState.r2 + handler wiring (no behavior yet)

**Files:**
- Modify: `server/src/ws.rs`, `server/src/main.rs`, `server/tests/common/mod.rs`

- [ ] **Step 1: Add `r2` to `AppState`** in `server/src/ws.rs`:

```rust
#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
    pub r2: Option<crate::r2::R2Presigner>,
}
```

- [ ] **Step 2: Add the attachment-size constant** near `MAX_BODY_BYTES`, and raise the body cap:

```rust
/// Hard cap on per-recipient ciphertext (base64). 96 KiB fits a long text
/// message OR a `kind:"file"` envelope whose inline thumbnail is ~5–15 KB
/// (base64-expanded). Full file bytes never travel in the body — they go to R2.
const MAX_BODY_BYTES: usize = 98_304;
/// Hard cap on a single attachment upload (raw plaintext bytes). 500 MiB,
/// single presigned PUT, one-shot client-side AEAD (spec §4).
const MAX_ATTACHMENT_BYTES: i64 = 500 * 1024 * 1024;
```

- [ ] **Step 3: Update `main.rs`** to build the presigner and pass it. In `server/src/main.rs`, after building `store`:

```rust
    let r2 = match cfg.r2.as_ref() {
        Some(r2cfg) => match littlelove_api::r2::R2Presigner::new(r2cfg) {
            Ok(p) => Some(p),
            Err(e) => {
                tracing::warn!("R2 presigner init failed; attachments disabled: {e}");
                None
            }
        },
        None => {
            tracing::warn!("R2_* env unset; attachments disabled");
            None
        }
    };
    let state = AppState {
        routing: Routing::new(),
        store,
        r2,
    };
```

- [ ] **Step 4: Update the test harness** `server/tests/common/mod.rs`:

Add to the imports: `use littlelove_api::{config::R2Config, r2::R2Presigner};`. Change `build_app` to set a test presigner (presigning is offline, so dummy creds are fine), and keep the existing signature:

```rust
pub fn test_presigner() -> R2Presigner {
    R2Presigner::new(&R2Config {
        account_id: "acct123".into(),
        bucket: "littlelove-media".into(),
        access_key_id: "AKIDEXAMPLE".into(),
        secret_access_key: "secretexample".into(),
    })
    .unwrap()
}

pub fn build_app(store: Option<Store>) -> Router {
    let state = AppState {
        routing: Routing::new(),
        store,
        r2: Some(test_presigner()),
    };
    // ... unchanged router builder ...
}
```

- [ ] **Step 5: Build to verify everything compiles**

Run: `cargo build -p littlelove-api && cargo test -p littlelove-api --test health`
Expected: compiles; existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add server/src/ws.rs server/src/main.rs server/tests/common/mod.rs
git commit -m "feat(server): thread R2 presigner through AppState; raise body cap to 96 KiB"
```

### Task 7: upload/download handlers + integration tests

**Files:**
- Modify: `server/src/ws.rs`
- Test: `server/tests/attachments_presign.rs`

- [ ] **Step 1: Add the dispatch arms** in `handle_socket`'s match (after the `Send` arm):

```rust
                Ok(RoomClientFrame::RequestUpload {
                    request_id,
                    room_id,
                    byte_size,
                }) => {
                    handle_request_upload(&state, &me, request_id, &room_id, byte_size, &tx).await;
                }
                Ok(RoomClientFrame::RequestDownload { blob_key }) => {
                    handle_request_download(&state, &me, &blob_key, &tx).await;
                }
```

- [ ] **Step 2: Add imports** at the top of `ws.rs`:

```rust
use std::time::Duration;
use crate::attachments::{attachment_room, insert_attachment};
```

(Merge the `use crate::...` lines as appropriate; `Duration` joins the existing `std` imports.)

- [ ] **Step 3: Implement the handlers** (append near `handle_send`):

```rust
/// Presigned-URL TTL for both upload and download. Long enough for a 500 MiB
/// upload on a slow mobile link; far under R2's 7-day max.
const PRESIGN_TTL: Duration = Duration::from_secs(600);

async fn handle_request_upload(
    state: &AppState,
    me: &AccountRecord,
    request_id: Uuid,
    room_id: &str,
    byte_size: i64,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let (store, r2) = match (state.store.as_ref(), state.r2.as_ref()) {
        (Some(s), Some(r)) => (s, r),
        _ => {
            send_error(tx, error_codes::R2_UNAVAILABLE, "");
            return;
        }
    };
    if byte_size <= 0 || byte_size > MAX_ATTACHMENT_BYTES {
        send_error(tx, error_codes::BLOB_TOO_LARGE, "");
        return;
    }
    match is_member(store.pool(), room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            send_error(tx, error_codes::UNKNOWN_ROOM, "");
            return;
        }
        Err(e) => {
            warn!("is_member (upload): {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    let blob_key = Ulid::new().to_string();
    if let Err(e) = insert_attachment(store.pool(), &blob_key, room_id, me.id, byte_size).await {
        warn!("insert_attachment: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    let url = r2.presign_put(&blob_key, PRESIGN_TTL);
    let _ = tx.send(RoomServerFrame::UploadGranted {
        request_id,
        blob_key,
        url,
        expires_at: Utc::now() + chrono::Duration::from_std(PRESIGN_TTL).unwrap(),
    });
}

async fn handle_request_download(
    state: &AppState,
    me: &AccountRecord,
    blob_key: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let (store, r2) = match (state.store.as_ref(), state.r2.as_ref()) {
        (Some(s), Some(r)) => (s, r),
        _ => {
            send_error(tx, error_codes::R2_UNAVAILABLE, "");
            return;
        }
    };
    let room_id = match attachment_room(store.pool(), blob_key).await {
        Ok(Some(r)) => r,
        Ok(None) => {
            send_error(tx, error_codes::UNKNOWN_BLOB, "");
            return;
        }
        Err(e) => {
            warn!("attachment_room: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    // Authorize: requester must be a member of the blob's room. A non-member
    // gets UNKNOWN_BLOB (not a distinct "forbidden") so blob existence isn't
    // leaked across rooms.
    match is_member(store.pool(), &room_id, me.id).await {
        Ok(true) => {}
        _ => {
            send_error(tx, error_codes::UNKNOWN_BLOB, "");
            return;
        }
    }
    let url = r2.presign_get(blob_key, PRESIGN_TTL);
    let _ = tx.send(RoomServerFrame::DownloadGranted {
        blob_key: blob_key.to_string(),
        url,
        expires_at: Utc::now() + chrono::Duration::from_std(PRESIGN_TTL).unwrap(),
    });
}
```

- [ ] **Step 4: Write integration tests**

```rust
// server/tests/attachments_presign.rs
mod common;

use common::*;
use futures::SinkExt;
use tokio_tungstenite::tungstenite::Message as WsMessage;

// court/kaitlyn/riley are members of the seeded room; mallory is not.
async fn seed_with_outsider(store: &littlelove_api::store::Store) -> String {
    let (_c, _k, _r, room_id) = seed_trio_room(store).await;
    let vk = signing_key_from_seed([9u8; 32]);
    insert_account(store, "mallory", &vk.verifying_key()).await;
    room_id
}

#[tokio::test]
#[serial_test::serial]
async fn member_gets_upload_granted_and_row_inserted() {
    let store = fresh_store().await;
    let room_id = seed_with_outsider(&store).await;
    let addr = spawn_server(Some(store.clone())).await;
    let sk = signing_key_from_seed([10u8; 32]); // court (ed pub = [10;32]) — see seed_trio_room
    let mut sock = handshake_as(addr, "court", &sk).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 1_048_576,
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "UploadGranted", "got {v}");
    assert!(v["url"].as_str().unwrap().contains("X-Amz-Signature="));
    let blob_key = v["blob_key"].as_str().unwrap();

    let room: Option<(String,)> =
        sqlx::query_as("SELECT room_id FROM attachments WHERE blob_key = $1")
            .bind(blob_key)
            .fetch_optional(store.pool())
            .await
            .unwrap();
    assert_eq!(room.unwrap().0, room_id);
}

#[tokio::test]
#[serial_test::serial]
async fn oversize_upload_rejected() {
    let store = fresh_store().await;
    let room_id = seed_with_outsider(&store).await;
    let addr = spawn_server(Some(store)).await;
    let sk = signing_key_from_seed([10u8; 32]);
    let mut sock = handshake_as(addr, "court", &sk).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 600i64 * 1024 * 1024, // 600 MiB > 500 cap
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "BlobTooLarge");
}

#[tokio::test]
#[serial_test::serial]
async fn non_member_upload_rejected() {
    let store = fresh_store().await;
    let room_id = seed_with_outsider(&store).await;
    let addr = spawn_server(Some(store)).await;
    let sk = signing_key_from_seed([9u8; 32]); // mallory
    let mut sock = handshake_as(addr, "mallory", &sk).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 1024,
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "UnknownRoom");
}

#[tokio::test]
#[serial_test::serial]
async fn cross_room_download_denied_member_allowed() {
    let store = fresh_store().await;
    let room_id = seed_with_outsider(&store).await;
    // Seed a blob owned by court in the room.
    let court = littlelove_api::rooms::account_id_by_username(store.pool(), "court")
        .await.unwrap().unwrap();
    littlelove_api::attachments::insert_attachment(store.pool(), "01JBLOB", &room_id, court, 1024)
        .await.unwrap();
    let addr = spawn_server(Some(store)).await;

    // mallory (non-member) → UnknownBlob
    let mut m = handshake_as(addr, "mallory", &signing_key_from_seed([9u8; 32])).await;
    drain_rooms(&mut m).await;
    m.send(WsMessage::Text(
        serde_json::json!({"kind":"RequestDownload","blob_key":"01JBLOB"}).to_string(),
    )).await.unwrap();
    let v = next_frame(&mut m).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "UnknownBlob");

    // court (member) → DownloadGranted
    let mut c = handshake_as(addr, "court", &signing_key_from_seed([10u8; 32])).await;
    drain_rooms(&mut c).await;
    c.send(WsMessage::Text(
        serde_json::json!({"kind":"RequestDownload","blob_key":"01JBLOB"}).to_string(),
    )).await.unwrap();
    let v = next_frame(&mut c).await;
    assert_eq!(v["kind"], "DownloadGranted", "got {v}");
    assert!(v["url"].as_str().unwrap().contains("X-Amz-Signature="));
}
```

NOTE: `seed_trio_room` sets court's `ed25519_pub` to `[10u8;32]` and uses `insert_account` for mallory with seed `[9u8;32]`; the signing-key seeds above must match those pubkeys so the handshake signature verifies. If `seed_trio_room`'s byte fillers differ from `signing_key_from_seed`'s derived verifying key, switch the seeded rows to use `ed_pub_b64(&signing_key_from_seed(seed))` instead of raw `[n;32]` bytes. Verify by running the test; a handshake mismatch shows as a closed socket at `handshake_as`.

- [ ] **Step 5: Run**

Run: `cargo test -p littlelove-api --test attachments_presign`
Expected: PASS (4 tests). If handshake fails, reconcile the seed pubkeys per the note above.

- [ ] **Step 6: Commit**

```bash
git add server/src/ws.rs server/tests/attachments_presign.rs
git commit -m "feat(server): RequestUpload/RequestDownload handlers with room authorization"
```

---

## Phase 3 — Client: file crypto + content envelope

### Task 8: add Flutter dependencies

**Files:**
- Modify: `app/pubspec.yaml`

- [ ] **Step 1: Add the packages**

Run (from `app/`): `flutter pub add image_picker file_picker image video_thumbnail video_player`
Expected: pubspec updated, `flutter pub get` succeeds. Record resolved versions.

- [ ] **Step 2: iOS Info.plist usage strings** — add to `app/ios/Runner/Info.plist` (Photos access for `image_picker`):

```xml
	<key>NSPhotoLibraryUsageDescription</key>
	<string>LittleLove needs access to your photos so you can share them, end-to-end encrypted, with your partner.</string>
```

- [ ] **Step 3: Verify the app still builds**

Run (from `app/`): `flutter analyze`
Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/ios/Runner/Info.plist
git commit -m "feat(app): add image_picker/file_picker/image/video_thumbnail/video_player"
```

### Task 9: file-bytes AEAD

**Files:**
- Create: `app/lib/attachment/file_crypto.dart`
- Test: `app/test/attachment/file_crypto_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/attachment/file_crypto_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/file_crypto.dart';

void main() {
  test('encrypt then decrypt round-trips arbitrary bytes', () async {
    final plain = Uint8List.fromList(List<int>.generate(5000, (i) => i % 256));
    final enc = await encryptFileBytes(plain);
    expect(enc.key.length, 32);
    expect(enc.nonce.length, 24);
    expect(enc.ciphertext.length, greaterThan(plain.length)); // + 16-byte MAC

    final out = await decryptFileBytes(
      key: enc.key, nonce: enc.nonce, ciphertext: enc.ciphertext);
    expect(out, equals(plain));
  });

  test('wrong key fails to decrypt', () async {
    final plain = Uint8List.fromList([1, 2, 3, 4]);
    final enc = await encryptFileBytes(plain);
    final badKey = Uint8List(32)..[0] = 0xFF;
    expect(
      () => decryptFileBytes(key: badKey, nonce: enc.nonce, ciphertext: enc.ciphertext),
      throwsA(isA<Exception>()),
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/attachment/file_crypto_test.dart`
Expected: FAIL — `file_crypto.dart` does not exist.

- [ ] **Step 3: Implement** (mirrors `crypto/cipher.dart` packing: `cipher || mac`)

```dart
// app/lib/attachment/file_crypto.dart
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Result of encrypting a file's bytes: the random per-file [key] and [nonce]
/// (which go into the message envelope, encrypted per-recipient) plus the
/// [ciphertext] (which is uploaded raw to R2). XChaCha20-Poly1305 — same AEAD
/// as text messages (spec §4).
class EncryptedFile {
  EncryptedFile({required this.key, required this.nonce, required this.ciphertext});
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List ciphertext;
}

final _algo = Xchacha20.poly1305Aead();

Future<EncryptedFile> encryptFileBytes(Uint8List plain) async {
  final secret = await _algo.newSecretKey();
  final nonce = _algo.newNonce();
  final box = await _algo.encrypt(plain, secretKey: secret, nonce: nonce);
  final keyBytes = Uint8List.fromList(await secret.extractBytes());
  final out = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
  return EncryptedFile(
    key: keyBytes,
    nonce: Uint8List.fromList(nonce),
    ciphertext: out,
  );
}

Future<Uint8List> decryptFileBytes({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List ciphertext,
}) async {
  if (ciphertext.length < 16) {
    throw const FormatException('ciphertext too short to contain MAC');
  }
  final ct = ciphertext.sublist(0, ciphertext.length - 16);
  final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
  final plain = await _algo.decrypt(
    SecretBox(ct, nonce: nonce, mac: mac),
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(plain);
}
```

- [ ] **Step 4: Run to verify pass**

Run (from `app/`): `flutter test test/attachment/file_crypto_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/attachment/file_crypto.dart app/test/attachment/file_crypto_test.dart
git commit -m "feat(app): XChaCha20-Poly1305 file-bytes encrypt/decrypt"
```

### Task 10: attachment descriptor + in-band thumbnail codec

**Files:**
- Create: `app/lib/attachment/attachment_descriptor.dart`
- Test: `app/test/attachment/attachment_descriptor_test.dart`

The inline `thumb` is self-contained: `base64( key[32] || nonce[24] || ciphertext )`, so a recipient decrypts it with no extra key material.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/attachment/attachment_descriptor_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';

void main() {
  test('json round-trips, omitting null video fields for images', () {
    const d = AttachmentDescriptor(
      blobKey: '01JBLOB', contentKeyB64: 'a', nonceB64: 'b',
      mime: 'image/jpeg', filename: 'IMG.jpg', size: 5242880,
      width: 4032, height: 3024, durationMs: null, thumbB64: 'tt',
    );
    final j = d.toJson();
    expect(j.containsKey('duration_ms'), isFalse);
    final back = AttachmentDescriptor.fromJson(j);
    expect(back.blobKey, '01JBLOB');
    expect(back.isVideo, isFalse);
  });

  test('isVideo true for video mime', () {
    const d = AttachmentDescriptor(
      blobKey: 'k', contentKeyB64: 'a', nonceB64: 'b', mime: 'video/mp4',
      filename: 'v.mp4', size: 10, width: 1, height: 1, durationMs: 8200, thumbB64: 't');
    expect(d.isVideo, isTrue);
    expect(d.toJson()['duration_ms'], 8200);
  });

  test('thumb encode/decode round-trips', () async {
    final plain = Uint8List.fromList([9, 8, 7, 6, 5]);
    final wire = await encodeThumb(plain);
    final out = await decodeThumb(wire);
    expect(out, equals(plain));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/attachment/attachment_descriptor_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement**

```dart
// app/lib/attachment/attachment_descriptor.dart
import 'dart:convert';
import 'dart:typed_data';

import 'file_crypto.dart';

/// The `kind:"file"` payload carried inside the per-recipient encrypted message
/// body (spec §3). Holds the per-file content key + metadata + an inline
/// encrypted thumbnail. Full file bytes live in R2 under [blobKey].
class AttachmentDescriptor {
  const AttachmentDescriptor({
    required this.blobKey,
    required this.contentKeyB64,
    required this.nonceB64,
    required this.mime,
    required this.filename,
    required this.size,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.thumbB64,
  });

  final String blobKey;
  final String contentKeyB64;
  final String nonceB64;
  final String mime;
  final String filename;
  final int size;
  final int width;
  final int height;
  final int? durationMs;
  final String thumbB64;

  bool get isVideo => mime.startsWith('video/');

  Map<String, Object?> toJson() => {
        'blob_key': blobKey,
        'content_key': contentKeyB64,
        'nonce': nonceB64,
        'mime': mime,
        'filename': filename,
        'size': size,
        'width': width,
        'height': height,
        if (durationMs != null) 'duration_ms': durationMs,
        'thumb': thumbB64,
      };

  factory AttachmentDescriptor.fromJson(Map<String, Object?> j) => AttachmentDescriptor(
        blobKey: j['blob_key']! as String,
        contentKeyB64: j['content_key']! as String,
        nonceB64: j['nonce']! as String,
        mime: j['mime']! as String,
        filename: (j['filename'] as String?) ?? '',
        size: (j['size'] as num).toInt(),
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        thumbB64: j['thumb']! as String,
      );
}

/// Encrypt a thumbnail JPEG into a self-contained wire string:
/// base64( key[32] || nonce[24] || ciphertext ).
Future<String> encodeThumb(Uint8List jpeg) async {
  final enc = await encryptFileBytes(jpeg);
  final out = Uint8List(32 + 24 + enc.ciphertext.length)
    ..setRange(0, 32, enc.key)
    ..setRange(32, 56, enc.nonce)
    ..setRange(56, 56 + enc.ciphertext.length, enc.ciphertext);
  return base64.encode(out);
}

Future<Uint8List> decodeThumb(String wire) async {
  final raw = base64.decode(wire);
  if (raw.length < 56) throw const FormatException('thumb too short');
  final key = Uint8List.sublistView(raw, 0, 32);
  final nonce = Uint8List.sublistView(raw, 32, 56);
  final ct = Uint8List.sublistView(raw, 56);
  return decryptFileBytes(key: key, nonce: nonce, ciphertext: ct);
}
```

- [ ] **Step 4: Run to verify pass**

Run (from `app/`): `flutter test test/attachment/attachment_descriptor_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/attachment/attachment_descriptor.dart app/test/attachment/attachment_descriptor_test.dart
git commit -m "feat(app): attachment descriptor + in-band encrypted thumbnail codec"
```

### Task 11: content envelope (text vs file)

**Files:**
- Create: `app/lib/conversation/message_content.dart`
- Test: `app/test/conversation/message_content_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/conversation/message_content_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_content.dart';

void main() {
  test('text encodes to a versioned envelope and decodes back', () {
    final enc = const TextContent('hello').encode();
    final back = MessageContent.decode(enc);
    expect(back, isA<TextContent>());
    expect((back as TextContent).text, 'hello');
  });

  test('file envelope round-trips', () {
    const d = AttachmentDescriptor(
      blobKey: 'k', contentKeyB64: 'a', nonceB64: 'b', mime: 'image/jpeg',
      filename: 'IMG.jpg', size: 1, width: 1, height: 1, durationMs: null, thumbB64: 't');
    final back = MessageContent.decode(const FileContent(d).encode());
    expect(back, isA<FileContent>());
    expect((back as FileContent).descriptor.blobKey, 'k');
  });

  test('legacy bare string decodes as text (back-compat)', () {
    final back = MessageContent.decode('just a plain old message');
    expect(back, isA<TextContent>());
    expect((back as TextContent).text, 'just a plain old message');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/conversation/message_content_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement**

```dart
// app/lib/conversation/message_content.dart
import 'dart:convert';

import '../attachment/attachment_descriptor.dart';

/// The decrypted plaintext layer of a message (spec §3). Versioned so future
/// kinds can be added. Text and file are the only kinds in this iteration.
sealed class MessageContent {
  const MessageContent();

  String encode();

  /// Decode a decrypted plaintext string. Any string that is not a valid v1
  /// envelope is treated as legacy/plain text (back-compat with pre-envelope
  /// sends and with the cannot-decrypt sentinel, which renders as text).
  static MessageContent decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, Object?> && j['v'] == 1) {
        switch (j['kind']) {
          case 'file':
            return FileContent(AttachmentDescriptor.fromJson(j));
          case 'text':
            return TextContent((j['text'] as String?) ?? '');
        }
      }
    } catch (_) {
      // fall through to plain-text
    }
    return TextContent(raw);
  }
}

class TextContent extends MessageContent {
  const TextContent(this.text);
  final String text;

  @override
  String encode() => jsonEncode({'v': 1, 'kind': 'text', 'text': text});
}

class FileContent extends MessageContent {
  const FileContent(this.descriptor);
  final AttachmentDescriptor descriptor;

  @override
  String encode() => jsonEncode({'v': 1, 'kind': 'file', ...descriptor.toJson()});
}
```

Note: `AttachmentDescriptor.fromJson` expects the descriptor fields at the top level of the envelope map, which is how `FileContent.encode` writes them (spread alongside `v`/`kind`). Keep these two in sync.

- [ ] **Step 4: Run to verify pass**

Run (from `app/`): `flutter test test/conversation/message_content_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/message_content.dart app/test/conversation/message_content_test.dart
git commit -m "feat(app): versioned message content envelope (text/file)"
```

---

## Phase 4 — Client: wire frames + R2 transport

### Task 12: client wire frames

**Files:**
- Modify: `app/lib/wire/frames.dart`, `app/lib/conversation/room_message_router.dart`
- Test: `app/test/wire/attachment_frames_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wire/attachment_frames_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  test('RequestUpload serializes', () {
    final j = const RequestUploadFrame(
      requestId: 'req-1', roomId: '01J', byteSize: 1048576).toJson();
    expect(j['kind'], 'RequestUpload');
    expect(j['byte_size'], 1048576);
  });

  test('RequestDownload serializes', () {
    expect(const RequestDownloadFrame(blobKey: '01JBLOB').toJson()['blob_key'], '01JBLOB');
  });

  test('UploadGranted parses', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'UploadGranted', 'request_id': 'req-1', 'blob_key': '01JBLOB',
      'url': 'https://r2/put', 'expires_at': '2026-06-16T18:00:00Z',
    });
    expect(f, isA<UploadGrantedFrame>());
    expect((f as UploadGrantedFrame).blobKey, '01JBLOB');
  });

  test('DownloadGranted parses', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'DownloadGranted', 'blob_key': '01JBLOB',
      'url': 'https://r2/get', 'expires_at': '2026-06-16T18:00:00Z',
    });
    expect(f, isA<DownloadGrantedFrame>());
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/wire/attachment_frames_test.dart`
Expected: FAIL — frames don't exist.

- [ ] **Step 3: Add the inbound frames** — in `app/lib/wire/frames.dart`, add two cases to `RoomServerFrame.fromJson`'s switch (before `default`):

```dart
      case 'UploadGranted':
        return UploadGrantedFrame(
          requestId: json['request_id']! as String,
          blobKey: json['blob_key']! as String,
          url: json['url']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
        );
      case 'DownloadGranted':
        return DownloadGrantedFrame(
          blobKey: json['blob_key']! as String,
          url: json['url']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
        );
```

And add the subclasses (near `MessageFrame`):

```dart
class UploadGrantedFrame extends RoomServerFrame {
  const UploadGrantedFrame({
    required this.requestId,
    required this.blobKey,
    required this.url,
    required this.expiresAt,
  });
  final String requestId;
  final String blobKey;
  final String url;
  final DateTime expiresAt;
}

class DownloadGrantedFrame extends RoomServerFrame {
  const DownloadGrantedFrame({
    required this.blobKey,
    required this.url,
    required this.expiresAt,
  });
  final String blobKey;
  final String url;
  final DateTime expiresAt;
}
```

- [ ] **Step 4: Add the outbound frames** — in the `// ---------- Outbound` section of `frames.dart`:

```dart
class RequestUploadFrame {
  const RequestUploadFrame({
    required this.requestId,
    required this.roomId,
    required this.byteSize,
  });
  final String requestId;
  final String roomId;
  final int byteSize;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'RequestUpload',
        'request_id': requestId,
        'room_id': roomId,
        'byte_size': byteSize,
      };
}

class RequestDownloadFrame {
  const RequestDownloadFrame({required this.blobKey});
  final String blobKey;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'RequestDownload',
        'blob_key': blobKey,
      };
}
```

- [ ] **Step 5: Handle the new frames in the router** — in `app/lib/conversation/room_message_router.dart`, the `switch (f)` has a final arm grouping frames it ignores. Add the two grant frames there so they don't fall through (the upload/download code listens for them directly):

```dart
      case InviteCreatedFrame():
      case RoomErrorFrame():
      case UploadGrantedFrame():
      case DownloadGrantedFrame():
        // Owned by LivePairingTransport / attachment upload+download flows.
        break;
```

- [ ] **Step 6: Run to verify pass**

Run (from `app/`): `flutter test test/wire/attachment_frames_test.dart && flutter analyze`
Expected: PASS (4 tests); analyze clean (the switch is now exhaustive).

- [ ] **Step 7: Commit**

```bash
git add app/lib/wire/frames.dart app/lib/conversation/room_message_router.dart app/test/wire/attachment_frames_test.dart
git commit -m "feat(app): client wire frames for upload/download presign"
```

### Task 13: thumbnail builder

**Files:**
- Create: `app/lib/attachment/thumbnail.dart`
- Test: `app/test/attachment/thumbnail_test.dart`

Images use the `image` package (pure Dart, testable in the Flutter test VM). Video poster frames use `video_thumbnail`, which needs a real iOS host — so the video path is exercised by the on-device test (Task 21), not a unit test.

- [ ] **Step 1: Write the failing test (image path only)**

```dart
// app/test/attachment/thumbnail_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/attachment/thumbnail.dart';

void main() {
  test('downscales a large image to <=180px long edge, returns jpeg + dims', () async {
    final src = img.Image(width: 1200, height: 800);
    img.fill(src, color: img.ColorRgb8(120, 60, 90));
    final png = Uint8List.fromList(img.encodePng(src));

    final t = await buildImageThumbnail(png);
    expect(t.width, 1200);
    expect(t.height, 800);
    final decoded = img.decodeJpg(t.jpeg)!;
    expect(decoded.width <= 180 && decoded.height <= 180, isTrue);
    expect(decoded.width, 180); // long edge clamped
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/attachment/thumbnail_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement**

```dart
// app/lib/attachment/thumbnail.dart
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

/// A built thumbnail: a small JPEG plus the ORIGINAL media's pixel dimensions
/// (used for the descriptor's width/height so the bubble can size its tile).
class BuiltThumbnail {
  BuiltThumbnail({required this.jpeg, required this.width, required this.height});
  final Uint8List jpeg;
  final int width;
  final int height;
}

const _maxEdge = 180;
const _quality = 50;

/// Downscale image [bytes] to a <=180px-long-edge JPEG. Returns the original
/// dimensions alongside the thumbnail.
Future<BuiltThumbnail> buildImageThumbnail(Uint8List bytes) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('undecodable image');
  final w = decoded.width, h = decoded.height;
  final thumb = w >= h
      ? img.copyResize(decoded, width: _maxEdge)
      : img.copyResize(decoded, height: _maxEdge);
  return BuiltThumbnail(
    jpeg: Uint8List.fromList(img.encodeJpg(thumb, quality: _quality)),
    width: w,
    height: h,
  );
}

/// Extract a poster frame from a video file at [path] and downscale it.
/// iOS-only path (AVAssetImageGenerator under the hood). Dimensions are the
/// poster's, which match the video's display size.
Future<BuiltThumbnail> buildVideoThumbnail(String path) async {
  final jpeg = await vt.VideoThumbnail.thumbnailData(
    video: path,
    imageFormat: vt.ImageFormat.JPEG,
    maxWidth: _maxEdge,
    quality: _quality,
  );
  if (jpeg == null) throw const FormatException('could not extract video poster');
  final decoded = img.decodeImage(jpeg);
  return BuiltThumbnail(
    jpeg: jpeg,
    width: decoded?.width ?? 0,
    height: decoded?.height ?? 0,
  );
}
```

- [ ] **Step 4: Run to verify pass**

Run (from `app/`): `flutter test test/attachment/thumbnail_test.dart`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add app/lib/attachment/thumbnail.dart app/test/attachment/thumbnail_test.dart
git commit -m "feat(app): image/video thumbnail builder"
```

### Task 14: upload transport

**Files:**
- Create: `app/lib/attachment/attachment_upload.dart`

This sends `RequestUpload`, awaits the matching `UploadGranted` on the broadcast `conn.incoming`, then PUTs the raw ciphertext to R2. No unit test (needs a live conn + HTTP); covered by the on-device test (Task 21). Keep the function small and dependency-injected so it stays reviewable.

- [ ] **Step 1: Implement**

```dart
// app/lib/attachment/attachment_upload.dart
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';

/// Request a presigned PUT for [ciphertext] in [roomId], then upload the raw
/// bytes to R2. Returns the server-minted `blob_key`. Throws on timeout or a
/// non-2xx PUT. The caller has already encrypted the bytes (raw ciphertext is
/// uploaded — never base64 — to bound memory; spec §4).
Future<String> uploadCiphertext({
  required LiveConnection conn,
  required String roomId,
  required Uint8List ciphertext,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final requestId = const Uuid().v4();
  final granted = conn.incoming
      .where((f) => f is UploadGrantedFrame && f.requestId == requestId)
      .cast<UploadGrantedFrame>()
      .first
      .timeout(timeout);

  conn.send(RequestUploadFrame(
    requestId: requestId,
    roomId: roomId,
    byteSize: ciphertext.length,
  ).toJson());

  final grant = await granted;
  final client = httpClient ?? http.Client();
  try {
    final res = await client.put(
      Uri.parse(grant.url),
      headers: const {'content-type': 'application/octet-stream'},
      body: ciphertext,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw http.ClientException('R2 PUT failed: HTTP ${res.statusCode}');
    }
    return grant.blobKey;
  } finally {
    if (httpClient == null) client.close();
  }
}
```

NOTE (progress): the `http` package buffers the whole body, so this gives no granular % — the optimistic bubble shows an indeterminate spinner (mockup screen 3's ring is aspirational). Real percentage progress needs a streamed request (e.g. `dio`); deferred to keep deps minimal. Call this out in the bubble UI (Task 19).

- [ ] **Step 2: Verify it compiles**

Run (from `app/`): `flutter analyze lib/attachment/attachment_upload.dart`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add app/lib/attachment/attachment_upload.dart
git commit -m "feat(app): attachment upload transport (presign + R2 PUT)"
```

### Task 15: download transport + on-disk cache

**Files:**
- Create: `app/lib/attachment/attachment_download.dart`

- [ ] **Step 1: Implement**

```dart
// app/lib/attachment/attachment_download.dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'attachment_descriptor.dart';
import 'file_crypto.dart';

/// Fetch + decrypt the full file for [descriptor], returning a local plaintext
/// file. Cached by `blob_key` under app-support so re-opening is instant. The
/// content key/nonce come from the (already-decrypted) descriptor; the server
/// never sees them.
Future<File> fetchAndDecrypt({
  required LiveConnection conn,
  required AttachmentDescriptor descriptor,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final dir = await getApplicationSupportDirectory();
  final cacheDir = Directory(p.join(dir.path, 'attachments'));
  await cacheDir.create(recursive: true);
  final cached = File(p.join(cacheDir.path, descriptor.blobKey));
  if (await cached.exists()) return cached;

  final granted = conn.incoming
      .where((f) => f is DownloadGrantedFrame && f.blobKey == descriptor.blobKey)
      .cast<DownloadGrantedFrame>()
      .first
      .timeout(timeout);
  conn.send(RequestDownloadFrame(blobKey: descriptor.blobKey).toJson());
  final grant = await granted;

  final client = httpClient ?? http.Client();
  try {
    final res = await client.get(Uri.parse(grant.url));
    if (res.statusCode != 200) {
      throw http.ClientException('R2 GET failed: HTTP ${res.statusCode}');
    }
    final plain = await decryptFileBytes(
      key: base64ToBytes(descriptor.contentKeyB64),
      nonce: base64ToBytes(descriptor.nonceB64),
      ciphertext: res.bodyBytes,
    );
    // Write atomically: temp then rename, so a crash mid-write can't leave a
    // truncated file masquerading as a complete cache hit.
    final tmp = File('${cached.path}.part');
    await tmp.writeAsBytes(plain, flush: true);
    await tmp.rename(cached.path);
    return cached;
  } finally {
    if (httpClient == null) client.close();
  }
}
```

- [ ] **Step 2: Add the base64 helper** — append to `app/lib/attachment/file_crypto.dart`:

```dart
import 'dart:convert';
// (add `base64` usage)
Uint8List base64ToBytes(String b64) => base64.decode(b64);
```

(If `dart:convert` is already imported elsewhere in the file, just add the function.)

- [ ] **Step 3: Verify it compiles**

Run (from `app/`): `flutter analyze lib/attachment/`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add app/lib/attachment/attachment_download.dart app/lib/attachment/file_crypto.dart
git commit -m "feat(app): attachment download transport + decrypt-to-cache"
```

---

## Phase 5 — Client: message model + send/receive + UI

### Task 16: carry attachments on `Msg`

**Files:**
- Modify: `app/lib/wire/message.dart`
- Test: `app/test/wire/msg_attachment_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wire/msg_attachment_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  test('attachment defaults to null and survives copyWith', () {
    final m = Msg(id: '1', from: 'court', to: 'r', body: '', ts: DateTime.now());
    expect(m.attachment, isNull);
    const d = AttachmentDescriptor(
      blobKey: 'k', contentKeyB64: 'a', nonceB64: 'b', mime: 'image/jpeg',
      filename: 'IMG.jpg', size: 1, width: 1, height: 1, durationMs: null, thumbB64: 't');
    final withAtt = Msg(id: '1', from: 'court', to: 'r', body: '', ts: m.ts, attachment: d);
    expect(withAtt.copyWith(sendStatus: SendStatus.sent).attachment, isNotNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `flutter test test/wire/msg_attachment_test.dart`
Expected: FAIL — `attachment` param doesn't exist.

- [ ] **Step 3: Add the field** — in `app/lib/wire/message.dart`:
  - add import: `import '../attachment/attachment_descriptor.dart';`
  - add constructor param `this.attachment,` (after `this.sendStatus = SendStatus.sent,`)
  - add field: `final AttachmentDescriptor? attachment;`
  - in `copyWith`, thread it through: add `AttachmentDescriptor? attachment,` to the signature and `attachment: attachment ?? this.attachment,` to the returned `Msg`.

`Msg.fromJson`/`toJson` are the legacy Day-1 text wire shape and do NOT need the attachment field (attachments arrive via the v0.3 `MessageFrame` → decrypt → envelope path, not these). Leave them unchanged.

- [ ] **Step 4: Run to verify pass**

Run (from `app/`): `flutter test test/wire/msg_attachment_test.dart`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add app/lib/wire/message.dart app/test/wire/msg_attachment_test.dart
git commit -m "feat(app): carry optional attachment descriptor on Msg"
```

### Task 17: decode the envelope on receive

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`

- [ ] **Step 1: Update `_ingestMessage`** — replace the `Msg` construction block (currently `body: plaintext`) with envelope decoding. After `final plaintext = await decryptIncoming(key, f.body);`:

```dart
    // A decrypt failure returns the sentinel; render it as text verbatim
    // rather than trying to parse it as an envelope.
    final content = plaintext == cannotDecryptSentinel
        ? const TextContent(cannotDecryptSentinel)
        : MessageContent.decode(plaintext);
    final msg = switch (content) {
      TextContent(:final text) => Msg(
          id: f.id, from: f.from, to: f.roomId, body: text, ts: f.ts,
          replayed: f.replayed,
        ),
      FileContent(:final descriptor) => Msg(
          id: f.id, from: f.from, to: f.roomId, body: '', ts: f.ts,
          replayed: f.replayed, attachment: descriptor,
        ),
    };
```

- [ ] **Step 2: Add imports** to `room_message_router.dart`:

```dart
import 'message_content.dart';
```

(`cannotDecryptSentinel` is already available via the existing `import '../pairing/encryption.dart';`.)

- [ ] **Step 3: Verify it compiles + existing message tests pass**

Run (from `app/`): `flutter test test/conversation/ && flutter analyze lib/conversation/room_message_router.dart`
Expected: existing conversation tests still PASS (text path unchanged in behavior — a `TextContent` envelope decodes to the same `body` string); analyze clean.

- [ ] **Step 4: Commit**

```bash
git add app/lib/conversation/room_message_router.dart
git commit -m "feat(app): decode content envelope into text/attachment on receive"
```

### Task 18: send path — wrap text, add attachment send

**Files:**
- Modify: `app/lib/screens/inbox/inbox_shell.dart`

Key insight that simplifies restart handling: the attachment descriptor (incl. the inline thumb) lives inside the encrypted message body. So even if the app is killed before the echo, when the outbox drains and the server echoes the self-copy, the router decodes the body → `FileContent` → renders the full tile. No attachment state needs to persist in the outbox beyond the ciphertext it already stores.

- [ ] **Step 1: Wrap outgoing text in the envelope** — in `_sendEncrypted`, change the `buildSendFrame` call's `plaintext:`:

```dart
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: account.username,
        plaintext: TextContent(text).encode(),
        cache: cache,
        clientMsgId: clientMsgId,
      );
```

The optimistic `Msg` still uses `body: text` (display text), unchanged.

- [ ] **Step 2: Add the attachment send method** — add to the same widget class:

```dart
  /// Encrypt + upload an attachment, then send it as a `kind:"file"` message
  /// through the same outbox path as text. The optimistic bubble carries the
  /// locally built descriptor (incl. inline thumb) so the preview shows
  /// immediately; the authoritative row replaces it on the server echo.
  Future<void> _sendAttachment(
    WidgetRef ref,
    Room room, {
    required Uint8List bytes,
    required String filename,
    required String mime,
    String? videoPath,
  }) async {
    final clientMsgId = ref.read(outboxIdGenProvider)();
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    if (bytes.length > 500 * 1024 * 1024) {
      // Over the 500 MiB cap (spec §4) — surface and bail.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That file is too large (max 500 MB).')),
      );
      return;
    }
    try {
      final thumb = mime.startsWith('video/') && videoPath != null
          ? await buildVideoThumbnail(videoPath)
          : await buildImageThumbnail(bytes);
      final enc = await encryptFileBytes(bytes);
      final blobKey = await uploadCiphertext(
        conn: conn, roomId: room.roomId, ciphertext: enc.ciphertext);

      final descriptor = AttachmentDescriptor(
        blobKey: blobKey,
        contentKeyB64: base64.encode(enc.key),
        nonceB64: base64.encode(enc.nonce),
        mime: mime,
        filename: filename,
        size: bytes.length,
        width: thumb.width,
        height: thumb.height,
        durationMs: null, // populated for video in a follow-up if needed
        thumbB64: await encodeThumb(thumb.jpeg),
      );

      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: account.username,
        plaintext: FileContent(descriptor).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId, roomId: room.roomId, bodies: frame.bodies);
      ref.read(messageStoreProvider(room.roomId).notifier).add(
            Msg(
              id: clientMsgId,
              from: account.username,
              to: room.roomId,
              body: '',
              ts: DateTime.now().toUtc(),
              clientMsgId: clientMsgId,
              sendStatus: SendStatus.sending,
              attachment: descriptor,
            ),
          );
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      debugPrint('attachment send failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send attachment.')),
      );
    }
  }
```

- [ ] **Step 3: Add imports** to `inbox_shell.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import '../../attachment/attachment_descriptor.dart';
import '../../attachment/attachment_upload.dart';
import '../../attachment/file_crypto.dart';
import '../../attachment/thumbnail.dart';
import '../../conversation/message_content.dart';
```

- [ ] **Step 4: Verify it compiles**

Run (from `app/`): `flutter analyze lib/screens/inbox/inbox_shell.dart`
Expected: no errors (an unused `_sendAttachment` warning is fine until Task 20 wires it).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/inbox/inbox_shell.dart
git commit -m "feat(app): send text via envelope; add attachment send pipeline"
```

### Task 19: render the media tile

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`

When `m.attachment != null`, render a media tile (inline thumb + overlay) instead of a text bubble. Match the mockup (`docs/mocks/attachments.html` screens 4–5): sent media in a faint twilight bubble; video shows a centered play overlay.

- [ ] **Step 1: Add a `_MediaBubble` widget** near the bottom of `conversation_page.dart`:

```dart
class _MediaBubble extends StatelessWidget {
  const _MediaBubble({required this.msg, required this.isMe, required this.onOpen});
  final Msg msg;
  final bool isMe;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final d = msg.attachment!;
    final aspect = (d.width > 0 && d.height > 0) ? d.width / d.height : 4 / 3;
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isMe ? TwilightColors.bubbleUserBg : TwilightColors.bubblePartnerBg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: aspect.clamp(0.6, 1.9),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ThumbImage(thumbB64: d.thumbB64),
                if (d.isVideo) const Center(child: _PlayBadge()),
                if (msg.sendStatus == SendStatus.sending)
                  Container(
                    color: const Color(0x57F4EBEC),
                    child: const Center(
                      child: SizedBox(
                        width: 30, height: 30,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Decodes + decrypts the inline thumb (FutureBuilder; tiny, fast).
class _ThumbImage extends StatefulWidget {
  const _ThumbImage({required this.thumbB64});
  final String thumbB64;
  @override
  State<_ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<_ThumbImage> {
  late final Future<Uint8List> _bytes = decodeThumb(widget.thumbB64);
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (_, snap) {
        if (snap.hasData) {
          return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
        }
        return Container(color: TwilightColors.bgSurfaceAlt);
      },
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();
  @override
  Widget build(BuildContext context) => Container(
        width: 52, height: 52,
        decoration: BoxDecoration(
          color: const Color(0x6B140C12),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xBFFFFFFF), width: 1.5),
        ),
        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
      );
}
```

- [ ] **Step 2: Branch the bubble builder** — find where a `Msg` renders its text bubble (the widget consuming `m.body` and the in-bubble status marker, near the status-model usage). At the top of that per-message build, add:

```dart
        if (m.attachment != null) {
          return Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: _MediaBubble(
                msg: m, isMe: isMe,
                onOpen: () => onOpenAttachment(m.attachment!),
              ),
            ),
          );
        }
```

Reuse the `isMe` already computed in that scope. `onOpenAttachment` is a new `ConversationPage` callback (next step).

- [ ] **Step 3: Add the `onOpenAttachment` callback** to `ConversationPage` (alongside `onSend`/`onRetry`): `final void Function(AttachmentDescriptor descriptor) onOpenAttachment;`. Add `import '../attachment/attachment_descriptor.dart';` and `import 'dart:typed_data';`.

- [ ] **Step 4: Verify it compiles**

Run (from `app/`): `flutter analyze lib/conversation/conversation_page.dart`
Expected: only errors about the not-yet-passed `onOpenAttachment`/`onAttach` at the `inbox_shell` call site (fixed in Task 20).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/conversation_page.dart
git commit -m "feat(app): render inline media tile (thumb + play badge + sending state)"
```

### Task 20: composer attach button, picker, and viewer

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`, `app/lib/screens/inbox/inbox_shell.dart`
- Create: `app/lib/attachment/attachment_viewer.dart`

- [ ] **Step 1: Add the attach affordance** — in `conversation_page.dart`, add callback `final Future<void> Function() onAttach;` and a leading `IconButton(icon: const Icon(Icons.add), onPressed: onAttach)` in the composer row, left of the text field.

- [ ] **Step 2: Create the viewer**

```dart
// app/lib/attachment/attachment_viewer.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'attachment_descriptor.dart';

/// Full-screen viewer for a decrypted attachment file. Image → InteractiveViewer;
/// video → video_player. [file] is the decrypted plaintext on local disk.
class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({super.key, required this.file, required this.descriptor});
  final File file;
  final AttachmentDescriptor descriptor;
  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.descriptor.isVideo) {
      _video = VideoPlayerController.file(widget.file)
        ..initialize().then((_) {
          if (mounted) setState(() => _video!..play());
        });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      backgroundColor: const Color(0xFF140C12),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(widget.descriptor.filename, style: const TextStyle(fontSize: 13)),
      ),
      body: Center(
        child: widget.descriptor.isVideo
            ? (v != null && v.value.isInitialized
                ? GestureDetector(
                    onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
                    child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
                  )
                : const CircularProgressIndicator())
            : InteractiveViewer(child: Image.file(widget.file)),
      ),
    );
  }
}
```

- [ ] **Step 3: Wire composer + open in `inbox_shell.dart`** — in the `ConversationPage(...)` construction add:

```dart
      onAttach: () => _pickAndSend(ref, room),
      onOpenAttachment: (descriptor) => _openAttachment(ref, room, descriptor),
```

Add the methods:

```dart
  Future<void> _pickAndSend(WidgetRef ref, Room room) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo Library'),
            onTap: () => Navigator.pop(context, 'photos'),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('Choose File'),
            onTap: () => Navigator.pop(context, 'file'),
          ),
        ]),
      ),
    );
    if (choice == 'photos') {
      final picked = await ImagePicker().pickMedia();
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final mime = _mimeFor(picked.name, picked.mimeType);
      await _sendAttachment(ref, room,
          bytes: bytes, filename: picked.name, mime: mime,
          videoPath: mime.startsWith('video/') ? picked.path : null);
    } else if (choice == 'file') {
      final res = await FilePicker.platform.pickFiles(withReadStream: false);
      final f = res?.files.singleOrNull;
      if (f == null || f.path == null) return;
      final bytes = await File(f.path!).readAsBytes();
      final mime = _mimeFor(f.name, null);
      await _sendAttachment(ref, room,
          bytes: bytes, filename: f.name, mime: mime,
          videoPath: mime.startsWith('video/') ? f.path : null);
    }
  }

  String _mimeFor(String name, String? hint) {
    if (hint != null && hint.isNotEmpty) return hint;
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) return 'video/mp4';
    if (lower.endsWith('.png')) return 'image/png';
    return 'image/jpeg';
  }

  Future<void> _openAttachment(
    WidgetRef ref, Room room, AttachmentDescriptor descriptor) async {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    try {
      final file = await fetchAndDecrypt(conn: conn, descriptor: descriptor);
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AttachmentViewer(file: file, descriptor: descriptor),
      ));
    } catch (e) {
      debugPrint('open attachment failed: $e');
    }
  }
```

- [ ] **Step 4: Add imports** to `inbox_shell.dart`:

```dart
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../../attachment/attachment_download.dart';
import '../../attachment/attachment_viewer.dart';
```

- [ ] **Step 5: Verify it compiles**

Run (from `app/`): `flutter analyze`
Expected: no errors across the app.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/lib/screens/inbox/inbox_shell.dart app/lib/attachment/attachment_viewer.dart
git commit -m "feat(app): composer attach sheet, photo/file picker, full-screen viewer"
```

---

## Phase 6 — Infra, on-device verification, finalize

### Task 21: provision R2 + set secrets

**Files:**
- Modify: `infra/cloudflare/main.tf` (or a new `r2.tf`), `infra/cloudflare/variables.tf`, `infra/cloudflare/outputs.tf`

This is an ops task — no automated test; verified by the on-device test (Task 22).

- [ ] **Step 1: Add the R2 bucket** — in `infra/cloudflare/r2.tf`:

```hcl
resource "cloudflare_r2_bucket" "media" {
  account_id = var.cloudflare_account_id
  name       = "littlelove-media"
  location   = "ENAM" # eastern North America; match your user base
}
```

(Confirm `var.cloudflare_account_id` exists in `variables.tf`; if not, add it.)

- [ ] **Step 2: Create a scoped R2 API token** — in the Cloudflare dashboard (R2 → Manage API Tokens), create an **Object Read & Write** token scoped to the `littlelove-media` bucket. Record the Access Key ID and Secret Access Key. (R2 S3 tokens are not currently well-supported as Terraform resources; create manually and document here.)

- [ ] **Step 3: Set Railway secrets** — on the API service:

```bash
railway variables --set R2_ACCOUNT_ID=<account-id> \
  --set R2_BUCKET=littlelove-media \
  --set R2_ACCESS_KEY_ID=<access-key-id> \
  --set R2_SECRET_ACCESS_KEY=<secret>
```

(Or via the Railway dashboard. Do NOT commit these values.)

- [ ] **Step 4: Apply Terraform**

Run (from `infra/cloudflare/`): `tofu plan` then `tofu apply`
Expected: the `littlelove-media` bucket is created. No CORS config is needed (iOS uses native HTTP, not a browser origin).

- [ ] **Step 5: Commit (infra code only — never secrets)**

```bash
git add infra/cloudflare/r2.tf infra/cloudflare/variables.tf
git commit -m "infra(cloudflare): provision littlelove-media R2 bucket"
```

### Task 22: end-to-end on-device verification + full sweep

No code; this is the acceptance gate. Uses the two-Mac demo flow (`scripts/demo.sh`) with an iOS target, or two iПhones.

- [ ] **Step 1: Full automated sweep**

Run (server, with dev DB up): `cargo test`
Run (from `app/`): `flutter test && flutter analyze`
Expected: all green.

- [ ] **Step 2: Send a photo (golden path)** — Build to a real iPhone (`flutter run --release -d <device>` after `./scripts/dev-up.sh` and pointing config at the API). As Court, tap `+` → Photo Library → pick a photo. Expected: optimistic tile appears with the thumbnail + spinner; flips to a heart when the server acks. As Kaitlyn (second device), the photo tile appears with the inline preview immediately; tapping it opens the full image.

- [ ] **Step 3: Send a video** — As Court, `+` → Photo Library → pick a video clip. Expected: poster-frame thumbnail with a play badge; Kaitlyn sees the same, taps → it downloads, decrypts, and plays in the viewer.

- [ ] **Step 4: Size rejection** — Attempt a file > 500 MiB. Expected: "too large (max 500 MB)" snackbar; nothing enqueued.

- [ ] **Step 5: Memory check at the cap (spec §4)** — Send a file at/near 500 MiB on a real iPhone; watch Xcode's memory gauge. If the app approaches jetsam limits (~1.5 GB), drop `MAX_ATTACHMENT_BYTES` (server) and the client `500 * 1024 * 1024` guard to 256 MiB and re-test. Record the observed peak in the PR description.

- [ ] **Step 6: Restart durability** — Send a photo, kill the app before the heart appears, relaunch. Expected: the outbox drains, the server echoes the self-copy, and the message renders fully (the descriptor + thumb live in the encrypted body, so it reconstructs without any persisted attachment state).

- [ ] **Step 7: Final commit / PR**

```bash
git add -A && git commit -m "test: attachments end-to-end verification notes" --allow-empty
```

Open a PR summarizing the feature, the observed memory peak (Step 5), and any cap adjustment.

---

## Self-Review

**Spec coverage:** §3 envelope → Task 11; §4 file crypto + one-shot/raw-bytes → Tasks 9, 14, 15, 22(step 5); §5.1 table → Task 1; §5.2 frames+handlers → Tasks 5–7; §5.3 R2 presign → Tasks 3–4; §5.4 commit-on-send → deferred (documented in spec); §5.5 body cap → Task 6; §6.1 send → Tasks 13, 14, 18, 20; §6.2 receive → Tasks 15, 17, 19, 20; §6.3 modules → Tasks 9–15; §7 outbox unchanged → Task 18 (reuses enqueue); §8 infra → Task 21, orphan reaper deferred; §9 testing → Tasks 6/7 (server), 9–11/13/16 (unit), 22 (on-device); §2 platform/packages → Task 8.

**Known integration risks flagged inline for the implementer:** (1) `seed_trio_room` pubkey vs `signing_key_from_seed` mismatch — reconcile in Task 7; (2) `rusty-s3` method names may differ by version — adapt in Task 4; (3) exact location of the text-bubble builder in the large `conversation_page.dart` — Task 19 step 2 describes how to find it; (4) upload progress is indeterminate (no `dio`) — noted in Task 14.

**Type consistency:** `AttachmentDescriptor` fields/`toJson` keys match `fromJson` and the `FileContent.encode` spread (Tasks 10–11). `EncryptedFile{key,nonce,ciphertext}` consistent across Tasks 9/10/14/18. Frame names (`RequestUploadFrame`, `UploadGrantedFrame`, etc.) consistent across Tasks 12/14/15. Server `MAX_ATTACHMENT_BYTES` (Task 6) matches the client 500 MiB guard (Task 18) and the rejection test (Task 7).
