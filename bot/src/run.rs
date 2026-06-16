//! `run` subcommand: subscribe to the room, decrypt inbound, call LLM,
//! encrypt + send reply, persist turns to per-room memory.

use std::sync::atomic::{AtomicBool, Ordering};
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
    // Extract the persona's name *before* moving `card` into PersonaSources so
    // summary prompts can address the character by name instead of "bot".
    let character_name = card
        .as_ref()
        .map(|c| c.data.name.clone())
        .unwrap_or_else(|| "bot".to_string());
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
                character_name.clone(),
                room.peer_username.clone(),
            )
            .await
            {
                tracing::warn!("startup summary failed: {e}");
            }
        }
    }

    // Guard against concurrent summary refreshes. The threshold check
    // (`needs_summary`) stays true until the summary row commits, so without
    // this flag a burst of turns can spawn N parallel tasks that snapshot
    // different `covers_up_to_turn_id` values and clobber each other on
    // commit (last writer wins, possibly with a *smaller* covers value).
    let summary_in_flight = Arc::new(AtomicBool::new(false));

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
                if replayed {
                    // Server is re-delivering history we've already persisted.
                    // Skip before record_turn so we don't duplicate user turns
                    // in the log (and indirectly in the next summary).
                    //
                    // Tradeoff: if the bot crashed between receiving a live
                    // (non-replayed) message and calling record_turn, the
                    // server's replay on next start is the only way to
                    // recover those turns — but this skip drops them too.
                    // Acceptable for v0.3; a content-aware dedup (per-room
                    // last-persisted ts or message-id) would let us trust
                    // replays without double-writing.
                    continue;
                }
                let text = String::from_utf8_lossy(&plain).into_owned();
                // Assemble the prompt BEFORE recording the user turn, otherwise
                // assemble_prompt pulls the just-recorded turn into `recent` AND
                // appends `latest_user_msg` again, so the LLM sees the same
                // message twice. record_turn happens after the LLM call.
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
                let reply_text: Option<String> = match llm.chat(&msgs).await {
                    Ok(r) => Some(r),
                    Err(e) => {
                        tracing::error!("LLM error: {e}");
                        None
                    }
                };
                let Some(reply_text) = reply_text else {
                    // LLM hiccuped. Tell the peer something brief so they
                    // aren't left hanging, but do NOT persist either turn —
                    // we never produced a real reply and don't want the
                    // error or this exchange leaking into the next summary
                    // as if it were real conversation.
                    //
                    // Tradeoff: the bot has no memory it ever said "having
                    // trouble" — when the user re-sends, the next reply sees
                    // the user message as the first occurrence, with no
                    // acknowledgment of the prior attempt. We accept that:
                    // poisoning the summary with error strings is worse than
                    // a one-turn amnesia. If we ever want the bot to remember
                    // "I told them I was struggling earlier", add a distinct
                    // Role variant (e.g. Role::SystemNotice) that is excluded
                    // from the summary input but kept in recent turns.
                    let fallback = "(having trouble right now — try again in a moment)";
                    let wire = aead::encrypt_wire(&room_key, fallback.as_bytes())?;
                    send_message(&mut session, &room.room_id, &room.peer_x25519_pub, &wire).await?;
                    continue;
                };
                {
                    let mut m = memory.lock().await;
                    m.record_turn(Role::User, &text)?;
                    m.record_turn(Role::Assistant, &reply_text)?;
                }
                let wire = aead::encrypt_wire(&room_key, reply_text.as_bytes())?;
                send_message(&mut session, &room.room_id, &room.peer_x25519_pub, &wire).await?;

                let trigger = { memory.lock().await.needs_summary(args.summary_every)? };
                // Only spawn if no other refresh is in flight. swap returns
                // the previous value: if it was false we won the race (and
                // it's now true); if it was true another task already owns
                // the slot and we skip.
                if trigger && !summary_in_flight.swap(true, Ordering::SeqCst) {
                    let mem_c = memory.clone();
                    let llm_c = llm.clone();
                    let char_name = character_name.clone();
                    let peer = room.peer_username.clone();
                    let flag = summary_in_flight.clone();
                    tokio::spawn(async move {
                        if let Err(e) = run_summary_refresh(mem_c, llm_c, char_name, peer).await {
                            tracing::warn!("summary refresh failed: {e}");
                        }
                        flag.store(false, Ordering::SeqCst);
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
