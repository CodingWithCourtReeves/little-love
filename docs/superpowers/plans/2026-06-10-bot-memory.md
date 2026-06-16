> **HISTORICAL — superseded (annotated 2026-06-16).** This document predates the
> removal of the AI "familiar" / bring-your-own-model feature. LittleLove is now a
> couples-first, channels-based, fully end-to-end-encrypted messenger with **no AI
> and no familiars**. Any mention below of bots, familiars, character cards, LLMs,
> or cloud/local AI describes a **retired** design and does NOT reflect the current
> product. For current framing see `README.md` and `docs/positioning.md`.

# LittleLove Bot Long-Term Memory (v0.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bot's in-memory `History` with persistent per-room SQLite memory, a hand-edited `facts.md`, and an async background summary loop — so the bot remembers across restarts.

**Architecture:** A new `bot/src/memory.rs` module owns a per-room SQLite database (`<memory-dir>/rooms/<room_id>/memory.sqlite`) and reads a sibling `facts.md`. `Memory::open` runs a `PRAGMA user_version` migration ladder with backup-on-migrate. Each reply assembles a prompt from `persona + facts.md + summary + recent-turns` under a char-budget. After every assistant turn the run loop checks a turn-count threshold and `tokio::spawn`s a background summary refresh that snapshots needed data, releases its DB lock, calls the LLM, then re-acquires the lock briefly to write the new summary row. A new `doctor` subcommand introspects state without writing.

**Tech Stack:** Rust, `rusqlite` (bundled SQLite), `regex` (summary parser), `tokio` (async), existing `directories` / `clap` / `tracing` / `anyhow` / `thiserror`. Local-only LLM via existing `LlmClient` (private-IP guarded).

**Spec:** `docs/superpowers/specs/2026-06-10-bot-memory-design.md`

---

## Module / file plan

| Path | Responsibility | Status |
|---|---|---|
| `bot/Cargo.toml` | Add `rusqlite` (bundled) and `regex` deps. | Modify |
| `bot/src/memory.rs` | `Memory` struct: open + migrate + record turn + assemble prompt + needs_summary + summary snapshot / commit. Includes private summary parser. | Create |
| `bot/src/summary_task.rs` | Free async function `run_summary_refresh(Arc<Mutex<Memory>>, Arc<LlmClient>, ...)` + private `build_summary_messages`. Owns the brief-lock / await / brief-lock pattern. | Create |
| `bot/src/doctor.rs` | `doctor` subcommand handler. Read-only inspection of the memory dir. | Create |
| `bot/src/llm.rs` | Refactor `LlmClient::chat` to take `&[ChatMessage]` directly; expose `ChatMessage` publicly. Drop the `LlmRequest` shim and the `&History` dependency. | Modify |
| `bot/src/cli.rs` | Add `--memory-dir`, `--summary-every`, `--max-context-chars` to `RunArgs`. Repurpose `--history` doc. Add `Doctor` subcommand + `DoctorArgs`. | Modify |
| `bot/src/main.rs` | Dispatch `Doctor` subcommand. | Modify |
| `bot/src/lib.rs` | Register new modules; remove `history`. | Modify |
| `bot/src/run.rs` | Replace `History` with `Arc<Mutex<Memory>>`, wire `record_turn`/`assemble_prompt`, spawn summary refresh, startup-sync-summary-if-needed. | Modify |
| `bot/src/history.rs` | Delete — `Memory` replaces it wholesale. | Delete |
| `bot/tests/memory_smoke.rs` | Integration test: real SQLite tempdir + mocked LLM, drives a few rounds + summary trigger. | Create |
| `bot/tests/doctor_smoke.rs` | Integration test: spawn `doctor` against tempdir scenarios. | Create |
| `bot/README.md` | Document `--memory-dir`, `doctor`, editing `facts.md`, and backup story. | Modify |

### Rationale for the `summary_task.rs` split

The spec sketches `Memory::refresh_summary(&mut self, llm: &LlmClient, ...)` as a single async method. We deviate intentionally: holding `&mut self` (with its `rusqlite::Connection`) across the LLM `.await` either blocks the reply loop on the mutex while the LLM runs, or wedges us into self-referential lifetime trouble with `Arc<Mutex<Memory>>`. Splitting into `snapshot_for_summary` (sync, brief lock) → LLM call (no lock) → `commit_summary` (sync, brief lock) is the correct shape for the spec's stated goal: "never blocks the reply loop." The orchestration lives in `summary_task.rs::run_summary_refresh`.

---

## Hard invariants the plan must preserve

- No cloud AI — all LLM calls go through the existing `LlmClient`, which runs `ensure_url_is_private`. Do not bypass.
- E2EE — memory writes happen *after* `aead::decrypt_wire` on the bot's local disk only. Never store ciphertext, never relay plaintext.
- Tests are real — SQLite tests hit a `tempfile::tempdir()` DB, not a mock. Crypto is not touched by this work.
- Conventional commits, frequent.

---

## Task 1: Add new crate dependencies

**Files:**
- Modify: `bot/Cargo.toml`

- [ ] **Step 1: Add `rusqlite` and `regex` to `[dependencies]`**

In `bot/Cargo.toml`, append below the existing dep list:

```toml
rusqlite          = { version = "0.31", features = ["bundled"] }
regex             = "1"
```

- [ ] **Step 2: Verify the workspace still builds**

Run: `cargo build -p littlelove-bot`
Expected: PASS (clean build, possibly slow on the first SQLite compile).

- [ ] **Step 3: Commit**

```bash
git add bot/Cargo.toml Cargo.lock
git commit -m "chore(bot): add rusqlite (bundled) and regex for memory module"
```

---

## Task 2: Skeleton `memory.rs` module

**Files:**
- Create: `bot/src/memory.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Write the failing test**

In a new `bot/src/memory.rs`, add at the bottom:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn open_on_fresh_dir_creates_room_tree_and_schema_v1() {
        let dir = tempdir().unwrap();
        let mem = Memory::open(dir.path(), "01TESTROOM").expect("open");
        assert_eq!(mem.schema_version(), 1);
        let room_dir = dir.path().join("rooms").join("01TESTROOM");
        assert!(room_dir.join("memory.sqlite").exists());
    }
}
```

And the bare skeleton above it:

```rust
//! Persistent per-room memory: SQLite turn log + summary row + facts.md sidecar.
//!
//! See docs/superpowers/specs/2026-06-10-bot-memory-design.md.

use std::path::{Path, PathBuf};

use anyhow::Result;
use rusqlite::Connection;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    pub fn as_str(&self) -> &'static str {
        match self {
            Role::User => "user",
            Role::Assistant => "assistant",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Summary {
    pub events: String,
    pub character: String,
    pub covers_up_to_turn_id: i64,
    pub updated_ts: i64,
}

pub struct Memory {
    db: Connection,
    facts_path: PathBuf,
    summary: Option<Summary>,
    schema_version: u32,
}

impl Memory {
    pub fn open(_memory_dir: &Path, _room_id: &str) -> Result<Self> {
        unimplemented!("Task 3 implements this")
    }

    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }
}
```

Register it in `bot/src/lib.rs` — add `pub mod memory;` next to the other modules.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p littlelove-bot --lib memory::tests::open_on_fresh_dir_creates_room_tree_and_schema_v1 -- --nocapture`
Expected: PANIC with `not yet implemented: Task 3 implements this`.

- [ ] **Step 3: Commit**

```bash
git add bot/src/memory.rs bot/src/lib.rs
git commit -m "feat(bot): scaffold Memory module (open is stubbed)"
```

---

## Task 3: Implement `Memory::open` + v0→v1 migration

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Implement open() with migration ladder**

Replace the stubbed `open` and add the helpers below it:

```rust
impl Memory {
    pub fn open(memory_dir: &Path, room_id: &str) -> Result<Self> {
        use anyhow::Context;

        let room_dir = memory_dir.join("rooms").join(room_id);
        std::fs::create_dir_all(&room_dir)
            .with_context(|| format!("create {}", room_dir.display()))?;
        set_dir_perms_0700(&room_dir)?;

        let db_path = room_dir.join("memory.sqlite");
        let facts_path = room_dir.join("facts.md");

        let mut db = Connection::open(&db_path)
            .with_context(|| format!("open {}", db_path.display()))?;
        db.pragma_update(None, "journal_mode", "WAL")?;

        migrate_up(&mut db, &db_path, SCHEMA_VERSION)?;
        set_file_perms_0600(&db_path)?;

        let summary = load_summary(&db)?;

        Ok(Self {
            db,
            facts_path,
            summary,
            schema_version: SCHEMA_VERSION,
        })
    }
}

fn current_user_version(db: &Connection) -> Result<u32> {
    let v: u32 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    Ok(v)
}

fn migrate_up(db: &mut Connection, db_path: &Path, expected: u32) -> Result<()> {
    use anyhow::{anyhow, Context};

    let current = current_user_version(db)?;
    if current == expected {
        return Ok(());
    }
    if current > expected {
        return Err(anyhow!(
            "memory.sqlite at {} was written by a newer bot (schema {current}, this is {expected}). \
             Upgrade the bot or run with --memory-dir <new-path> to start fresh.",
            db_path.display()
        ));
    }
    // current < expected: back up, then apply each step in its own transaction.
    let backup = db_path.with_file_name(format!(
        "{}.bak-v{}",
        db_path.file_name().unwrap().to_string_lossy(),
        current
    ));
    std::fs::copy(db_path, &backup)
        .with_context(|| format!("backup {} -> {}", db_path.display(), backup.display()))?;
    for v in (current + 1)..=expected {
        let tx = db.transaction()?;
        apply_migration(&tx, v)?;
        tx.pragma_update(None, "user_version", v)?;
        tx.commit()?;
    }
    Ok(())
}

fn apply_migration(tx: &rusqlite::Transaction, target: u32) -> Result<()> {
    use anyhow::anyhow;
    match target {
        1 => {
            tx.execute_batch(
                "CREATE TABLE turn (
                    id      INTEGER PRIMARY KEY,
                    ts      INTEGER NOT NULL,
                    role    TEXT NOT NULL,
                    content TEXT NOT NULL
                );
                 CREATE INDEX turn_ts_idx ON turn(ts);
                 CREATE TABLE summary (
                    id                   INTEGER PRIMARY KEY CHECK (id = 1),
                    events               TEXT NOT NULL,
                    character            TEXT NOT NULL,
                    covers_up_to_turn_id INTEGER NOT NULL,
                    updated_ts           INTEGER NOT NULL
                 );",
            )?;
            Ok(())
        }
        other => Err(anyhow!("no migration registered for user_version = {other}")),
    }
}

fn load_summary(db: &Connection) -> Result<Option<Summary>> {
    let mut stmt = db.prepare(
        "SELECT events, character, covers_up_to_turn_id, updated_ts FROM summary WHERE id = 1",
    )?;
    let mut rows = stmt.query([])?;
    if let Some(row) = rows.next()? {
        Ok(Some(Summary {
            events: row.get(0)?,
            character: row.get(1)?,
            covers_up_to_turn_id: row.get(2)?,
            updated_ts: row.get(3)?,
        }))
    } else {
        Ok(None)
    }
}

#[cfg(unix)]
fn set_dir_perms_0700(p: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_dir_perms_0700(_p: &Path) -> Result<()> { Ok(()) }

#[cfg(unix)]
fn set_file_perms_0600(p: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_file_perms_0600(_p: &Path) -> Result<()> { Ok(()) }
```

- [ ] **Step 2: Run the existing test to verify it passes**

Run: `cargo test -p littlelove-bot --lib memory::tests::open_on_fresh_dir_creates_room_tree_and_schema_v1`
Expected: PASS.

- [ ] **Step 3: Add an idempotency test**

Append to the existing `mod tests`:

```rust
    #[test]
    fn open_is_idempotent() {
        let dir = tempdir().unwrap();
        let _m1 = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let _m2 = Memory::open(dir.path(), "01TESTROOM").unwrap();
        // Second open must not create a second backup (no migration happened).
        let room_dir = dir.path().join("rooms").join("01TESTROOM");
        let bak = room_dir.join("memory.sqlite.bak-v0");
        // first open created bak-v0; second open must NOT create bak-v1.
        assert!(bak.exists(), "first open should create bak-v0");
        assert!(!room_dir.join("memory.sqlite.bak-v1").exists());
    }
```

Run: `cargo test -p littlelove-bot --lib memory::tests::open_is_idempotent`
Expected: PASS.

- [ ] **Step 4: Add the future-schema-refusal test**

Append:

```rust
    #[test]
    fn open_refuses_newer_schema() {
        let dir = tempdir().unwrap();
        let room_dir = dir.path().join("rooms").join("01TESTROOM");
        std::fs::create_dir_all(&room_dir).unwrap();
        let db_path = room_dir.join("memory.sqlite");
        let conn = Connection::open(&db_path).unwrap();
        conn.pragma_update(None, "user_version", 99u32).unwrap();
        drop(conn);

        let err = Memory::open(dir.path(), "01TESTROOM").unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("newer bot"), "got: {msg}");
        assert!(msg.contains("schema 99"), "got: {msg}");
    }
```

Run: `cargo test -p littlelove-bot --lib memory::tests::open_refuses_newer_schema`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): Memory::open with v0→v1 schema migration and backup"
```

---

## Task 4: `record_turn` + accessor

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
    #[test]
    fn record_turn_appends_with_monotonic_ts_and_returns_id() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let id1 = m.record_turn(Role::User, "hello").unwrap();
        let id2 = m.record_turn(Role::Assistant, "hi back").unwrap();
        assert!(id2 > id1);
        let turns = m.recent_turns(10).unwrap();
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].role, Role::User);
        assert_eq!(turns[0].content, "hello");
        assert_eq!(turns[1].role, Role::Assistant);
        assert_eq!(turns[1].content, "hi back");
        assert!(turns[1].ts >= turns[0].ts);
    }

    #[test]
    fn latest_turn_id_is_zero_when_empty() {
        let dir = tempdir().unwrap();
        let m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        assert_eq!(m.latest_turn_id().unwrap(), 0);
    }
```

- [ ] **Step 2: Verify they fail**

Run: `cargo test -p littlelove-bot --lib memory::tests::record_turn`
Expected: FAIL (methods don't exist).

- [ ] **Step 3: Implement**

Add to `impl Memory`:

```rust
    pub fn record_turn(&mut self, role: Role, content: &str) -> Result<i64> {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.db.execute(
            "INSERT INTO turn (ts, role, content) VALUES (?1, ?2, ?3)",
            rusqlite::params![ts, role.as_str(), content],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    pub fn latest_turn_id(&self) -> Result<i64> {
        let id: Option<i64> = self
            .db
            .query_row("SELECT MAX(id) FROM turn", [], |r| r.get(0))?;
        Ok(id.unwrap_or(0))
    }

    pub fn recent_turns(&self, limit: usize) -> Result<Vec<TurnRecord>> {
        let mut stmt = self.db.prepare(
            "SELECT id, ts, role, content FROM turn ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(rusqlite::params![limit as i64], |r| {
            let role_s: String = r.get(2)?;
            let role = match role_s.as_str() {
                "user" => Role::User,
                "assistant" => Role::Assistant,
                _ => Role::User,
            };
            Ok(TurnRecord {
                id: r.get(0)?,
                ts: r.get(1)?,
                role,
                content: r.get(3)?,
            })
        })?;
        let mut out: Vec<TurnRecord> = rows.collect::<rusqlite::Result<_>>()?;
        out.reverse(); // oldest-first
        Ok(out)
    }
```

And at the top of the file (next to `Summary`):

```rust
#[derive(Debug, Clone)]
pub struct TurnRecord {
    pub id: i64,
    pub ts: i64,
    pub role: Role,
    pub content: String,
}
```

- [ ] **Step 4: Verify tests pass**

Run: `cargo test -p littlelove-bot --lib memory::`
Expected: PASS for the new tests; older tests still green.

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): Memory record_turn + recent_turns + latest_turn_id"
```

---

## Task 5: Summary parser

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
    #[test]
    fn parse_summary_basic() {
        let raw = "EVENTS:\nWe talked about cats.\nShe likes calicos.\n\nCHARACTER:\nI feel warm about her preferences.\n";
        let (events, character) = parse_summary_response(raw).unwrap();
        assert_eq!(events.trim(), "We talked about cats.\nShe likes calicos.");
        assert_eq!(character.trim(), "I feel warm about her preferences.");
    }

    #[test]
    fn parse_summary_tolerates_leading_whitespace_and_extra_text() {
        let raw = "  \nEVENTS:\n  alpha\nCHARACTER:\n  beta";
        let (e, c) = parse_summary_response(raw).unwrap();
        assert_eq!(e.trim(), "alpha");
        assert_eq!(c.trim(), "beta");
    }

    #[test]
    fn parse_summary_rejects_missing_character_section() {
        let raw = "EVENTS:\nstuff happened\n";
        assert!(parse_summary_response(raw).is_err());
    }

    #[test]
    fn parse_summary_rejects_missing_events_section() {
        let raw = "CHARACTER:\nI feel things\n";
        assert!(parse_summary_response(raw).is_err());
    }
```

- [ ] **Step 2: Verify they fail**

Run: `cargo test -p littlelove-bot --lib memory::tests::parse_summary`
Expected: FAIL (function not defined).

- [ ] **Step 3: Implement**

Above `impl Memory`, add:

```rust
/// Split a summary LLM response into (events, character).
///
/// Expects line-anchored `EVENTS:` and `CHARACTER:` headers in that order.
pub fn parse_summary_response(raw: &str) -> Result<(String, String)> {
    use anyhow::anyhow;
    use regex::Regex;

    let re = Regex::new(r"(?m)^\s*(EVENTS|CHARACTER):").expect("static regex");
    let mut events: Option<String> = None;
    let mut character: Option<String> = None;

    let mut spans: Vec<(usize, usize, &str)> = Vec::new(); // (header_end, kind_start, kind)
    for m in re.find_iter(raw) {
        // capture which kind
        let caps = re.captures(&raw[m.start()..m.end()]).unwrap();
        let kind = caps.get(1).unwrap().as_str();
        spans.push((m.end(), m.start(), kind));
    }
    if spans.is_empty() {
        return Err(anyhow!("summary response missing EVENTS:/CHARACTER: headers"));
    }
    for (i, (header_end, _start, kind)) in spans.iter().enumerate() {
        let end = spans.get(i + 1).map(|(_, s, _)| *s).unwrap_or(raw.len());
        let body = raw[*header_end..end].to_string();
        match *kind {
            "EVENTS" => events = Some(body),
            "CHARACTER" => character = Some(body),
            _ => {}
        }
    }
    let events = events.ok_or_else(|| anyhow!("summary missing EVENTS section"))?;
    let character = character.ok_or_else(|| anyhow!("summary missing CHARACTER section"))?;
    Ok((events, character))
}
```

- [ ] **Step 4: Verify tests pass**

Run: `cargo test -p littlelove-bot --lib memory::tests::parse_summary`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): parse EVENTS/CHARACTER sections from summary LLM output"
```

---

## Task 6: `needs_summary` + `snapshot_for_summary` + `commit_summary`

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
    #[test]
    fn needs_summary_false_on_empty_db() {
        let dir = tempdir().unwrap();
        let m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        assert!(!m.needs_summary(5).unwrap());
    }

    #[test]
    fn needs_summary_true_after_threshold_exceeded() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        for i in 0..6 {
            m.record_turn(Role::User, &format!("u{i}")).unwrap();
        }
        assert!(m.needs_summary(5).unwrap());
    }

    #[test]
    fn commit_summary_then_needs_summary_false_under_threshold() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        for i in 0..6 {
            m.record_turn(Role::User, &format!("u{i}")).unwrap();
        }
        let latest = m.latest_turn_id().unwrap();
        m.commit_summary("events text".into(), "character text".into(), latest)
            .unwrap();
        assert!(!m.needs_summary(5).unwrap());
        // The in-memory cache is updated:
        let s = m.summary().expect("summary loaded");
        assert_eq!(s.events, "events text");
        assert_eq!(s.character, "character text");
        assert_eq!(s.covers_up_to_turn_id, latest);
    }

    #[test]
    fn snapshot_for_summary_returns_only_new_turns() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        for i in 0..3 {
            m.record_turn(Role::User, &format!("u{i}")).unwrap();
        }
        m.commit_summary("prev events".into(), "prev character".into(), m.latest_turn_id().unwrap())
            .unwrap();
        for i in 0..2 {
            m.record_turn(Role::Assistant, &format!("a{i}")).unwrap();
        }
        let snap = m.snapshot_for_summary().unwrap();
        assert_eq!(snap.new_turns.len(), 2);
        assert_eq!(snap.prev_events.as_deref(), Some("prev events"));
        assert_eq!(snap.prev_character.as_deref(), Some("prev character"));
        assert_eq!(snap.covers_up_to_turn_id, m.latest_turn_id().unwrap());
    }
```

- [ ] **Step 2: Verify they fail**

Run: `cargo test -p littlelove-bot --lib memory::tests::needs_summary memory::tests::commit_summary memory::tests::snapshot_for_summary`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add to `impl Memory`:

```rust
    pub fn summary(&self) -> Option<&Summary> {
        self.summary.as_ref()
    }

    pub fn needs_summary(&self, threshold: usize) -> Result<bool> {
        let latest = self.latest_turn_id()?;
        let covers = self.summary.as_ref().map(|s| s.covers_up_to_turn_id).unwrap_or(0);
        Ok((latest - covers) as usize > threshold)
    }

    pub fn snapshot_for_summary(&self) -> Result<SummarySnapshot> {
        let covers = self.summary.as_ref().map(|s| s.covers_up_to_turn_id).unwrap_or(0);
        let mut stmt = self.db.prepare(
            "SELECT id, ts, role, content FROM turn WHERE id > ?1 ORDER BY id ASC",
        )?;
        let rows = stmt.query_map(rusqlite::params![covers], |r| {
            let role_s: String = r.get(2)?;
            let role = match role_s.as_str() {
                "user" => Role::User,
                "assistant" => Role::Assistant,
                _ => Role::User,
            };
            Ok(TurnRecord { id: r.get(0)?, ts: r.get(1)?, role, content: r.get(3)? })
        })?;
        let new_turns: Vec<TurnRecord> = rows.collect::<rusqlite::Result<_>>()?;
        let latest = new_turns.last().map(|t| t.id).unwrap_or(covers);
        Ok(SummarySnapshot {
            prev_events: self.summary.as_ref().map(|s| s.events.clone()),
            prev_character: self.summary.as_ref().map(|s| s.character.clone()),
            covers_up_to_turn_id: latest,
            new_turns,
        })
    }

    pub fn commit_summary(&mut self, events: String, character: String, covers_up_to_turn_id: i64) -> Result<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.db.execute(
            "INSERT INTO summary (id, events, character, covers_up_to_turn_id, updated_ts)
             VALUES (1, ?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
                events = excluded.events,
                character = excluded.character,
                covers_up_to_turn_id = excluded.covers_up_to_turn_id,
                updated_ts = excluded.updated_ts",
            rusqlite::params![events, character, covers_up_to_turn_id, now],
        )?;
        self.summary = Some(Summary {
            events,
            character,
            covers_up_to_turn_id,
            updated_ts: now,
        });
        Ok(())
    }
```

And add the snapshot type at top of file:

```rust
#[derive(Debug, Clone)]
pub struct SummarySnapshot {
    pub prev_events: Option<String>,
    pub prev_character: Option<String>,
    pub covers_up_to_turn_id: i64,
    pub new_turns: Vec<TurnRecord>,
}
```

- [ ] **Step 4: Verify tests pass**

Run: `cargo test -p littlelove-bot --lib memory::`
Expected: PASS for the four new tests; earlier tests still green.

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): needs_summary, snapshot_for_summary, commit_summary"
```

---

## Task 7: Refactor `LlmClient::chat` to take `&[ChatMessage]`

**Files:**
- Modify: `bot/src/llm.rs`
- Modify: `bot/tests/llm_mock.rs`

- [ ] **Step 1: Refactor llm.rs**

Replace the body of `llm.rs` with the version below. Key changes: `ChatMessage` is now `pub`; `chat` takes `&[ChatMessage]`; `LlmRequest` and the `&History` dependency are removed.

```rust
//! OpenAI-compatible chat-completions client. Talks only to private IPs.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

use crate::addr_guard::ensure_url_is_private;

#[derive(Debug, Clone, Serialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

pub struct LlmClient {
    base_url: String,
    model: String,
    temperature: f32,
    max_tokens: u32,
    http: reqwest::Client,
}

#[derive(Serialize)]
struct ChatBody<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    stream: bool,
    temperature: f32,
    max_tokens: u32,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

impl LlmClient {
    pub fn new(
        base_url: &str,
        model: &str,
        temperature: f32,
        max_tokens: u32,
        timeout: Duration,
    ) -> Result<Self> {
        ensure_url_is_private(base_url)
            .with_context(|| format!("refusing LLM endpoint {base_url}"))?;
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .context("reqwest client")?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            model: model.to_string(),
            temperature,
            max_tokens,
            http,
        })
    }

    pub async fn chat(&self, messages: &[ChatMessage]) -> Result<String> {
        ensure_url_is_private(&self.base_url)
            .with_context(|| format!("LLM endpoint flipped to non-private: {}", self.base_url))?;
        let body = ChatBody {
            model: &self.model,
            messages,
            stream: false,
            temperature: self.temperature,
            max_tokens: self.max_tokens,
        };
        let url = format!("{}/chat/completions", self.base_url);
        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("LLM {status}: {text}"));
        }
        let body: ChatResponse = resp.json().await.context("decode chat response")?;
        let choice = body
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("LLM returned no choices"))?;
        Ok(choice.message.content)
    }
}
```

- [ ] **Step 2: Update llm_mock.rs to match**

Open `bot/tests/llm_mock.rs` and adapt the existing test to construct `Vec<ChatMessage>` and call `chat(&messages)`. (If the test used `LlmRequest`, replace the construction with explicit `ChatMessage` values for system/user.)

- [ ] **Step 3: Make the workspace compile**

`run.rs` still calls the old API and won't build yet — that's expected, Task 11 rewires it. To keep the tree compilable during the intermediate tasks, temporarily build only the lib + tests we've touched:

Run: `cargo build -p littlelove-bot --lib`
Expected: FAIL — `run.rs` references removed `LlmRequest`. **This is expected.** Mark `run.rs` as `#[allow(dead_code, unused_imports)]` is not enough; instead, temporarily stub the calls so the lib builds. Edit `bot/src/run.rs` and:

- Replace `use crate::llm::{LlmClient, LlmRequest};` with `use crate::llm::{ChatMessage, LlmClient};`.
- Replace the `llm.chat(&LlmRequest { ... }).await` block with a one-line placeholder that builds a `Vec<ChatMessage>` from `history` and calls `llm.chat(&msgs).await`. Keep it simple — Task 11 rewrites this whole region anyway:

```rust
let mut msgs: Vec<ChatMessage> = vec![ChatMessage {
    role: "system".into(),
    content: system_prompt.clone(),
}];
for t in history.iter() {
    msgs.push(ChatMessage {
        role: match t.role {
            Role::User => "user".into(),
            Role::Assistant => "assistant".into(),
        },
        content: t.content.clone(),
    });
}
msgs.push(ChatMessage { role: "user".into(), content: text.clone() });
let reply_text = match llm.chat(&msgs).await {
    Ok(r) => r,
    Err(e) => { tracing::error!("LLM error: {e}"); format!("[llm error: {e}]") }
};
```

Run: `cargo build -p littlelove-bot`
Expected: PASS.

- [ ] **Step 4: Run the full test suite to confirm nothing else broke**

Run: `cargo test -p littlelove-bot`
Expected: PASS for all existing tests including `llm_mock`.

- [ ] **Step 5: Commit**

```bash
git add bot/src/llm.rs bot/src/run.rs bot/tests/llm_mock.rs
git commit -m "refactor(bot): LlmClient::chat takes &[ChatMessage] directly"
```

---

## Task 8: `assemble_prompt` — happy path

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Write failing test**

Append to `mod tests`:

```rust
    #[test]
    fn assemble_prompt_empty_memory_returns_system_plus_latest_user() {
        let dir = tempdir().unwrap();
        let m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let msgs = m
            .assemble_prompt("PERSONA", "alice", "hello bot", 20, 28_000)
            .unwrap();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "system");
        assert!(msgs[0].content.starts_with("PERSONA"));
        assert!(msgs[0].content.contains("(none yet)"));
        assert!(msgs[0].content.contains("(early days — no summary yet)"));
        assert!(msgs[0].content.contains("(no reflections yet)"));
        assert_eq!(msgs[1].role, "user");
        assert_eq!(msgs[1].content, "hello bot");
    }
```

- [ ] **Step 2: Verify it fails**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt_empty`
Expected: FAIL (method not defined).

- [ ] **Step 3: Implement minimal version**

Add to `impl Memory`:

```rust
    pub fn assemble_prompt(
        &self,
        persona: &str,
        _peer_name: &str,
        latest_user_msg: &str,
        recent_n: usize,
        max_chars: usize,
    ) -> Result<Vec<crate::llm::ChatMessage>> {
        use crate::llm::ChatMessage;

        let facts = read_facts(&self.facts_path).unwrap_or_default();
        let facts_section = if facts.trim().is_empty() {
            "(none yet)".to_string()
        } else {
            facts
        };
        let (events_section, character_section) = match &self.summary {
            Some(s) => (s.events.clone(), s.character.clone()),
            None => (
                "(early days — no summary yet)".to_string(),
                "(no reflections yet)".to_string(),
            ),
        };
        let system_content = format!(
            "{persona}\n\n# What you know about your partner\n{facts_section}\n\n# Recent context\n{events_section}\n\n# How you've been feeling\n{character_section}"
        );

        let recent = self.recent_turns(recent_n)?;
        let mut msgs: Vec<ChatMessage> = Vec::with_capacity(recent.len() + 2);
        msgs.push(ChatMessage { role: "system".into(), content: system_content });
        for t in &recent {
            msgs.push(ChatMessage {
                role: t.role.as_str().into(),
                content: t.content.clone(),
            });
        }
        msgs.push(ChatMessage { role: "user".into(), content: latest_user_msg.to_string() });

        // Budget enforcement comes in Task 9. For now allow oversize.
        let _ = max_chars;
        Ok(msgs)
    }
```

Helpers near the bottom of the file:

```rust
fn read_facts(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}
```

- [ ] **Step 4: Verify test passes**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt_empty`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): assemble_prompt happy path (system + recent + latest)"
```

---

## Task 9: `assemble_prompt` — facts.md, summary, recent_n cap

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Add failing tests**

Append to `mod tests`:

```rust
    #[test]
    fn assemble_prompt_uses_facts_md_when_present() {
        let dir = tempdir().unwrap();
        let m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let room_dir = dir.path().join("rooms").join("01TESTROOM");
        std::fs::write(room_dir.join("facts.md"), "- alice's cat is Mittens").unwrap();
        // Re-open so facts_path read is fresh; the in-memory facts are read every assemble.
        let msgs = m.assemble_prompt("P", "alice", "hi", 10, 28_000).unwrap();
        assert!(msgs[0].content.contains("alice's cat is Mittens"));
    }

    #[test]
    fn assemble_prompt_uses_summary_when_present() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        m.record_turn(Role::User, "u1").unwrap();
        m.commit_summary("e1".into(), "c1".into(), m.latest_turn_id().unwrap()).unwrap();
        let msgs = m.assemble_prompt("P", "alice", "hi", 10, 28_000).unwrap();
        assert!(msgs[0].content.contains("e1"));
        assert!(msgs[0].content.contains("c1"));
        assert!(!msgs[0].content.contains("(early days"));
    }

    #[test]
    fn assemble_prompt_caps_recent_turns_at_recent_n() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        for i in 0..10 {
            m.record_turn(Role::User, &format!("u{i}")).unwrap();
        }
        let msgs = m.assemble_prompt("P", "alice", "latest", 3, 28_000).unwrap();
        // 1 system + 3 recent + 1 latest = 5
        assert_eq!(msgs.len(), 5);
        // The 3 recent are the LAST three (u7, u8, u9).
        assert_eq!(msgs[1].content, "u7");
        assert_eq!(msgs[2].content, "u8");
        assert_eq!(msgs[3].content, "u9");
    }
```

- [ ] **Step 2: Verify they fail**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt`
Expected: The `uses_facts_md` test FAILS (the existing implementation reads facts at open time, not at assemble time — but the way `read_facts` is currently called, it reads at every assemble. Actually it already works.) Re-check: the `read_facts` helper called inside `assemble_prompt` reads at every call — so this test should PASS already. The `caps_recent_turns` test should also PASS — already covered by the LIMIT in `recent_turns`. The `uses_summary` test should also PASS. **If all three already pass, skip to Step 4.**

- [ ] **Step 3: Adjust implementation only if needed**

If any test fails after Step 2, address it minimally. Otherwise no code change.

- [ ] **Step 4: Verify tests pass**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt`
Expected: PASS.

- [ ] **Step 5: Commit (if any code changed)**

```bash
git add bot/src/memory.rs
git commit -m "test(bot): assemble_prompt — facts.md, summary, recent cap"
```

If no code changed, commit just the new tests:

```bash
git add bot/src/memory.rs
git commit -m "test(bot): cover facts.md/summary/recent-cap behavior in assemble_prompt"
```

---

## Task 10: `assemble_prompt` — char budget drop-order

**Files:**
- Modify: `bot/src/memory.rs`

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
    #[test]
    fn assemble_prompt_drops_oldest_turns_when_over_budget() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        for i in 0..6 {
            m.record_turn(Role::User, &"x".repeat(200)).unwrap();
            let _ = i;
        }
        // Budget tight enough to drop ~half the turns.
        let msgs = m.assemble_prompt("PERSONA", "alice", "the last message", 100, 1500).unwrap();
        // System + (some turns) + 1 latest.
        let total_chars: usize = msgs.iter().map(|m| m.content.len()).sum();
        assert!(total_chars <= 1500, "got {total_chars}");
        // The final user message survives intact:
        assert_eq!(msgs.last().unwrap().content, "the last message");
    }

    #[test]
    fn assemble_prompt_never_drops_final_user_message() {
        let dir = tempdir().unwrap();
        let m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let huge = "z".repeat(500);
        // Very tight budget — system+latest can't fit, but final must survive.
        let msgs = m.assemble_prompt(&"P".repeat(5000), "alice", &huge, 100, 200).unwrap();
        assert_eq!(msgs.last().unwrap().content, huge);
    }

    #[test]
    fn assemble_prompt_truncates_summary_events_then_character_then_persona() {
        let dir = tempdir().unwrap();
        let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
        m.record_turn(Role::User, "u").unwrap();
        m.commit_summary("E".repeat(2000), "C".repeat(1000), m.latest_turn_id().unwrap())
            .unwrap();
        // Budget that forces summary truncation but NOT persona truncation.
        let msgs = m.assemble_prompt("PERSONA", "alice", "hi", 1, 800).unwrap();
        let sys = &msgs[0].content;
        assert!(sys.contains("PERSONA"));
        // events should be shorter than the original 2000 chars.
        let total: usize = msgs.iter().map(|m| m.content.len()).sum();
        assert!(total <= 800, "got {total}");
    }
```

- [ ] **Step 2: Verify they fail**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt_drops memory::tests::assemble_prompt_never memory::tests::assemble_prompt_truncates`
Expected: FAIL.

- [ ] **Step 3: Implement budget enforcement**

In `Memory::assemble_prompt`, replace the trailing `let _ = max_chars; Ok(msgs)` with a call to a private `enforce_budget` helper. Add the helper at the bottom of the file:

```rust
fn enforce_budget(
    persona: &str,
    facts: &str,
    events: &str,
    character: &str,
    recent: &[crate::memory::TurnRecord],
    latest_user_msg: &str,
    max_chars: usize,
) -> Vec<crate::llm::ChatMessage> {
    use crate::llm::ChatMessage;

    let mut events_buf = events.to_string();
    let mut character_buf = character.to_string();
    let mut persona_buf = persona.to_string();
    let mut turns: Vec<&TurnRecord> = recent.iter().collect();

    let build_system = |persona: &str, facts: &str, events: &str, character: &str| -> String {
        format!(
            "{persona}\n\n# What you know about your partner\n{facts}\n\n# Recent context\n{events}\n\n# How you've been feeling\n{character}"
        )
    };
    let total_len = |system: &str, turns: &[&TurnRecord], latest: &str| -> usize {
        system.len() + turns.iter().map(|t| t.content.len()).sum::<usize>() + latest.len()
    };

    let mut system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    // 1) drop oldest turns
    while total_len(&system, &turns, latest_user_msg) > max_chars && !turns.is_empty() {
        turns.remove(0);
    }
    // 2) truncate events in 25% suffix-trim increments
    let orig_events_len = events_buf.len();
    while total_len(&system, &turns, latest_user_msg) > max_chars && events_buf.len() > orig_events_len / 4 {
        let cut = (events_buf.len() * 3) / 4;
        events_buf.truncate(cut);
        system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    }
    if total_len(&system, &turns, latest_user_msg) > max_chars && !events_buf.is_empty() {
        events_buf.clear();
        system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    }
    // 3) truncate character similarly
    let orig_char_len = character_buf.len();
    while total_len(&system, &turns, latest_user_msg) > max_chars && character_buf.len() > orig_char_len / 4 {
        let cut = (character_buf.len() * 3) / 4;
        character_buf.truncate(cut);
        system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    }
    if total_len(&system, &turns, latest_user_msg) > max_chars && !character_buf.is_empty() {
        character_buf.clear();
        system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    }
    // 4) truncate persona last (warn loudly)
    if total_len(&system, &turns, latest_user_msg) > max_chars && !persona_buf.is_empty() {
        let overflow = total_len(&system, &turns, latest_user_msg).saturating_sub(max_chars);
        let new_len = persona_buf.len().saturating_sub(overflow);
        persona_buf.truncate(new_len);
        tracing::warn!(
            "persona truncated from {} to {} chars to fit budget — character may break",
            persona.len(),
            persona_buf.len()
        );
        system = build_system(&persona_buf, facts, &events_buf, &character_buf);
    }

    let mut msgs: Vec<ChatMessage> = Vec::with_capacity(turns.len() + 2);
    msgs.push(ChatMessage { role: "system".into(), content: system });
    for t in &turns {
        msgs.push(ChatMessage {
            role: t.role.as_str().into(),
            content: t.content.clone(),
        });
    }
    msgs.push(ChatMessage { role: "user".into(), content: latest_user_msg.to_string() });
    msgs
}
```

Rewire `Memory::assemble_prompt` so that after computing `facts_section`, `events_section`, `character_section`, and `recent`, it returns:

```rust
Ok(enforce_budget(persona, &facts_section, &events_section, &character_section, &recent, latest_user_msg, max_chars))
```

- [ ] **Step 4: Verify tests pass**

Run: `cargo test -p littlelove-bot --lib memory::tests::assemble_prompt`
Expected: All assemble_prompt tests PASS.

- [ ] **Step 5: Commit**

```bash
git add bot/src/memory.rs
git commit -m "feat(bot): assemble_prompt char-budget drop order (turns → events → character → persona)"
```

---

## Task 11: `summary_task` module — message builder + run_summary_refresh

**Files:**
- Create: `bot/src/summary_task.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Write failing test**

Create `bot/src/summary_task.rs` with this skeleton plus its test:

```rust
//! Background summary refresh: snapshot under lock, call LLM, commit under lock.
//!
//! See docs/superpowers/specs/2026-06-10-bot-memory-design.md §6.

use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::sync::Mutex;

use crate::llm::{ChatMessage, LlmClient};
use crate::memory::{parse_summary_response, Memory, Role, SummarySnapshot, TurnRecord};

/// Build the EVENTS:/CHARACTER: prompt described in spec §6.
pub fn build_summary_messages(
    snap: &SummarySnapshot,
    character_name: &str,
    peer_name: &str,
) -> Vec<ChatMessage> {
    let prev_events = snap
        .prev_events
        .clone()
        .unwrap_or_else(|| "(none — first summary)".to_string());
    let prev_character = snap
        .prev_character
        .clone()
        .unwrap_or_else(|| "(none — first summary)".to_string());
    let mut new_turns = String::new();
    for t in &snap.new_turns {
        let tag = match t.role {
            Role::User => "[user]",
            Role::Assistant => "[assistant]",
        };
        new_turns.push_str(&format!("{tag} {}\n", t.content));
    }
    let last_id = snap.new_turns.last().map(|t| t.id).unwrap_or(snap.covers_up_to_turn_id);
    let first_new_id = snap.new_turns.first().map(|t| t.id).unwrap_or(snap.covers_up_to_turn_id + 1);
    let covers_to = snap.covers_up_to_turn_id;

    let user_content = format!(
"You are summarizing a conversation between {character_name} and {peer_name}.

Previous summary (covers turns 1..{covers_to}):
EVENTS:
{prev_events}

CHARACTER:
{prev_character}

New turns to incorporate ({first_new_id}..{last_id}):
{new_turns}
Produce an updated summary as exactly two sections.

EVENTS:
Compressed \"what happened\" narrative — combine previous events with the new turns.
Keep names, decisions, places, emotional beats. Drop trivia. Max 400 words.

CHARACTER:
Speaking as {character_name}, write a brief first-person reflection — how you've been
feeling, what you've learned about {peer_name}, what feels significant. Max 200 words.

Reply with EVENTS: followed by the events text, then CHARACTER: on a new line followed
by the character text. Nothing else.");

    vec![ChatMessage {
        role: "user".into(),
        content: user_content,
    }]
}

/// Snapshot under lock → LLM call (no lock) → commit under lock. Never blocks the reply loop.
pub async fn run_summary_refresh(
    memory: Arc<Mutex<Memory>>,
    llm: Arc<LlmClient>,
    character_name: String,
    peer_name: String,
) -> Result<()> {
    let snap = {
        let m = memory.lock().await;
        m.snapshot_for_summary().context("snapshot_for_summary")?
    };
    if snap.new_turns.is_empty() {
        return Ok(());
    }
    let msgs = build_summary_messages(&snap, &character_name, &peer_name);
    let raw = llm.chat(&msgs).await.context("LLM summary call")?;
    let (events, character) = parse_summary_response(&raw).context("parse summary")?;
    let mut m = memory.lock().await;
    m.commit_summary(events, character, snap.covers_up_to_turn_id)
        .context("commit_summary")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::SummarySnapshot;

    #[test]
    fn build_summary_messages_includes_prev_summary_and_new_turns() {
        let snap = SummarySnapshot {
            prev_events: Some("did A".into()),
            prev_character: Some("felt warm".into()),
            covers_up_to_turn_id: 3,
            new_turns: vec![
                TurnRecord { id: 4, ts: 0, role: Role::User, content: "hi".into() },
                TurnRecord { id: 5, ts: 0, role: Role::Assistant, content: "hey".into() },
            ],
        };
        let msgs = build_summary_messages(&snap, "Nova", "alice");
        assert_eq!(msgs.len(), 1);
        let c = &msgs[0].content;
        assert!(c.contains("Nova"));
        assert!(c.contains("alice"));
        assert!(c.contains("did A"));
        assert!(c.contains("felt warm"));
        assert!(c.contains("[user] hi"));
        assert!(c.contains("[assistant] hey"));
        assert!(c.contains("4..5"));
        assert!(c.contains("1..3"));
    }

    #[test]
    fn build_summary_messages_handles_empty_prev_summary() {
        let snap = SummarySnapshot {
            prev_events: None,
            prev_character: None,
            covers_up_to_turn_id: 0,
            new_turns: vec![
                TurnRecord { id: 1, ts: 0, role: Role::User, content: "hello".into() },
            ],
        };
        let msgs = build_summary_messages(&snap, "Nova", "alice");
        assert!(msgs[0].content.contains("(none — first summary)"));
    }
}
```

Register the module in `bot/src/lib.rs`:

```rust
pub mod summary_task;
```

- [ ] **Step 2: Verify tests fail then pass**

Run: `cargo test -p littlelove-bot --lib summary_task::tests`
Expected: PASS (the test compiles against the new module and passes immediately — implementation is intentionally complete in this task because it's mostly string templating).

- [ ] **Step 3: Add an integration test using a mock LLM**

Create `bot/tests/memory_smoke.rs`:

```rust
//! End-to-end smoke for the memory + summary refresh loop with a mocked LLM.

use std::sync::Arc;
use std::time::Duration;

use axum::{routing::post, Json, Router};
use serde_json::json;
use tempfile::tempdir;
use tokio::sync::Mutex;

use littlelove_bot::llm::LlmClient;
use littlelove_bot::memory::{Memory, Role};
use littlelove_bot::summary_task::run_summary_refresh;

#[tokio::test]
async fn summary_refresh_writes_row_against_mock_llm() {
    // 1. Start a fake OpenAI server.
    let canned = "EVENTS:\nThey said hi several times.\nCHARACTER:\nI feel curious.";
    let app = Router::new().route(
        "/v1/chat/completions",
        post(move |Json(_): Json<serde_json::Value>| async move {
            Json(json!({"choices":[{"message":{"content": canned}}]}))
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    // 2. Open memory and record a handful of turns.
    let dir = tempdir().unwrap();
    let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
    for i in 0..5 {
        m.record_turn(Role::User, &format!("u{i}")).unwrap();
        m.record_turn(Role::Assistant, &format!("a{i}")).unwrap();
    }
    let mem = Arc::new(Mutex::new(m));

    // 3. Refresh.
    let llm = Arc::new(
        LlmClient::new(
            &format!("http://{addr}/v1"),
            "test",
            0.8,
            512,
            Duration::from_secs(5),
        )
        .unwrap(),
    );
    run_summary_refresh(mem.clone(), llm, "Nova".into(), "alice".into())
        .await
        .unwrap();

    // 4. Assert the summary row is populated and matches.
    let m = mem.lock().await;
    let s = m.summary().expect("summary populated");
    assert_eq!(s.events.trim(), "They said hi several times.");
    assert_eq!(s.character.trim(), "I feel curious.");
}
```

- [ ] **Step 4: Run the integration test**

Run: `cargo test -p littlelove-bot --test memory_smoke`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bot/src/summary_task.rs bot/src/lib.rs bot/tests/memory_smoke.rs
git commit -m "feat(bot): summary_task module + mocked-LLM integration test"
```

---

## Task 12: CLI flags + Doctor subcommand

**Files:**
- Modify: `bot/src/cli.rs`
- Modify: `bot/src/main.rs`
- Create: `bot/src/doctor.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Extend RunArgs and add Doctor**

In `bot/src/cli.rs`:

```rust
// In RunArgs, add three fields:

    #[arg(long, env = "LITTLELOVE_BOT_MEMORY_DIR")]
    pub memory_dir: Option<std::path::PathBuf>,

    #[arg(long, env = "LITTLELOVE_BOT_SUMMARY_EVERY", default_value_t = 20)]
    pub summary_every: usize,

    #[arg(long, env = "LITTLELOVE_BOT_MAX_CONTEXT_CHARS", default_value_t = 28_000)]
    pub max_context_chars: usize,
```

Update the `--history` field doc-comment:

```rust
    /// Max recent raw turns to inject into the prompt (oldest dropped first).
    #[arg(long, env = "LITTLELOVE_BOT_HISTORY", default_value_t = 20)]
    pub history: usize,
```

Add the Doctor subcommand:

```rust
#[derive(Subcommand, Debug)]
pub enum Command {
    Pair(PairArgs),
    Run(RunArgs),
    ShowIdentity,
    /// Inspect the bot's identity + per-room memory state without writing.
    Doctor(DoctorArgs),
}

#[derive(clap::Args, Debug)]
pub struct DoctorArgs {
    #[arg(long, env = "LITTLELOVE_BOT_MEMORY_DIR")]
    pub memory_dir: Option<std::path::PathBuf>,
}
```

- [ ] **Step 2: Create the doctor module skeleton**

`bot/src/doctor.rs`:

```rust
//! `doctor` subcommand: read-only health report on identity + per-room memory.

use std::path::Path;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use rusqlite::Connection;

use crate::cli::DoctorArgs;
use crate::identity_store::{default_identity_path, load_identity};
use crate::memory::SCHEMA_VERSION;

pub fn run(args: DoctorArgs) -> Result<()> {
    let id_path = default_identity_path();
    let memory_dir = args
        .memory_dir
        .clone()
        .unwrap_or_else(|| id_path.parent().unwrap().to_path_buf());

    println!("memory directory: {}", memory_dir.display());

    match load_identity(&id_path) {
        Ok(f) => println!("identity:         present (@{})", f.username),
        Err(e) => {
            println!("identity:         MISSING ({e})");
            std::process::exit(2);
        }
    }

    let rooms_dir = memory_dir.join("rooms");
    if !rooms_dir.exists() {
        println!("rooms:            (none — bot has not run yet)");
        return Ok(());
    }
    println!("rooms:");
    let mut any_error = false;
    for entry in std::fs::read_dir(&rooms_dir).with_context(|| format!("read {}", rooms_dir.display()))? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let room_id = entry.file_name().to_string_lossy().to_string();
        println!("  {room_id}");
        if let Err(e) = report_room(&entry.path()) {
            println!("    ERROR: {e}");
            any_error = true;
        }
    }
    if any_error {
        std::process::exit(2);
    }
    Ok(())
}

fn report_room(room_dir: &Path) -> Result<()> {
    use anyhow::anyhow;
    let db_path = room_dir.join("memory.sqlite");
    if !db_path.exists() {
        return Err(anyhow!("missing memory.sqlite"));
    }
    let conn = Connection::open(&db_path)?;
    let v: u32 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    let marker = if v == SCHEMA_VERSION { "✓" } else { "MISMATCH" };
    println!("    memory.sqlite:    schema version {v} ({marker})");
    if v != SCHEMA_VERSION {
        return Err(anyhow!(
            "schema version {v} != expected {SCHEMA_VERSION}; upgrade the bot or point --memory-dir at a fresh path"
        ));
    }
    let turn_count: i64 = conn.query_row("SELECT COUNT(*) FROM turn", [], |r| r.get(0))?;
    if turn_count == 0 {
        println!("    turns:            0");
    } else {
        let oldest: i64 = conn.query_row("SELECT MIN(ts) FROM turn", [], |r| r.get(0))?;
        let newest: i64 = conn.query_row("SELECT MAX(ts) FROM turn", [], |r| r.get(0))?;
        println!(
            "    turns:            {turn_count} (oldest: {}, newest: {})",
            fmt_ts(oldest),
            fmt_ts(newest)
        );
    }
    let summary: Option<(i64, i64)> = conn
        .query_row(
            "SELECT covers_up_to_turn_id, updated_ts FROM summary WHERE id = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .ok();
    match summary {
        Some((covers, updated)) => println!(
            "    summary:          present, covers up to turn {covers}, updated {}",
            fmt_ts(updated)
        ),
        None => println!("    summary:          (none yet)"),
    }
    let facts_path = room_dir.join("facts.md");
    match std::fs::metadata(&facts_path) {
        Ok(md) => println!("    facts.md:         present, {} bytes", md.len()),
        Err(_) => println!("    facts.md:         (absent — create it to add user facts)"),
    }
    Ok(())
}

fn fmt_ts(unix_secs: i64) -> String {
    DateTime::<Utc>::from_timestamp(unix_secs, 0)
        .map(|d| d.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|| format!("{unix_secs}"))
}
```

Add `pub mod doctor;` to `bot/src/lib.rs`. Update `main.rs`:

```rust
        cli::Command::Doctor(args) => littlelove_bot::doctor::run(args),
```

- [ ] **Step 3: Verify the binary builds and `--help` shows the new flags**

Run: `cargo build -p littlelove-bot && cargo run -p littlelove-bot -- run --help`
Expected: PASS; help text shows `--memory-dir`, `--summary-every`, `--max-context-chars`.

Run: `cargo run -p littlelove-bot -- doctor --help`
Expected: PASS; help shows `doctor [--memory-dir <PATH>]`.

- [ ] **Step 4: Commit**

```bash
git add bot/src/cli.rs bot/src/main.rs bot/src/doctor.rs bot/src/lib.rs
git commit -m "feat(bot): add --memory-dir/--summary-every/--max-context-chars + doctor subcommand"
```

---

## Task 13: `doctor` integration tests

**Files:**
- Create: `bot/tests/doctor_smoke.rs`

- [ ] **Step 1: Write failing tests**

```rust
//! Integration tests for the `doctor` subcommand.

use std::process::Command;

use rusqlite::Connection;
use tempfile::tempdir;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_littlelove-bot")
}

#[test]
fn doctor_reports_missing_rooms_directory() {
    let dir = tempdir().unwrap();
    let out = Command::new(bin())
        .args(["doctor", "--memory-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    // identity is also absent here — should exit 2 with helpful text.
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("memory directory"));
    assert!(!out.status.success(), "doctor should exit non-zero when identity is absent");
}

#[test]
fn doctor_reports_v99_schema_mismatch() {
    let dir = tempdir().unwrap();
    let room_dir = dir.path().join("rooms").join("01TESTROOM");
    std::fs::create_dir_all(&room_dir).unwrap();
    let db_path = room_dir.join("memory.sqlite");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "user_version", 99u32).unwrap();
    drop(conn);

    let out = Command::new(bin())
        .args(["doctor", "--memory-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("schema version 99"), "stdout: {stdout}");
    assert!(stdout.contains("MISMATCH"), "stdout: {stdout}");
    assert!(!out.status.success());
}
```

- [ ] **Step 2: Run them**

Run: `cargo test -p littlelove-bot --test doctor_smoke`
Expected: PASS.

(Both tests use `--memory-dir` to isolate from any real `~/Library/...` state, but identity always lives at `default_identity_path()`. If the dev machine has a real `identity.json`, the first test will still pass because we still expect non-zero exit only when rooms are missing AND identity is fine. Re-check by reading the test: it asserts non-zero exit, which holds if identity is absent OR rooms-dir is absent and any room has an issue. On the dev machine where identity is present, the first test's stdout will show `rooms: (none — bot has not run yet)` and exit 0 — which would FAIL the assertion. Fix: relax the first test to only check stdout content, not exit code, OR set HOME to the tempdir so `default_identity_path()` doesn't find the real identity.)

Adjust the first test to set `HOME` (and on macOS, `XDG_CONFIG_HOME` is irrelevant — `directories` uses `~/Library/Application Support` directly). The robust fix:

```rust
    let out = Command::new(bin())
        .env("HOME", dir.path())          // unix
        .env("USERPROFILE", dir.path())   // windows
        .env("APPDATA", dir.path().join("AppData/Roaming"))
        .args(["doctor", "--memory-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
```

Re-run and confirm PASS.

- [ ] **Step 3: Commit**

```bash
git add bot/tests/doctor_smoke.rs
git commit -m "test(bot): doctor integration — missing rooms + v=99 mismatch"
```

---

## Task 14: Wire `Memory` into `run.rs`

**Files:**
- Modify: `bot/src/run.rs`
- Modify: `bot/src/lib.rs` (remove `pub mod history;`)
- Delete: `bot/src/history.rs`

- [ ] **Step 1: Rewrite the run loop**

In `bot/src/run.rs`, replace the imports and the inbound-handling region. The full revised file should look approximately like this (sections you do not modify are elided for brevity — keep them as-is):

```rust
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use tokio::sync::Mutex;

use crate::cli::RunArgs;
use crate::identity_store::{default_identity_path, load_identity};
use crate::llm::LlmClient;
use crate::memory::{Memory, Role};
use crate::persona::{resolve, PersonaSources};
use crate::summary_task::run_summary_refresh;
use crate::ws_client::{
    connect_and_identify, next_inbound, send_message, subscribe, ClientIdentity, Inbound,
};
use littlelove_crypto::{aead, ecdh};

pub async fn run(args: RunArgs) -> Result<()> {
    // ... identity / persona / llm setup unchanged through `let llm = LlmClient::new(...)?;`

    let llm = Arc::new(llm);

    // ws / room setup unchanged through `subscribe(&mut session, &room.room_id).await?;`

    let memory_dir = args
        .memory_dir
        .clone()
        .unwrap_or_else(|| default_identity_path().parent().unwrap().to_path_buf());
    let memory = Arc::new(Mutex::new(
        Memory::open(&memory_dir, &room.room_id)
            .with_context(|| format!("open memory at {}", memory_dir.display()))?,
    ));

    // Startup-sync summary if there are turns but no summary row.
    {
        let needs = {
            let m = memory.lock().await;
            m.summary().is_none() && m.latest_turn_id()? > 0
        };
        if needs {
            tracing::info!("first run with existing turns and no summary — running synchronous catch-up summary");
            if let Err(e) = run_summary_refresh(
                memory.clone(),
                llm.clone(),
                args.character_name().unwrap_or("bot").to_string(),
                room.peer_username.clone(),
            )
            .await
            {
                tracing::warn!("startup summary failed: {e}");
            }
        }
    }

    while let Some(inbound) = next_inbound(&mut session).await? {
        match inbound {
            Inbound::Message { from, body, replayed, .. } if from != file.username => {
                let plain = match aead::decrypt_wire(&room_key, &body) {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::warn!("decrypt failed for inbound frame from {from}: {e}");
                        continue;
                    }
                };
                let text = String::from_utf8_lossy(&plain).into_owned();
                {
                    let mut m = memory.lock().await;
                    m.record_turn(Role::User, &text)?;
                }
                if replayed {
                    continue;
                }
                let msgs = {
                    let m = memory.lock().await;
                    m.assemble_prompt(
                        &system_prompt,
                        &room.peer_username,
                        &text,
                        args.history,
                        args.max_context_chars,
                    )?
                };
                let reply_text = match llm.chat(&msgs).await {
                    Ok(r) => r,
                    Err(e) => {
                        tracing::error!("LLM error: {e}");
                        format!("[llm error: {e}]")
                    }
                };
                {
                    let mut m = memory.lock().await;
                    m.record_turn(Role::Assistant, &reply_text)?;
                }
                let wire = aead::encrypt_wire(&room_key, reply_text.as_bytes())?;
                send_message(&mut session, &room.room_id, &wire).await?;

                // Trigger background summary if threshold crossed.
                let trigger = { memory.lock().await.needs_summary(args.summary_every)? };
                if trigger {
                    let mem_c = memory.clone();
                    let llm_c = llm.clone();
                    let char_name = args.character_name().unwrap_or("bot").to_string();
                    let peer = room.peer_username.clone();
                    tokio::spawn(async move {
                        if let Err(e) = run_summary_refresh(mem_c, llm_c, char_name, peer).await {
                            tracing::warn!("summary refresh failed: {e}");
                        }
                    });
                }
            }
            _ => {}
        }
    }
    Ok(())
}
```

Add a tiny helper on `RunArgs` (in `cli.rs`) so the character name resolves from the same source persona does — keep it simple:

```rust
impl RunArgs {
    /// Best-effort character name for summary prompts. Falls back to None;
    /// callers can default to "bot".
    pub fn character_name(&self) -> Option<&str> {
        // Card / file / env are loaded separately; for v0.3 we don't thread the
        // resolved name through, so this is None — callers default to "bot".
        None
    }
}
```

(A richer character-name extraction is a follow-up; the spec doesn't require it for v0.3 correctness — the summary prompt just substitutes "bot" if no card.)

- [ ] **Step 2: Delete `bot/src/history.rs` and remove from lib.rs**

```bash
rm bot/src/history.rs
```

Edit `bot/src/lib.rs` and delete the line `pub mod history;`.

- [ ] **Step 3: Verify the whole crate builds and tests pass**

Run: `cargo build -p littlelove-bot`
Expected: PASS.

Run: `cargo test -p littlelove-bot`
Expected: PASS for everything (existing + new).

- [ ] **Step 4: Commit**

```bash
git add bot/src/run.rs bot/src/lib.rs bot/src/cli.rs
git rm bot/src/history.rs
git commit -m "feat(bot): wire Memory into run loop, spawn background summary, delete History"
```

---

## Task 15: README updates

**Files:**
- Modify: `bot/README.md`

- [ ] **Step 1: Document the new surface**

Add a "Memory" section to `bot/README.md`:

```markdown
## Memory

The bot stores per-room state on local disk:

```
<memory-dir>/
  identity.json
  rooms/<room_id>/
    memory.sqlite      # turn log + summary (SQLite, WAL)
    facts.md           # hand-edited notes about your partner (you write, the bot reads)
```

`<memory-dir>` defaults to:

- macOS: `~/Library/Application Support/dev.littlelove.littlelove-bot/`
- Linux: `~/.config/littlelove-bot/`
- Windows: `%APPDATA%\littlelove\littlelove-bot\config\`

Override with `--memory-dir <path>` or `LITTLELOVE_BOT_MEMORY_DIR`.

### Knobs

- `--summary-every <N>` (default `20`) — turn-count threshold for the background summary refresh.
- `--max-context-chars <N>` (default `28000`) — char budget for the assembled system prompt + history.
- `--history <N>` (default `20`) — max recent raw turns injected into the prompt.

### Editing facts.md

`facts.md` is yours — the bot reads it on every reply but never writes to it. Open it in any text editor and add what you want the bot to know. Examples:

```markdown
# About alice
- Allergic to cilantro.
- Lives in Lisbon, originally from Calgary.
- Has two cats: Mittens (calico) and Bandit (tuxedo).

# Tone
- Likes dry humor, hates apologetic pre-ambles.
```

### Deleting memory

For v0.3 there is no `forget` subcommand. To wipe a single conversation:

```bash
sqlite3 ~/Library/Application\ Support/dev.littlelove.littlelove-bot/rooms/<room_id>/memory.sqlite "DELETE FROM turn; DELETE FROM summary;"
```

Or delete the room directory entirely; the bot recreates it on next message.

### Backup / machine migration

The memory directory is just files — `rsync` or copy it. **Bring `identity.json` along** or you'll lose pairing with the LittleLove server.

### Inspecting state

```bash
littlelove-bot doctor
```

Reports schema version, turn count, summary status, and `facts.md` size for each room. Read-only.

### Schema upgrades

`memory.sqlite` carries a `PRAGMA user_version`. On startup, a newer bot copies `memory.sqlite` to `memory.sqlite.bak-v<old>` before applying schema migrations in a transaction. Migrations are additive — no renames, no drops.

If you downgrade the bot, it will refuse to open a newer database and tell you what to do.
```

- [ ] **Step 2: Commit**

```bash
git add bot/README.md
git commit -m "docs(bot): document memory dir, facts.md, doctor, backup story"
```

---

## Task 16: Lint + final verification

**Files:** (none — sanity pass)

- [ ] **Step 1: Run clippy**

Run: `cargo clippy -p littlelove-bot --all-targets -- -D warnings`
Expected: PASS. Fix any warnings introduced by this work (unused imports left from the `history` removal are the most likely).

- [ ] **Step 2: Run the full test suite one last time**

Run: `cargo test -p littlelove-bot`
Expected: PASS.

- [ ] **Step 3: Confirm the binary's --help output**

Run: `cargo run -p littlelove-bot -- --help`
Expected: lists `pair`, `run`, `show-identity`, `doctor`.

- [ ] **Step 4: Commit (if anything changed)**

```bash
git add -A
git commit -m "chore(bot): clippy clean + final memory-feature verification"
```

- [ ] **Step 5: Push branch**

```bash
git push origin feat/bot-memory
```

---

## Task 17: Open PR against `main`

**Files:** (none — PR description only)

- [ ] **Step 1: Create the PR via `gh`**

```bash
gh pr create --base main --title "feat(bot): persistent per-room memory (SQLite + facts.md + async summary)" --draft --body "$(cat <<'EOF'
## Summary
- Replaces in-memory `History` with `bot/src/memory.rs` — per-room SQLite (`<memory-dir>/rooms/<room_id>/memory.sqlite`) + sibling `facts.md`.
- Adds an async background summary loop (`bot/src/summary_task.rs`) gated by `--summary-every`. Never blocks the reply path.
- Adds char-budget prompt assembly with the drop order from the spec (turns → events → character → persona; final user message and facts.md never truncated).
- Adds `doctor` subcommand: read-only health report.
- New flags: `--memory-dir`, `--summary-every`, `--max-context-chars`. `--history` repurposed (semantics in README).
- Schema is versioned via `PRAGMA user_version`; migrations are additive and back up the DB before applying.

## Out of scope (v0.4+)
- Vector RAG / semantic recall (table layout reserved).
- Automatic fact extraction.
- `forget` subcommand.

## Test plan
- [x] `cargo test -p littlelove-bot` — unit + integration suites green.
- [x] `cargo clippy -p littlelove-bot --all-targets -- -D warnings`.
- [ ] **Manual smoke (Court runs before merge):** pair fresh, send ~25 messages, verify summary triggers, restart the bot, send another message, confirm continuity. Edit `facts.md` mid-stream, confirm next reply reflects it. Run `doctor` against the live dir.

## Hard invariants preserved
- No cloud AI: `LlmClient` still goes through `ensure_url_is_private`. Memory work touched no networking code.
- E2EE: memory is written *after* `aead::decrypt_wire`, on the bot's local disk only. Server still sees ciphertext.
- Tests are real: SQLite tests hit `tempfile::tempdir()` DBs; LLM integration test uses a real `axum` mock server, not stubs.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Print PR URL**

Echo the URL `gh pr create` returned so Court can click into it.

**DO NOT MERGE.** Court runs the manual smoke and clicks merge himself.

---

## Self-review notes (post-write)

Coverage check against the spec:

- §3 Architecture — Tasks 3, 11, 14.
- §4 Schema + migrations (additive, backup, refuse-newer) — Task 3.
- §5 Prompt assembly + budget — Tasks 8, 9, 10.
- §6 Summary lifecycle (snapshot/commit split, async, startup-sync) — Tasks 6, 11, 14.
- §7 CLI surface + module layout (with the intentional `summary_task.rs` split documented) — Tasks 7, 12, 14.
- §8 Cross-platform + upgrade — covered by §4 implementation; documented in Task 15.
- §9 Testing strategy — Tasks 3–6, 8–11, 13.
- §10 Dependencies — Task 1.

Deliberately deferred: the spec lists a "migration runs in a transaction" test (§9). Demonstrating mid-migration failure cleanly without a test hook is awkward for the single v0→v1 step we have today; the `BEGIN; … ; COMMIT;` pattern is enforced by code inspection (see Task 3 `migrate_up`). Revisit in v0.4 when the second migration arrives — at that point parameterized tests against a tampered migration become straightforward.
