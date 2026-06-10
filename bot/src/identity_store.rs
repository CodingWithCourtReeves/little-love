//! `identity.json` read/write. Atomic write via tempfile + rename.

use std::fs;
use std::io::Write;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IdentityStoreError {
    #[error("identity file already exists at {0:?} (use --force to overwrite)")]
    Exists(std::path::PathBuf),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityFile {
    pub version: u32,
    pub username: String,
    pub ed25519_pub_b64: String,
    pub x25519_pub_b64: String,
    pub master_secret_b64: String,
    pub created_at: DateTime<Utc>,
}

pub fn load_identity(path: &Path) -> Result<IdentityFile, IdentityStoreError> {
    let bytes = fs::read(path)?;
    let file: IdentityFile = serde_json::from_slice(&bytes)?;
    Ok(file)
}

pub fn save_identity(
    path: &Path,
    file: &IdentityFile,
    force: bool,
) -> Result<(), IdentityStoreError> {
    if path.exists() && !force {
        return Err(IdentityStoreError::Exists(path.to_path_buf()));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o600);
            f.set_permissions(perms)?;
        }
        let bytes = serde_json::to_vec_pretty(file)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Default location, per `directories::ProjectDirs`.
pub fn default_identity_path() -> std::path::PathBuf {
    let proj = directories::ProjectDirs::from("dev", "littlelove", "littlelove-bot")
        .expect("OS provided no config dir");
    proj.config_dir().join("identity.json")
}
