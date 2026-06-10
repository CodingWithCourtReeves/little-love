//! `run` subcommand: subscribe to the room, decrypt inbound, call LLM,
//! encrypt + send reply.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;

use crate::cli::RunArgs;
use crate::history::{History, Role};
use crate::identity_store::{default_identity_path, load_identity};
use crate::llm::{LlmClient, LlmRequest};
use crate::persona::{resolve, PersonaSources};
use crate::ws_client::{
    connect_and_identify, next_inbound, send_message, subscribe, ClientIdentity, Inbound,
};
use littlelove_crypto::{aead, ecdh};

pub async fn run(args: RunArgs) -> Result<()> {
    let id_path = default_identity_path();
    let file = load_identity(&id_path)
        .with_context(|| format!("load identity {id_path:?} — did you run `pair`?"))?;
    let master = B64
        .decode(file.master_secret_b64.as_bytes())
        .context("decode master_secret_b64")?;
    let master_arr: [u8; 32] = master
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("master_secret_b64 is not 32 bytes"))?;
    // Re-derive from master via the same HKDF path as derive_identity
    // (the spec stores the master, not the seed — derive_identity takes a
    // seed, so we expose a master-input path here):
    let identity_keypair = derive_identity_from_master(&master_arr)?;
    let signing = SigningKey::from_bytes(&identity_keypair.signing_seed);
    let x_pub_bytes = B64.decode(file.x25519_pub_b64.as_bytes())?;
    let _: [u8; 32] = x_pub_bytes
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("x25519_pub_b64 is not 32 bytes"))?;

    let card = match &args.character_card {
        Some(p) => {
            let bytes = std::fs::read(p).with_context(|| format!("read {p:?}"))?;
            Some(crate::character_card::parse_png(&bytes)?)
        }
        None => None,
    };
    let file_prompt = match &args.system_prompt_file {
        Some(p) => Some(std::fs::read_to_string(p).with_context(|| format!("read {p:?}"))?),
        None => None,
    };
    let env_prompt = std::env::var("LITTLELOVE_BOT_SYSTEM_PROMPT").ok();

    let system_prompt = resolve(
        PersonaSources {
            card,
            system_prompt_file_contents: file_prompt,
            env_prompt,
        },
        &file.username,
    )?;

    let llm = LlmClient::new(
        &args.llm_url,
        &args.model,
        args.temperature,
        args.max_tokens,
        Duration::from_secs(60),
    )?;

    let ws_url = format!("{}/connect", args.server.trim_end_matches('/'));
    let mut session = connect_and_identify(
        &ws_url,
        &ClientIdentity {
            username: file.username.clone(),
            ed25519_signing: signing.clone(),
        },
    )
    .await
    .context("ws handshake")?;

    let room = session
        .initial_rooms
        .first()
        .cloned()
        .ok_or_else(|| anyhow!("no rooms in initial Rooms frame — did pairing complete?"))?;
    tracing::info!(
        "subscribed to room {} with peer @{}",
        room.room_id,
        room.peer_username
    );

    let peer_x_pub: [u8; 32] = B64
        .decode(room.peer_x25519_pub.as_bytes())
        .context("decode peer_x25519_pub")?
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("peer x25519_pub not 32 bytes"))?;
    let room_key = ecdh::derive_room_key(&identity_keypair.enc_seed, &peer_x_pub, &room.room_id)
        .context("derive room key")?;

    subscribe(&mut session, &room.room_id).await?;
    let mut history = History::new(args.history);

    while let Some(inbound) = next_inbound(&mut session).await? {
        match inbound {
            Inbound::Message {
                from,
                body,
                replayed,
                ..
            } if from != file.username => {
                let plain = match aead::decrypt_wire(&room_key, &body) {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::warn!("decrypt failed for inbound frame from {from}: {e}");
                        continue;
                    }
                };
                let text = String::from_utf8_lossy(&plain).into_owned();
                history.push(Role::User, text.clone());
                if replayed {
                    continue;
                }
                let reply_text = match llm
                    .chat(&LlmRequest {
                        system_prompt: system_prompt.clone(),
                        history: &history,
                        latest_user: &text,
                    })
                    .await
                {
                    Ok(r) => r,
                    Err(e) => {
                        tracing::error!("LLM error: {e}");
                        format!("[llm error: {e}]")
                    }
                };
                history.push(Role::Assistant, reply_text.clone());
                let wire = aead::encrypt_wire(&room_key, reply_text.as_bytes())?;
                send_message(&mut session, &room.room_id, &wire).await?;
            }
            _ => { /* skip — own messages, RoomCreated, etc. */ }
        }
    }
    Ok(())
}

struct IdentityKeypairBytes {
    signing_seed: [u8; 32],
    enc_seed: [u8; 32],
}

fn derive_identity_from_master(master: &[u8; 32]) -> Result<IdentityKeypairBytes> {
    let signing_seed = expand(b"littlelove.v0.2.signing", master)?;
    let enc_seed = expand(b"littlelove.v0.2.encryption", master)?;
    Ok(IdentityKeypairBytes {
        signing_seed,
        enc_seed,
    })
}

fn expand(salt: &[u8], ikm: &[u8]) -> Result<[u8; 32]> {
    use hkdf::Hkdf;
    use sha2::Sha256;
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    hk.expand(&[], &mut out).map_err(|_| anyhow!("hkdf"))?;
    Ok(out)
}
