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
