//! `run` subcommand: subscribe to the room, decrypt inbound, call LLM,
//! encrypt + send reply, persist turns to per-room memory.

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
    let llm = Arc::new(llm);

    let ws_url = format!("{}/ws", args.server.trim_end_matches('/'));
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

    let memory_dir = args
        .memory_dir
        .clone()
        .unwrap_or_else(|| default_identity_path().parent().unwrap().to_path_buf());
    let memory = Arc::new(Mutex::new(
        Memory::open(&memory_dir, &room.room_id)
            .with_context(|| format!("open memory at {}", memory_dir.display()))?,
    ));

    {
        let needs = {
            let m = memory.lock().await;
            m.summary().is_none() && m.latest_turn_id()? > 0
        };
        if needs {
            tracing::info!(
                "first run with existing turns and no summary — running synchronous catch-up summary"
            );
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
