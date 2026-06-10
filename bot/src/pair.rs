//! pair subcommand: signup + identify + ConsumeInvite + persist identity.

use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::Utc;

use crate::cli::PairArgs;
use crate::identity_store::{default_identity_path, save_identity, IdentityFile};
use crate::rest::{signup, SignupRequest};
use crate::ws_client::{connect_and_identify, consume_invite, ClientIdentity};
use littlelove_crypto::identity::{derive_identity, random_seed};

pub async fn run(args: PairArgs) -> Result<()> {
    if args.username.len() < 3
        || args.username.len() > 20
        || !args
            .username
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        anyhow::bail!("--username must match [a-z0-9_]{{3,20}}");
    }

    let path = default_identity_path();
    if path.exists() && !args.force {
        anyhow::bail!(
            "identity file already exists at {path:?} — re-run with --force to overwrite"
        );
    }

    let seed = random_seed();
    let identity = derive_identity(&seed).context("derive identity")?;
    let ed_pub_b64 = B64.encode(identity.ed25519_pub());
    let x_pub_b64 = B64.encode(identity.x25519_pub());

    let rest_base = ws_to_rest_base(&args.server)?;
    signup(
        &rest_base,
        &SignupRequest {
            username: args.username.clone(),
            ed25519_pub_b64: ed_pub_b64.clone(),
            x25519_pub_b64: x_pub_b64.clone(),
        },
    )
    .await
    .context("signup")?;

    let ws_url = format!("{}/ws", args.server.trim_end_matches('/'));
    let mut session = connect_and_identify(
        &ws_url,
        &ClientIdentity {
            username: args.username.clone(),
            ed25519_signing: identity.ed25519_signing.clone(),
        },
    )
    .await
    .context("ws handshake")?;

    let descriptor = consume_invite(
        &mut session,
        &ClientIdentity {
            username: args.username.clone(),
            ed25519_signing: identity.ed25519_signing.clone(),
        },
        &args.code,
    )
    .await
    .context("consume invite")?;

    let file = IdentityFile {
        version: 1,
        username: args.username.clone(),
        ed25519_pub_b64: ed_pub_b64,
        x25519_pub_b64: x_pub_b64,
        master_secret_b64: B64.encode(identity.master),
        created_at: Utc::now(),
    };
    save_identity(&path, &file, args.force).context("save identity")?;

    println!(
        "Paired with @{}. Room: {}. Identity saved to {}.",
        descriptor.peer_username,
        descriptor.room_id,
        path.display()
    );
    Ok(())
}

fn ws_to_rest_base(server: &str) -> Result<String> {
    let s = server.trim_end_matches('/');
    if let Some(rest) = s.strip_prefix("wss://") {
        Ok(format!("https://{rest}"))
    } else if let Some(rest) = s.strip_prefix("ws://") {
        Ok(format!("http://{rest}"))
    } else {
        Ok(s.to_string())
    }
}
