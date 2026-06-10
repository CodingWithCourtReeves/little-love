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

    let mut any_error = false;
    match load_identity(&id_path) {
        Ok(f) => println!("identity:         present (@{})", f.username),
        Err(e) => {
            println!("identity:         MISSING ({e})");
            any_error = true;
        }
    }

    let rooms_dir = memory_dir.join("rooms");
    if !rooms_dir.exists() {
        println!("rooms:            (none — bot has not run yet)");
        if any_error {
            std::process::exit(2);
        }
        return Ok(());
    }
    println!("rooms:");
    for entry in
        std::fs::read_dir(&rooms_dir).with_context(|| format!("read {}", rooms_dir.display()))?
    {
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
    let marker = if v == SCHEMA_VERSION {
        "✓"
    } else {
        "MISMATCH"
    };
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
