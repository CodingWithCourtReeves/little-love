//! show-identity: pretty-print the local identity file.

use anyhow::{Context, Result};

use crate::identity_store::{default_identity_path, load_identity};

pub fn run() -> Result<()> {
    let path = default_identity_path();
    let file = load_identity(&path).with_context(|| format!("load {path:?}"))?;
    println!("file:          {}", path.display());
    println!("username:      @{}", file.username);
    println!("ed25519_pub:   {}", short(&file.ed25519_pub_b64));
    println!("x25519_pub:    {}", short(&file.x25519_pub_b64));
    println!("created_at:    {}", file.created_at);
    Ok(())
}

fn short(s: &str) -> String {
    if s.len() < 12 {
        s.to_string()
    } else {
        format!("{}…{}", &s[..6], &s[s.len() - 6..])
    }
}
