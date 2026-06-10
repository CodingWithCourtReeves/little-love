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
        .env("HOME", dir.path())
        .env("USERPROFILE", dir.path())
        .env("APPDATA", dir.path().join("AppData/Roaming"))
        .args(["doctor", "--memory-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("memory directory"));
    assert!(
        !out.status.success(),
        "doctor should exit non-zero when identity is absent"
    );
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
        .env("HOME", dir.path())
        .env("USERPROFILE", dir.path())
        .env("APPDATA", dir.path().join("AppData/Roaming"))
        .args(["doctor", "--memory-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("schema version 99"), "stdout: {stdout}");
    assert!(stdout.contains("MISMATCH"), "stdout: {stdout}");
    assert!(!out.status.success());
}
