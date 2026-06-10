use tempfile::TempDir;

use littlelove_bot::identity_store::{load_identity, save_identity, IdentityFile};

#[test]
fn round_trip_writes_and_reads() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");

    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(),
        x25519_pub_b64: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=".into(),
        master_secret_b64: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, /*force=*/ false).expect("save");

    let back = load_identity(&path).expect("load");
    assert_eq!(back.username, "court_familiar");
    assert_eq!(back.master_secret_b64, file.master_secret_b64);
}

#[test]
fn save_refuses_existing_without_force() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");

    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "x".into(),
        x25519_pub_b64: "y".into(),
        master_secret_b64: "z".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, false).unwrap();
    let err = save_identity(&path, &file, false).unwrap_err();
    assert!(format!("{err}").contains("exists"));
}

#[cfg(unix)]
#[test]
fn writes_mode_0600_on_unix() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");
    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "x".into(),
        x25519_pub_b64: "y".into(),
        master_secret_b64: "z".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, false).unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}
