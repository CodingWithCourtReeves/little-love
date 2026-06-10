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
pub struct SummarySnapshot {
    pub prev_events: Option<String>,
    pub prev_character: Option<String>,
    pub covers_up_to_turn_id: i64,
    pub new_turns: Vec<TurnRecord>,
}

#[derive(Debug, Clone)]
pub struct TurnRecord {
    pub id: i64,
    pub ts: i64,
    pub role: Role,
    pub content: String,
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

impl std::fmt::Debug for Memory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Memory")
            .field("facts_path", &self.facts_path)
            .field("summary", &self.summary)
            .field("schema_version", &self.schema_version)
            .finish_non_exhaustive()
    }
}

/// Split a summary LLM response into (events, character).
///
/// Expects line-anchored `EVENTS:` and `CHARACTER:` headers in that order.
pub fn parse_summary_response(raw: &str) -> Result<(String, String)> {
    use anyhow::anyhow;
    use regex::Regex;

    let re = Regex::new(r"(?m)^\s*(EVENTS|CHARACTER):").expect("static regex");
    let mut events: Option<String> = None;
    let mut character: Option<String> = None;

    let mut spans: Vec<(usize, usize, &str)> = Vec::new();
    for m in re.find_iter(raw) {
        let caps = re.captures(&raw[m.start()..m.end()]).unwrap();
        let kind = caps.get(1).unwrap().as_str();
        let kind_static: &str = match kind {
            "EVENTS" => "EVENTS",
            "CHARACTER" => "CHARACTER",
            _ => continue,
        };
        spans.push((m.end(), m.start(), kind_static));
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

    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

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
        out.reverse();
        Ok(out)
    }

    pub fn summary(&self) -> Option<&Summary> {
        self.summary.as_ref()
    }

    pub fn needs_summary(&self, threshold: usize) -> Result<bool> {
        let latest = self.latest_turn_id()?;
        let covers = self
            .summary
            .as_ref()
            .map(|s| s.covers_up_to_turn_id)
            .unwrap_or(0);
        Ok((latest - covers) as usize > threshold)
    }

    pub fn snapshot_for_summary(&self) -> Result<SummarySnapshot> {
        let covers = self
            .summary
            .as_ref()
            .map(|s| s.covers_up_to_turn_id)
            .unwrap_or(0);
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
            Ok(TurnRecord {
                id: r.get(0)?,
                ts: r.get(1)?,
                role,
                content: r.get(3)?,
            })
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
        msgs.push(ChatMessage {
            role: "system".into(),
            content: system_content,
        });
        for t in &recent {
            msgs.push(ChatMessage {
                role: t.role.as_str().into(),
                content: t.content.clone(),
            });
        }
        msgs.push(ChatMessage {
            role: "user".into(),
            content: latest_user_msg.to_string(),
        });

        let _ = max_chars;
        Ok(msgs)
    }

    pub fn commit_summary(
        &mut self,
        events: String,
        character: String,
        covers_up_to_turn_id: i64,
    ) -> Result<()> {
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

fn read_facts(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

#[cfg(unix)]
fn set_dir_perms_0700(p: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_dir_perms_0700(_p: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_file_perms_0600(p: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_file_perms_0600(_p: &Path) -> Result<()> {
    Ok(())
}

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

    #[test]
    fn open_is_idempotent() {
        let dir = tempdir().unwrap();
        let _m1 = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let _m2 = Memory::open(dir.path(), "01TESTROOM").unwrap();
        let room_dir = dir.path().join("rooms").join("01TESTROOM");
        let bak = room_dir.join("memory.sqlite.bak-v0");
        assert!(bak.exists(), "first open should create bak-v0");
        assert!(!room_dir.join("memory.sqlite.bak-v1").exists());
    }

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
        m.commit_summary(
            "prev events".into(),
            "prev character".into(),
            m.latest_turn_id().unwrap(),
        )
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
}
