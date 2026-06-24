use std::collections::{HashMap, HashSet};
use std::time::Duration;

use axum::{
    extract::{
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::Utc;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};
use ulid::Ulid;
use uuid::Uuid;

use crate::accounts::{
    lookup_ed25519_pub, lookup_full_account, lookup_full_account_by_id, AccountRecord,
};
use crate::attachments::{attachment_room, insert_attachment};
use crate::invites::{
    create_invite_record, default_expiry, lookup_invite, mark_consumed, qr_png_base64,
    room_for_invite, InviteState,
};
use crate::profiles::{profile_for_account, upsert_profile};
use crate::push::{PushMessage, PushSender, SendOutcome};
use crate::push_tokens::{delete_token, delete_token_value, tokens_for_account, upsert_token};
use crate::rooms::{
    account_id_by_username, create_room_with_members, is_member, leave_room,
    list_rooms_for_account, members_for_room, partner_account_id_for, partner_username_for,
    rename_room, room_detail, set_partner_link, CreateRoomError, Member, MonogamyError, PairError,
};
use crate::routing::Routing;
use crate::store::{MessageRow, Store};
use crate::wire::{
    error_codes, AuthClientFrame, AuthServerFrame, IdentifyPayload, Member as WireMember,
    PendingInvite, RoomClientFrame, RoomServerFrame,
};
use littlelove_crypto::invite::{decode_code, generate_invite, sha256};
use littlelove_crypto::sig::{
    decode_b64, encode_b64, random_nonce, verify_invite_consume_signature, verify_signature,
};
use std::sync::Arc;

const MAX_ROOM_NAME_CHARS: usize = 64;
/// Hard cap on recipients per Send. Rooms with this many addressed peers are
/// well past the product target (a couple in a shared room); the cap is a DoS
/// bound, not a product limit.
const MAX_SEND_RECIPIENTS: usize = 16;
/// Hard cap on per-recipient ciphertext (base64). 96 KiB fits a long text
/// message OR a `kind:"file"` envelope whose inline thumbnail is ~5–15 KB
/// (base64-expanded). Full file bytes never travel in the body — they go to R2.
const MAX_BODY_BYTES: usize = 98_304;
/// Hard cap on a single attachment upload (raw plaintext bytes). 256 MiB,
/// single presigned PUT, one-shot client-side AEAD (spec §4). Lowered from
/// 500 MiB: download decrypts in-memory (ciphertext + plaintext both resident,
/// ~2× file), so 500 MiB risked iOS jetsam; 256 MiB keeps peak ~512 MiB.
const MAX_ATTACHMENT_BYTES: i64 = 256 * 1024 * 1024;
/// Heartbeat: the server pings each session on this cadence (keeps NAT/proxy
/// connections alive) and considers a session dead — flipping presence to
/// offline — if nothing (a frame OR an auto-pong) arrives within
/// [`LIVENESS_TIMEOUT`]. A live foreground client auto-pongs every tick; a
/// suspended/dropped one stops, so it ages out within the timeout.
const PING_INTERVAL: Duration = Duration::from_secs(15);
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(40);

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
    pub r2: Option<crate::r2::R2Presigner>,
    pub push: Option<Arc<dyn PushSender>>,
    /// TURN credential config (Cloudflare key or local override). `None` →
    /// calls fall back to whatever STUN/direct connectivity they can manage.
    pub turn: Option<crate::config::TurnConfig>,
    /// Shared HTTP client for the Cloudflare `generate-ice-servers` call.
    /// `reqwest::Client` is internally `Arc`, so cloning `AppState` is cheap.
    pub http: reqwest::Client,
    /// Call invites held for callees not yet (re)connected — delivered when the
    /// callee's WS comes up (e.g. after a VoIP-push cold start).
    pub pending_calls: Arc<crate::calls::PendingCalls>,
}

/// WSS close code for auth failures (spec §3.3 step 6).
const CLOSE_AUTH_FAILED: u16 = 4001;

pub async fn ws_handler(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handshake(socket: &mut WebSocket, state: &AppState) -> Option<AccountRecord> {
    let nonce = random_nonce();
    let challenge = AuthServerFrame::Challenge {
        nonce: encode_b64(&nonce),
    };
    if socket
        .send(Message::Text(serde_json::to_string(&challenge).ok()?))
        .await
        .is_err()
    {
        return None;
    }

    let raw = match socket.next().await {
        Some(Ok(Message::Text(t))) => t,
        _ => {
            close_auth_failed(socket).await;
            return None;
        }
    };

    let frame: AuthClientFrame = match serde_json::from_str(&raw) {
        Ok(f) => f,
        Err(_) => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let AuthClientFrame::Identify(IdentifyPayload {
        username,
        signature,
    }) = frame;

    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let pub_key = match lookup_ed25519_pub(store, &username).await {
        Ok(Some(b)) => b,
        _ => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let sig_bytes = match decode_b64(&signature) {
        Ok(b) => b,
        Err(_) => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    if verify_signature(&pub_key, &nonce, &sig_bytes).is_err() {
        close_auth_failed(socket).await;
        return None;
    }

    let account = match lookup_full_account(store, &username).await {
        Ok(Some(a)) => a,
        _ => {
            close_auth_failed(socket).await;
            return None;
        }
    };

    let ok = serde_json::to_string(&AuthServerFrame::Authenticated).ok()?;
    if socket.send(Message::Text(ok)).await.is_err() {
        return None;
    }
    Some(account)
}

async fn close_auth_failed(socket: &mut WebSocket) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code: CLOSE_AUTH_FAILED,
            reason: "auth failed".into(),
        })))
        .await;
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    let me = match handshake(&mut socket, &state).await {
        Some(a) => a,
        None => return,
    };
    info!(username = %me.username, "client authenticated");

    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<RoomServerFrame>();
    state
        .routing
        .register(me.username.clone(), tx.clone())
        .await;

    if let Some(store) = state.store.as_ref() {
        let rooms = match list_rooms_for_account(store.pool(), me.id).await {
            Ok(rows) => rows.into_iter().map(|r| r.into_wire()).collect::<Vec<_>>(),
            Err(e) => {
                warn!("list_rooms_for_account failed: {e}");
                Vec::new()
            }
        };
        let _ = tx.send(RoomServerFrame::Rooms { rooms });
    } else {
        let _ = tx.send(RoomServerFrame::Rooms { rooms: Vec::new() });
    }

    announce_presence_on_connect(&state, &me, &tx).await;
    deliver_pending_calls(&state, &me, &tx).await;

    let mut upload_rl = WindowRateLimiter::new(UPLOAD_RL_WINDOW, UPLOAD_RL_MAX);
    let mut typing_rl = WindowRateLimiter::new(TYPING_RL_WINDOW, TYPING_RL_MAX);
    let mut turn_rl = WindowRateLimiter::new(TURN_RL_WINDOW, TURN_RL_MAX);
    // Call invites trigger a VoIP push to the partner; gate them like TURN so a
    // misbehaving client can't spam-ring (or drain) the partner's device.
    let mut call_rl = WindowRateLimiter::new(TURN_RL_WINDOW, TURN_RL_MAX);
    // First tick after a full interval (not immediately) so we never ping a
    // client the instant it connects.
    let mut ping =
        tokio::time::interval_at(tokio::time::Instant::now() + PING_INTERVAL, PING_INTERVAL);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_seen = tokio::time::Instant::now();
    loop {
        tokio::select! {
            // Outbound: relay queued server frames to this session. We hold `tx`
            // for the whole handler, so `rx` stays open until we break.
            maybe_frame = rx.recv() => {
                let Some(frame) = maybe_frame else { break };
                match serde_json::to_string(&frame) {
                    Ok(text) => {
                        if sink.send(Message::Text(text)).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => warn!("failed to serialize outbound frame: {e}"),
                }
            }
            // Heartbeat: ping each tick; age out a session gone quiet past the
            // liveness window (its presence flips offline on cleanup below).
            _ = ping.tick() => {
                if last_seen.elapsed() > LIVENESS_TIMEOUT {
                    info!(username = %me.username, "session timed out (no heartbeat)");
                    break;
                }
                if sink.send(Message::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
            // Inbound: client frames, auto-pongs, close. Any inbound traffic
            // (including a pong) refreshes liveness.
            maybe_msg = stream.next() => {
                last_seen = tokio::time::Instant::now();
                let msg = match maybe_msg {
                    Some(Ok(m)) => m,
                    _ => break,
                };
                let text = match msg {
                    Message::Text(t) => t,
                    Message::Close(_) => break,
                    _ => continue,
                };
                match serde_json::from_str::<RoomClientFrame>(&text) {
                Ok(RoomClientFrame::CreateInvite) => {
                    handle_create_invite(&state, &me, &tx).await;
                }
                Ok(RoomClientFrame::ConsumeInvite {
                    code,
                    signature_over_token,
                }) => {
                    handle_consume_invite(&state, &me, &code, &signature_over_token, &tx).await;
                }
                Ok(RoomClientFrame::Subscribe {
                    room_id,
                    since_message_id,
                }) => {
                    handle_subscribe(&state, &me, &room_id, since_message_id.as_deref(), &tx).await;
                }
                Ok(RoomClientFrame::Send {
                    room_id,
                    bodies,
                    client_msg_id,
                }) => {
                    handle_send(&state, &me, &room_id, bodies, client_msg_id, &tx).await;
                }
                Ok(RoomClientFrame::CreateRoom {
                    name,
                    invite_human_partner,
                }) => {
                    handle_create_room(&state, &me, name, invite_human_partner, &tx).await;
                }
                Ok(RoomClientFrame::RenameRoom { room_id, name }) => {
                    handle_rename_room(&state, &me, &room_id, &name, &tx).await;
                }
                Ok(RoomClientFrame::LeaveRoom { room_id }) => {
                    handle_leave_room(&state, &me, &room_id, &tx).await;
                }
                Ok(RoomClientFrame::MarkRead {
                    room_id,
                    up_to_message_id,
                }) => {
                    handle_mark_read(&state, &me, &room_id, &up_to_message_id, &tx).await;
                }
                Ok(RoomClientFrame::Typing { room_id, typing }) => {
                    // Best-effort presence: silently drop a flood rather than
                    // erroring back (the client doesn't surface typing errors,
                    // and the indicator self-expires on the receiver).
                    if typing_rl.allow() {
                        handle_typing(&state, &me, &room_id, typing).await;
                    } else {
                        warn!("typing rate limit hit for {}", me.username);
                    }
                }
                Ok(RoomClientFrame::PublishProfile {
                    envelope,
                    avatar_key,
                }) => {
                    handle_publish_profile(&state, &me, &envelope, avatar_key.as_deref(), &tx)
                        .await;
                }
                Ok(RoomClientFrame::RequestUpload {
                    request_id,
                    room_id,
                    byte_size,
                }) => {
                    if upload_rl.allow() {
                        handle_request_upload(&state, &me, request_id, &room_id, byte_size, &tx)
                            .await;
                    } else {
                        warn!("upload rate limit hit for {}", me.username);
                        send_error(&tx, error_codes::RATE_LIMITED, "");
                    }
                }
                Ok(RoomClientFrame::RequestDownload { blob_key }) => {
                    handle_request_download(&state, &me, &blob_key, &tx).await;
                }
                Ok(RoomClientFrame::RegisterPush {
                    device_id,
                    apns_token,
                    environment,
                    token_kind,
                }) => {
                    if let Some(store) = state.store.as_ref() {
                        if let Err(e) = upsert_token(
                            store.pool(),
                            me.id,
                            &device_id,
                            &apns_token,
                            &environment,
                            &token_kind,
                        )
                        .await
                        {
                            warn!("RegisterPush upsert failed: {e}");
                        }
                    }
                }
                Ok(RoomClientFrame::UnregisterPush { device_id }) => {
                    if let Some(store) = state.store.as_ref() {
                        if let Err(e) = delete_token(store.pool(), me.id, &device_id).await {
                            warn!("UnregisterPush delete failed: {e}");
                        }
                    }
                }
                Ok(RoomClientFrame::CallTurnRequest { call_id }) => {
                    if turn_rl.allow() {
                        handle_call_turn_request(&state, &me, &call_id, &tx).await;
                    } else {
                        warn!("TURN credential rate limit hit for {}", me.username);
                        send_error(&tx, error_codes::RATE_LIMITED, "");
                    }
                }
                Ok(RoomClientFrame::CallInvite {
                    room_id,
                    call_id,
                    offer,
                    video,
                }) => {
                    if call_rl.allow() {
                        handle_call_invite(&state, &me, room_id, call_id, offer, video).await;
                    } else {
                        warn!("call invite rate limit hit for {}", me.username);
                        send_error(&tx, error_codes::RATE_LIMITED, "");
                    }
                }
                Ok(RoomClientFrame::CallAnswer {
                    room_id,
                    call_id,
                    answer,
                }) => {
                    forward_call_to_partner(
                        &state,
                        &me,
                        RoomServerFrame::CallAnswer {
                            room_id,
                            call_id,
                            answer,
                        },
                    )
                    .await;
                }
                Ok(RoomClientFrame::CallIce {
                    room_id,
                    call_id,
                    candidate,
                }) => {
                    forward_call_to_partner(
                        &state,
                        &me,
                        RoomServerFrame::CallIce {
                            room_id,
                            call_id,
                            candidate,
                        },
                    )
                    .await;
                }
                Ok(RoomClientFrame::CallHangup {
                    room_id,
                    call_id,
                    reason,
                }) => {
                    handle_call_hangup(&state, &me, room_id, call_id, reason).await;
                }
                Err(e) => warn!("invalid frame from {}: {e}", me.username),
                }
            }
        }
    }

    state.routing.unregister(&me.username, &tx).await;
    announce_presence_on_disconnect(&state, &me).await;
    info!(username = %me.username, "client disconnected");
}

fn send_error(tx: &mpsc::UnboundedSender<RoomServerFrame>, code: &str, message: &str) {
    let _ = tx.send(RoomServerFrame::Error {
        code: code.to_string(),
        message: message.to_string(),
    });
}

/// Mint ICE credentials for a call and return them to the requesting session.
///
/// Authorization: only a *paired* account may mint credentials. A call only
/// ever exists between the two partners of a room, so an unpaired principal has
/// no legitimate call — refusing here stops an authenticated account from using
/// our Cloudflare TURN allotment as a free relay (the credentials authorize
/// metered egress). The caller also rate-limits this (`turn_rl`).
///
/// On any *failure* (unpaired, no TURN config, or the Cloudflare call errors) we
/// send a `CallTurnGrant` with an empty `iceServers` list rather than an error
/// frame: the client can still attempt a direct/host-candidate connection, and a
/// relay failure should degrade, not abort call setup. The empty list simply
/// withholds the relay.
async fn handle_call_turn_request(
    state: &AppState,
    me: &AccountRecord,
    call_id: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let empty = || serde_json::json!({ "iceServers": [] });

    // Authorization gate: require an established pairing before minting.
    let paired = match state.store.as_ref() {
        Some(store) => matches!(
            partner_account_id_for(store.pool(), me.id).await,
            Ok(Some(_))
        ),
        None => false,
    };

    let ice_servers = if !paired {
        warn!(
            "CallTurnRequest from unpaired account {}; withholding relay",
            me.username
        );
        empty()
    } else {
        match state.turn.as_ref() {
            Some(cfg) => match crate::turn::ice_servers(cfg, &state.http).await {
                Ok(v) => v,
                Err(e) => {
                    warn!("TURN credential mint failed for call {call_id}: {e}");
                    empty()
                }
            },
            None => {
                warn!("CallTurnRequest but TURN is not configured");
                empty()
            }
        }
    };
    let n = ice_servers
        .get("iceServers")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    info!("call: CallTurnGrant for call={call_id} ({n} ice servers)");
    let _ = tx.send(RoomServerFrame::CallTurnGrant {
        call_id: call_id.to_string(),
        ice_servers,
    });
}

/// Deliver a call-signaling frame to the requester's partner (the only other
/// member of a 1:1 room). No-op if unpaired or the partner is offline (the
/// caller will hang up / time out). Used for answer/ice/hangup relays.
async fn forward_call_to_partner(state: &AppState, me: &AccountRecord, frame: RoomServerFrame) {
    let Some(store) = state.store.as_ref() else {
        return;
    };
    // Apply-layer authorization: the sender must actually belong to the room the
    // frame names. Both partners share the room key, so without this a misbehaving
    // client could inject answer/ice/hangup frames naming an arbitrary room.
    if let Some(room_id) = frame_room_id(&frame) {
        match is_member(store.pool(), room_id, me.id).await {
            Ok(true) => {}
            Ok(false) => {
                warn!(
                    "call: {} from {} for room {room_id} it's not a member of; dropping",
                    frame_kind(&frame),
                    me.username,
                );
                return;
            }
            Err(e) => {
                warn!("forward_call_to_partner: is_member failed: {e}");
                return;
            }
        }
    }
    match partner_username_for(store.pool(), me.id).await {
        Ok(Some(partner)) => {
            let online = state.routing.is_online(&partner).await;
            info!(
                "call: forwarding {} from {} -> {} (online={online})",
                frame_kind(&frame),
                me.username,
                partner
            );
            state.routing.deliver(&partner, frame).await;
        }
        Ok(None) => warn!(
            "call: {} from {} but no partner",
            frame_kind(&frame),
            me.username
        ),
        Err(e) => warn!("forward_call_to_partner: partner lookup failed: {e}"),
    }
}

fn frame_kind(f: &RoomServerFrame) -> &'static str {
    match f {
        RoomServerFrame::CallInvite { .. } => "CallInvite",
        RoomServerFrame::CallAnswer { .. } => "CallAnswer",
        RoomServerFrame::CallIce { .. } => "CallIce",
        RoomServerFrame::CallHangup { .. } => "CallHangup",
        _ => "other",
    }
}

/// The `room_id` a call frame names, for the apply-layer membership check.
fn frame_room_id(f: &RoomServerFrame) -> Option<&str> {
    match f {
        RoomServerFrame::CallInvite { room_id, .. }
        | RoomServerFrame::CallAnswer { room_id, .. }
        | RoomServerFrame::CallIce { room_id, .. }
        | RoomServerFrame::CallHangup { room_id, .. } => Some(room_id.as_str()),
        _ => None,
    }
}

/// Caller starts a call: forward the encrypted offer to the partner's open
/// sessions, hold it for a woken cold-start callee, and fire a VoIP push.
async fn handle_call_invite(
    state: &AppState,
    me: &AccountRecord,
    room_id: String,
    call_id: String,
    offer: String,
    video: bool,
) {
    let Some(store) = state.store.as_ref() else {
        return;
    };
    // Apply-layer authorization: the caller must belong to the room it's
    // inviting in (the partner derives the per-call sig-key from this room's key).
    match is_member(store.pool(), &room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            warn!(
                "call: CallInvite from {} for room {room_id} it's not a member of; dropping",
                me.username
            );
            return;
        }
        Err(e) => {
            warn!("handle_call_invite: is_member failed: {e}");
            return;
        }
    }
    let partner = match partner_account_id_for(store.pool(), me.id).await {
        Ok(Some(p)) => p,
        Ok(None) => return, // unpaired: no one to call
        Err(e) => {
            warn!("handle_call_invite: partner lookup failed: {e}");
            return;
        }
    };
    let partner_username = match partner_username_for(store.pool(), me.id).await {
        Ok(Some(u)) => u,
        _ => return,
    };

    // Hold the invite (TTL) so a VoIP-woken callee can fetch it on (re)connect,
    // and opportunistically sweep stale entries.
    let now = std::time::Instant::now();
    state.pending_calls.expire_due(now);
    state.pending_calls.insert(
        partner,
        crate::calls::Pending {
            call_id: call_id.clone(),
            room_id: room_id.clone(),
            from: me.username.clone(),
            offer: offer.clone(),
            video,
            expires_at: now + crate::calls::PENDING_TTL,
        },
    );

    // Forward to any open partner sessions (foreground case).
    let online = state.routing.is_online(&partner_username).await;
    info!(
        "call: CallInvite from {} -> {} call={call_id} (partner online={online})",
        me.username, partner_username
    );
    state
        .routing
        .deliver(
            &partner_username,
            RoomServerFrame::CallInvite {
                room_id: room_id.clone(),
                call_id: call_id.clone(),
                from: me.username.clone(),
                offer,
                video,
            },
        )
        .await;

    // Wake the partner's device(s) via VoIP push (background / killed case).
    if let Some(sender) = state.push.clone() {
        notify_call(&sender, store, partner, &room_id, &call_id, video).await;
    }
}

/// Forward a hangup to the partner and drop any held invite for it (covers the
/// caller cancelling before a woken callee reconnected).
async fn handle_call_hangup(
    state: &AppState,
    me: &AccountRecord,
    room_id: String,
    call_id: String,
    reason: String,
) {
    let Some(store) = state.store.as_ref() else {
        return;
    };
    if let Ok(Some(partner)) = partner_account_id_for(store.pool(), me.id).await {
        state.pending_calls.remove(partner, &call_id);
    }
    forward_call_to_partner(
        state,
        me,
        RoomServerFrame::CallHangup {
            room_id,
            call_id,
            reason,
        },
    )
    .await;
}

/// Send a content-free VoIP push to every PushKit token of the callee, deleting
/// any token APNs reports as permanently dead.
async fn notify_call(
    sender: &Arc<dyn PushSender>,
    store: &Store,
    callee_account_id: i64,
    room_id: &str,
    call_id: &str,
    video: bool,
) {
    let tokens = match crate::push_tokens::voip_tokens_for(store.pool(), callee_account_id).await {
        Ok(t) => t,
        Err(e) => {
            warn!("notify_call: voip_tokens_for failed: {e}");
            return;
        }
    };
    for t in tokens {
        let msg = PushMessage {
            token: t.apns_token.clone(),
            environment: t.environment.clone(),
            room_id: room_id.to_string(),
            badge: 0,
            push_type: crate::push::PushKind::Voip,
            call_id: Some(call_id.to_string()),
            video,
        };
        if let SendOutcome::DropToken = sender.send(&msg).await {
            if let Err(e) = delete_token_value(store.pool(), callee_account_id, &t.apns_token).await
            {
                warn!("notify_call: delete_token_value failed: {e}");
            }
        }
    }
}

async fn handle_create_invite(
    state: &AppState,
    me: &AccountRecord,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    // Re-read partner status live — the handshake-time snapshot can be stale
    // if another device of the same human paired in parallel.
    match partner_account_id_for(store.pool(), me.id).await {
        Ok(Some(_)) => {
            send_error(tx, error_codes::ALREADY_PAIRED, "");
            return;
        }
        Ok(None) => {}
        Err(e) => {
            warn!("partner_account_id_for: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    let (canonical, code, hash) = generate_invite();
    let expires_at = default_expiry(Utc::now());
    if let Err(e) = create_invite_record(store.pool(), me.id, &hash, expires_at, None).await {
        warn!("create_invite_record failed: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    let qr = match qr_png_base64(&code) {
        Ok(s) => s,
        Err(e) => {
            warn!("qr render failed: {e}");
            String::new()
        }
    };
    let _ = canonical;
    let _ = tx.send(RoomServerFrame::InviteCreated {
        code,
        qr_png_base64: qr,
        expires_at,
    });
}

async fn handle_consume_invite(
    state: &AppState,
    me: &AccountRecord,
    code: &str,
    signature_over_token_b64: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };

    let canonical = match decode_code(code) {
        Ok(t) => t,
        Err(_) => {
            send_error(tx, error_codes::BAD_CODE, "");
            return;
        }
    };
    let token_hash = sha256(&canonical);

    let invite = match lookup_invite(store.pool(), &token_hash).await {
        Ok(Some(i)) => i,
        Ok(None) => {
            send_error(tx, error_codes::INVITE_NOT_FOUND, "");
            return;
        }
        Err(e) => {
            warn!("lookup_invite failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };

    match invite.state(Utc::now()) {
        InviteState::Expired => {
            send_error(tx, error_codes::INVITE_EXPIRED, "");
            return;
        }
        InviteState::Consumed => {
            send_error(tx, error_codes::INVITE_CONSUMED, "");
            return;
        }
        InviteState::Pending => {}
    }

    let sig_bytes = match decode_b64(signature_over_token_b64) {
        Ok(b) => b,
        Err(_) => {
            send_error(tx, error_codes::INVALID_SIGNATURE, "");
            return;
        }
    };
    if verify_invite_consume_signature(&me.ed25519_pub, &canonical, &sig_bytes).is_err() {
        send_error(tx, error_codes::INVALID_SIGNATURE, "");
        return;
    }

    let inviter = match lookup_full_account_by_id(store, invite.inviter_id).await {
        Ok(Some(a)) => a,
        _ => {
            send_error(tx, error_codes::INVITE_NOT_FOUND, "");
            return;
        }
    };
    if inviter.id == me.id {
        send_error(tx, error_codes::ALREADY_PAIRED, "self-invite");
        return;
    }

    // Atomic monogamy check + partner-link write. If this fails (race lost,
    // peer already paired with someone else, or DB-level UNIQUE constraint
    // backstop fires), the invite is NOT consumed — the user can retry or
    // the inviter can issue a new invite. Must run before any side effects.
    match set_partner_link(store.pool(), me.id, inviter.id).await {
        Ok(()) => {}
        Err(PairError::Monogamy(MonogamyError::WrongPartner)) => {
            send_error(
                tx,
                error_codes::MONOGAMY_VIOLATION,
                "you already have a partner",
            );
            return;
        }
        Err(PairError::Db(e)) => {
            // 23505 = unique_violation — the partial UNIQUE index on
            // partner_account_id caught a race the app check missed.
            if let sqlx::Error::Database(db) = &e {
                if db.code().as_deref() == Some("23505") {
                    send_error(
                        tx,
                        error_codes::MONOGAMY_VIOLATION,
                        "you already have a partner",
                    );
                    return;
                }
            }
            warn!("set_partner_link: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }

    // Resolve or create the room on the fly, add the consumer, then mark the
    // invite consumed.
    let room_id = match room_for_invite(store.pool(), &token_hash).await {
        Ok(Some(r)) => r,
        Ok(None) => {
            match create_room_with_members(store.pool(), inviter.id, None, String::new()).await {
                Ok(r) => r,
                Err(CreateRoomError::Db(e)) => {
                    warn!("create_room_with_members (legacy invite): {e}");
                    send_error(tx, "Internal", "");
                    return;
                }
            }
        }
        Err(e) => {
            warn!("room_for_invite: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    if let Err(e) = sqlx::query(
        "INSERT INTO room_members (room_id, account_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING",
    )
    .bind(&room_id)
    .bind(me.id)
    .execute(store.pool())
    .await
    {
        warn!("insert consumer into room_members: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    if let Err(e) = mark_consumed(store.pool(), &token_hash, Utc::now()).await {
        warn!("mark_consumed failed: {e}");
    }

    let detail = match room_detail(store.pool(), &room_id).await {
        Ok(Some(d)) => d,
        _ => {
            send_error(tx, "Internal", "");
            return;
        }
    };
    let members_wire: Vec<WireMember> = detail
        .members
        .iter()
        .cloned()
        .map(Member::into_wire)
        .collect();

    let _ = tx.send(RoomServerFrame::InviteConsumed {
        room_id: detail.room_id.clone(),
        name: detail.name.clone(),
        members: members_wire.clone(),
    });

    let frame = RoomServerFrame::RoomCreated {
        room_id: detail.room_id.clone(),
        name: detail.name.clone(),
        members: members_wire,
        pending_invite: None,
    };
    for m in &detail.members {
        if m.account_id == me.id {
            continue;
        }
        state.routing.deliver(&m.username, frame.clone()).await;
    }
}

async fn handle_subscribe(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    since_message_id: Option<&str>,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    match is_member(store.pool(), room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            send_error(tx, error_codes::UNKNOWN_ROOM, "");
            return;
        }
        Err(e) => {
            warn!("is_member failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    let rows = match store
        .messages_for_recipient(room_id, me.id, since_message_id)
        .await
    {
        Ok(rs) => rs,
        Err(e) => {
            warn!("messages_for_recipient failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    for row in rows {
        let from_username = match lookup_full_account_by_id(store, row.from_account_id).await {
            Ok(Some(a)) => a.username,
            _ => continue,
        };
        let _ = tx.send(RoomServerFrame::Message {
            id: row.id,
            room_id: row.room_id,
            from: from_username,
            ts: row.ts,
            body: row.body,
            replayed: true,
            read: row.read,
            client_msg_id: None,
        });
    }
}

async fn handle_mark_read(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    up_to_message_id: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    match is_member(store.pool(), room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            send_error(tx, error_codes::UNKNOWN_ROOM, "");
            return;
        }
        Err(e) => {
            warn!("is_member failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    let flipped = match store.mark_read(room_id, me.id, up_to_message_id).await {
        Ok(f) => f,
        Err(e) => {
            warn!("mark_read failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    // Group the just-read ids by sender, then relay one Read frame per sender.
    let mut by_sender: HashMap<i64, Vec<String>> = HashMap::new();
    for (id, from_account_id) in flipped {
        by_sender.entry(from_account_id).or_default().push(id);
    }
    for (from_account_id, message_ids) in by_sender {
        let sender = match lookup_full_account_by_id(store, from_account_id).await {
            Ok(Some(a)) => a.username,
            _ => continue,
        };
        let frame = RoomServerFrame::Read {
            room_id: room_id.to_string(),
            message_ids,
            reader: me.username.clone(),
        };
        state.routing.deliver(&sender, frame).await;
    }
}

/// Relay transient typing presence to the other room member(s). Best-effort:
/// no persistence, and membership/lookup failures are silently ignored (a lost
/// typing frame is harmless — the client times the indicator out anyway).
async fn handle_typing(state: &AppState, me: &AccountRecord, room_id: &str, typing: bool) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return,
    };
    if !is_member(store.pool(), room_id, me.id)
        .await
        .unwrap_or(false)
    {
        return;
    }
    let members = members_for_room(store.pool(), room_id)
        .await
        .unwrap_or_default();
    let frame = RoomServerFrame::Typing {
        room_id: room_id.to_string(),
        from: me.username.clone(),
        typing,
    };
    for m in &members {
        if m.account_id == me.id {
            continue;
        }
        state.routing.deliver(&m.username, frame.clone()).await;
    }
}

/// Persist my profile ciphertext and relay it to my linked partner. Authorized
/// by the `accounts.partner_account_id` link — the same authority presence uses.
/// The server stores `envelope` opaquely; it never decodes the profile. Writing
/// only ever touches my own row (`me.id`) and relays only to my own partner, so
/// there is no cross-account action to authorize at the apply layer.
async fn handle_publish_profile(
    state: &AppState,
    me: &AccountRecord,
    envelope_b64: &str,
    avatar_key: Option<&str>,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return,
    };
    let envelope = match B64.decode(envelope_b64) {
        Ok(b) => b,
        Err(_) => {
            send_error(tx, error_codes::BAD_CODE, "");
            return;
        }
    };
    if let Err(e) = upsert_profile(store.pool(), me.id, &envelope, avatar_key).await {
        warn!("upsert_profile: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    match partner_username_for(store.pool(), me.id).await {
        Ok(Some(partner)) => {
            state
                .routing
                .deliver(
                    &partner,
                    RoomServerFrame::Profile {
                        user: me.username.clone(),
                        envelope: envelope_b64.to_string(),
                        avatar_key: avatar_key.map(str::to_string),
                    },
                )
                .await;
        }
        Ok(None) => {} // not paired yet — stored, relayed when they pair/connect
        Err(e) => warn!("partner_username_for (publish_profile): {e}"),
    }
}

/// On connect: tell my partner I'm online, and tell my freshly-connected
/// session whether my partner is currently online. The partner is resolved from
/// the authoritative `accounts.partner_account_id` link, so presence is only
/// ever shared between the two linked partners.
/// Deliver any call invites held for this account (a callee woken by a VoIP
/// push connects and fetches the encrypted offer it was rung for). Expired
/// invites are filtered out by `take_for`.
async fn deliver_pending_calls(
    state: &AppState,
    me: &AccountRecord,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let now = std::time::Instant::now();
    for p in state.pending_calls.take_for(me.id, now) {
        let _ = tx.send(RoomServerFrame::CallInvite {
            room_id: p.room_id,
            call_id: p.call_id,
            from: p.from,
            offer: p.offer,
            video: p.video,
        });
    }
}

async fn announce_presence_on_connect(
    state: &AppState,
    me: &AccountRecord,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return,
    };
    let partner = match partner_username_for(store.pool(), me.id).await {
        Ok(Some(u)) => u,
        Ok(None) => return, // not paired yet — nobody to exchange presence with
        Err(e) => {
            warn!("partner_username_for (connect): {e}");
            return;
        }
    };
    state
        .routing
        .deliver(
            &partner,
            RoomServerFrame::Presence {
                user: me.username.clone(),
                online: true,
                last_seen: None,
            },
        )
        .await;
    let partner_online = state.routing.is_online(&partner).await;
    let _ = tx.send(RoomServerFrame::Presence {
        user: partner.clone(),
        online: partner_online,
        last_seen: None,
    });
    // Replay my partner's latest profile, if any, to this fresh session so the
    // room list / chat header can render their display name + avatar at once.
    // (Durable, unlike presence — modeled on the presence relay otherwise.)
    if let Ok(Some(partner_id)) = partner_account_id_for(store.pool(), me.id).await {
        if let Ok(Some(p)) = profile_for_account(store.pool(), partner_id).await {
            let _ = tx.send(RoomServerFrame::Profile {
                user: partner,
                envelope: B64.encode(&p.envelope),
                avatar_key: p.avatar_key,
            });
        }
    }
}

/// On disconnect: once the user's *last* session has gone, tell their partner
/// they're offline. A reconnect or a second session keeps them online.
async fn announce_presence_on_disconnect(state: &AppState, me: &AccountRecord) {
    if state.routing.is_online(&me.username).await {
        return; // still has another open session
    }
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return,
    };
    match partner_username_for(store.pool(), me.id).await {
        Ok(Some(partner)) => {
            state
                .routing
                .deliver(
                    &partner,
                    RoomServerFrame::Presence {
                        user: me.username.clone(),
                        online: false,
                        last_seen: None,
                    },
                )
                .await;
        }
        Ok(None) => {}
        Err(e) => warn!("partner_username_for (disconnect): {e}"),
    }
}

async fn handle_send(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    bodies: HashMap<String, String>,
    client_msg_id: Uuid,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    if bodies.len() > MAX_SEND_RECIPIENTS {
        send_error(tx, error_codes::BODY_TOO_LARGE, "too many recipients");
        return;
    }
    if bodies.values().any(|b| b.len() > MAX_BODY_BYTES) {
        send_error(tx, error_codes::BODY_TOO_LARGE, "ciphertext too large");
        return;
    }
    match is_member(store.pool(), room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            send_error(tx, error_codes::UNKNOWN_ROOM, "");
            return;
        }
        Err(e) => {
            warn!("is_member failed: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    let members = match members_for_room(store.pool(), room_id).await {
        Ok(m) => m,
        Err(e) => {
            warn!("members_for_room: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    let self_key = B64.encode(&me.x25519_pub);
    let expected: HashSet<String> = members
        .iter()
        .filter(|m| m.account_id != me.id)
        .map(|m| B64.encode(&m.x25519_pub))
        .collect();
    let provided: HashSet<String> = bodies.keys().cloned().collect();
    // The sender MAY include a copy addressed to themselves (encrypted to their
    // own key) so their message history survives a restart — the server is the
    // source of truth for it, same as for every other recipient. The self-copy
    // is optional: a client that omits it still validates against `expected`.
    let has_self_copy = provided.contains(&self_key);
    let mut required = expected.clone();
    if has_self_copy {
        required.insert(self_key.clone());
    }
    if required != provided {
        send_error(tx, error_codes::FAN_OUT_MISMATCH, "");
        return;
    }

    let id = Ulid::new().to_string();
    let ts = Utc::now();
    let mut rows = Vec::with_capacity(members.len() + 1);
    for m in &members {
        // Skip self here; the self-copy (if any) is stored separately below so
        // it is keyed by the sender's own account id and own ciphertext.
        if m.account_id == me.id {
            continue;
        }
        let key = B64.encode(&m.x25519_pub);
        let Some(body) = bodies.get(&key) else {
            continue;
        };
        rows.push(MessageRow {
            id: id.clone(),
            room_id: room_id.to_string(),
            from_account_id: me.id,
            recipient_account_id: m.account_id,
            body: body.clone(),
            ts,
            read: false,
        });
    }
    if has_self_copy {
        if let Some(body) = bodies.get(&self_key) {
            rows.push(MessageRow {
                id: id.clone(),
                room_id: room_id.to_string(),
                from_account_id: me.id,
                recipient_account_id: me.id,
                body: body.clone(),
                ts,
                read: false,
            });
        }
    }
    if let Err(e) = store.insert_many(&rows).await {
        warn!("store.insert_many failed: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    for m in &members {
        if m.account_id == me.id {
            continue;
        }
        let key = B64.encode(&m.x25519_pub);
        let Some(body) = bodies.get(&key) else {
            continue;
        };
        let frame = RoomServerFrame::Message {
            id: id.clone(),
            room_id: room_id.to_string(),
            from: me.username.clone(),
            ts,
            body: body.clone(),
            replayed: false,
            read: false,
            client_msg_id: None,
        };
        state.routing.deliver(&m.username, frame).await;
        // Always notify the recipient's registered devices. The app itself
        // suppresses the banner when it's in the foreground (UNUserNotification
        // willPresent → []), so a backgrounded or quit app gets a banner while an
        // actively-open one stays silent. Gating on "no live WS session" missed
        // the backgrounded case — iOS keeps the socket alive briefly, so the
        // server saw a live session and skipped the push. Spawned so the APNs
        // round-trip never blocks the sender's ack.
        if let (Some(sender), Some(store)) = (state.push.clone(), state.store.clone()) {
            let recipient_id = m.account_id;
            let room = room_id.to_string();
            tokio::spawn(async move {
                notify_recipient(&sender, &store, recipient_id, &room).await;
            });
        }
    }
    // Echo the self-copy live to every open session for the sender, carrying
    // `client_msg_id` so the originating session can swap its optimistic echo
    // for the authoritative row. Replayed history omits `client_msg_id` (it is
    // not persisted), so a fresh-restart session just adds it by `id`.
    if has_self_copy {
        if let Some(body) = bodies.get(&self_key) {
            let frame = RoomServerFrame::Message {
                id: id.clone(),
                room_id: room_id.to_string(),
                from: me.username.clone(),
                ts,
                body: body.clone(),
                replayed: false,
                read: false,
                client_msg_id: Some(client_msg_id),
            };
            state.routing.deliver(&me.username, frame).await;
        }
    }
}

/// Presigned-URL TTL for both upload and download. Long enough for a 256 MiB
/// upload on a slow mobile link; far under R2's 7-day max.
const PRESIGN_TTL: Duration = Duration::from_secs(600);

/// Per-connection sliding-window rate limit on `RequestUpload`. Each grant
/// inserts a row + mints a presigned PUT with no quota and (today) no reaper,
/// so an unthrottled client could loop the frame to amass rows + uploaded
/// objects. The WS read loop is sequential per connection, so this needs no
/// locking. Generous enough that a real multi-file send (the client sends them
/// sequentially) never trips it.
const UPLOAD_RL_WINDOW: Duration = Duration::from_secs(60);
const UPLOAD_RL_MAX: usize = 60;

// Typing presence is chatty by design: the client re-asserts `typing:true` on a
// ~3s heartbeat while composing, plus start/stop toggles, so a real user emits
// only a handful of frames per 10s. This cap leaves generous headroom for that
// while bounding a misbehaving client to 4 frames/s — each frame costs two DB
// reads + a fan-out, so an unbounded stream is the thing worth capping. Blast
// radius is limited to the authenticated partner either way.
const TYPING_RL_WINDOW: Duration = Duration::from_secs(10);
const TYPING_RL_MAX: usize = 40;

// A call needs ICE credentials roughly once at setup (plus the rare mid-call
// refresh). Real call frequency is tiny, but each request triggers a paid
// Cloudflare `generate-ice-servers` round-trip and mints relay credentials, so
// it must be gated like `RequestUpload`. 10/min/connection is generous for a
// couple yet bounds both DoS amplification and third-party cost abuse.
const TURN_RL_WINDOW: Duration = Duration::from_secs(60);
const TURN_RL_MAX: usize = 10;

/// Per-connection sliding-window rate limiter: at most `max` calls per `window`.
struct WindowRateLimiter {
    hits: std::collections::VecDeque<std::time::Instant>,
    window: Duration,
    max: usize,
}

impl WindowRateLimiter {
    fn new(window: Duration, max: usize) -> Self {
        Self {
            hits: std::collections::VecDeque::new(),
            window,
            max,
        }
    }

    /// Record an attempt; returns false (without recording) if the window is
    /// already saturated.
    fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        while let Some(front) = self.hits.front() {
            if now.duration_since(*front) > self.window {
                self.hits.pop_front();
            } else {
                break;
            }
        }
        if self.hits.len() >= self.max {
            return false;
        }
        self.hits.push_back(now);
        true
    }
}

async fn handle_request_upload(
    state: &AppState,
    me: &AccountRecord,
    request_id: Uuid,
    room_id: &str,
    byte_size: i64,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let (store, r2) = match (state.store.as_ref(), state.r2.as_ref()) {
        (Some(s), Some(r)) => (s, r),
        _ => {
            send_error(tx, error_codes::R2_UNAVAILABLE, "");
            return;
        }
    };
    // KNOWN GAP: this only rejects an *honestly-declared* oversize. The
    // rusty-s3 query-signed PUT URL does not pin Content-Length, so a client
    // can declare a small byte_size here and then PUT an arbitrarily large body
    // to the presigned URL — R2 stores whatever arrives. A real bound needs a
    // signed Content-Length condition or a POST policy (awkward with rusty-s3).
    // Until then MAX_ATTACHMENT_BYTES is advisory, not enforced. Tracked as a
    // follow-up alongside the orphan reaper / upload quota below.
    if byte_size <= 0 || byte_size > MAX_ATTACHMENT_BYTES {
        send_error(tx, error_codes::BLOB_TOO_LARGE, "");
        return;
    }
    match is_member(store.pool(), room_id, me.id).await {
        Ok(true) => {}
        Ok(false) => {
            send_error(tx, error_codes::UNKNOWN_ROOM, "");
            return;
        }
        Err(e) => {
            warn!("is_member (upload): {e}");
            send_error(tx, "Internal", "");
            return;
        }
    }
    // KNOWN GAP: each RequestUpload inserts an `attachments` row (committed =
    // false, never flipped yet) and mints a presigned PUT. The per-connection
    // UploadRateLimiter (see caller) bounds the rate, but there is still no
    // storage quota and the orphan reaper is deferred, so uncommitted rows +
    // uploaded objects accumulate until a reaper exists. Blast radius is
    // authenticated couple-room users only. Follow-up: ship the reaper.
    let blob_key = Ulid::new().to_string();
    if let Err(e) = insert_attachment(store.pool(), &blob_key, room_id, me.id, byte_size).await {
        warn!("insert_attachment: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    let url = r2.presign_put(&blob_key, PRESIGN_TTL);
    let _ = tx.send(RoomServerFrame::UploadGranted {
        request_id,
        blob_key,
        url,
        expires_at: Utc::now() + chrono::Duration::from_std(PRESIGN_TTL).unwrap(),
    });
}

async fn handle_request_download(
    state: &AppState,
    me: &AccountRecord,
    blob_key: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let (store, r2) = match (state.store.as_ref(), state.r2.as_ref()) {
        (Some(s), Some(r)) => (s, r),
        _ => {
            send_error(tx, error_codes::R2_UNAVAILABLE, "");
            return;
        }
    };
    let room_id = match attachment_room(store.pool(), blob_key).await {
        Ok(Some(r)) => r,
        Ok(None) => {
            send_error(tx, error_codes::UNKNOWN_BLOB, "");
            return;
        }
        Err(e) => {
            warn!("attachment_room: {e}");
            send_error(tx, "Internal", "");
            return;
        }
    };
    // Authorize: requester must be a member of the blob's room. A non-member
    // gets UNKNOWN_BLOB (not a distinct "forbidden") so blob existence isn't
    // leaked across rooms.
    match is_member(store.pool(), &room_id, me.id).await {
        Ok(true) => {}
        _ => {
            send_error(tx, error_codes::UNKNOWN_BLOB, "");
            return;
        }
    }
    let url = r2.presign_get(blob_key, PRESIGN_TTL);
    let _ = tx.send(RoomServerFrame::DownloadGranted {
        blob_key: blob_key.to_string(),
        url,
        expires_at: Utc::now() + chrono::Duration::from_std(PRESIGN_TTL).unwrap(),
    });
}

async fn handle_create_room(
    state: &AppState,
    me: &AccountRecord,
    name: Option<String>,
    invite_partner: bool,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    let name = name.unwrap_or_default();
    if name.chars().count() > MAX_ROOM_NAME_CHARS {
        send_error(tx, "BadName", "name too long");
        return;
    }

    // If the requester wants the human partner included and they're already
    // paired, seed the room with the partner directly — no invite code, no
    // waiting room. The partner's connected sessions get the RoomCreated
    // push via the per-member fan-out below. We still keep the invite path
    // for the not-yet-paired case (stranger → first-time pairing).
    let auto_partner = if invite_partner {
        match partner_account_id_for(store.pool(), me.id).await {
            Ok(p) => p,
            Err(e) => {
                warn!("partner_account_id_for (create_room): {e}");
                send_error(tx, "Internal", "");
                return;
            }
        }
    } else {
        None
    };

    let room_id =
        match create_room_with_members(store.pool(), me.id, auto_partner, name.clone()).await {
            Ok(id) => id,
            Err(CreateRoomError::Db(e)) => {
                warn!("create_room_with_members: {e}");
                send_error(tx, "Internal", "");
                return;
            }
        };

    // Only mint a pending invite when the requester asked for a human
    // partner AND no existing partner exists. Otherwise (already paired or
    // human-partner not requested) pending_invite is None.
    let pending = if invite_partner && auto_partner.is_none() {
        let (canonical, code, hash) = generate_invite();
        let expires_at = default_expiry(Utc::now());
        if let Err(e) =
            create_invite_record(store.pool(), me.id, &hash, expires_at, Some(&room_id)).await
        {
            warn!("create_invite_record: {e}");
            send_error(tx, "Internal", "");
            return;
        }
        let qr = qr_png_base64(&code).unwrap_or_default();
        let _ = canonical;
        Some(PendingInvite {
            code,
            qr_png_base64: qr,
            expires_at,
        })
    } else {
        None
    };

    let detail = match room_detail(store.pool(), &room_id).await {
        Ok(Some(d)) => d,
        _ => {
            send_error(tx, "Internal", "");
            return;
        }
    };
    let members_wire: Vec<WireMember> = detail
        .members
        .iter()
        .cloned()
        .map(Member::into_wire)
        .collect();
    let frame = RoomServerFrame::RoomCreated {
        room_id: detail.room_id.clone(),
        name: detail.name.clone(),
        members: members_wire,
        pending_invite: pending,
    };
    for m in &detail.members {
        state.routing.deliver(&m.username, frame.clone()).await;
    }
}

async fn handle_rename_room(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    name: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    if !is_member(store.pool(), room_id, me.id)
        .await
        .unwrap_or(false)
    {
        send_error(tx, error_codes::UNKNOWN_ROOM, "");
        return;
    }
    if name.chars().count() > MAX_ROOM_NAME_CHARS {
        send_error(tx, "BadName", "name too long");
        return;
    }
    if let Err(e) = rename_room(store.pool(), room_id, name).await {
        warn!("rename_room: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    let members = members_for_room(store.pool(), room_id)
        .await
        .unwrap_or_default();
    let frame = RoomServerFrame::RoomRenamed {
        room_id: room_id.to_string(),
        name: name.to_string(),
    };
    for m in &members {
        state.routing.deliver(&m.username, frame.clone()).await;
    }
}

async fn handle_leave_room(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            send_error(tx, "Internal", "store unavailable");
            return;
        }
    };
    if !is_member(store.pool(), room_id, me.id)
        .await
        .unwrap_or(false)
    {
        send_error(tx, error_codes::UNKNOWN_ROOM, "");
        return;
    }
    let before = members_for_room(store.pool(), room_id)
        .await
        .unwrap_or_default();
    if let Err(e) = leave_room(store.pool(), room_id, me.id).await {
        warn!("leave_room: {e}");
        send_error(tx, "Internal", "");
        return;
    }
    let frame = RoomServerFrame::MemberLeft {
        room_id: room_id.to_string(),
        username: me.username.clone(),
    };
    for m in &before {
        if m.account_id == me.id {
            continue;
        }
        state.routing.deliver(&m.username, frame.clone()).await;
    }
}

/// Fan a single content-free push out to every registered device of an offline
/// recipient, deleting any token APNs reports as permanently dead.
async fn notify_recipient(
    sender: &Arc<dyn PushSender>,
    store: &Store,
    recipient_account_id: i64,
    room_id: &str,
) {
    let tokens = match tokens_for_account(store.pool(), recipient_account_id).await {
        Ok(t) => t,
        Err(e) => {
            warn!("push: tokens_for_account failed: {e}");
            return;
        }
    };
    // Total unread → the app-icon badge. Best-effort: a count error shouldn't
    // block the notification, so fall back to 0.
    let badge = store
        .unread_count(recipient_account_id)
        .await
        .unwrap_or(0)
        .max(0) as u32;
    for t in tokens {
        let msg = PushMessage {
            token: t.apns_token.clone(),
            environment: t.environment.clone(),
            room_id: room_id.to_string(),
            badge,
            push_type: crate::push::PushKind::Alert,
            call_id: None,
            video: false,
        };
        let outcome = sender.send(&msg).await;
        tracing::debug!(
            "push: sent account={recipient_account_id} env={} badge={badge} outcome={outcome:?}",
            t.environment
        );
        if let SendOutcome::DropToken = outcome {
            if let Err(e) =
                delete_token_value(store.pool(), recipient_account_id, &t.apns_token).await
            {
                warn!("push: delete_token_value failed: {e}");
            }
        }
    }
}

// Tests + the REST preview handler use this; keep it reachable.
#[allow(dead_code)]
fn _ensure_account_id_lookup_is_used() {
    let _ = account_id_by_username;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_rate_limiter_saturates_then_blocks() {
        let mut rl = WindowRateLimiter::new(UPLOAD_RL_WINDOW, UPLOAD_RL_MAX);
        // The first UPLOAD_RL_MAX attempts in a window are allowed…
        for i in 0..UPLOAD_RL_MAX {
            assert!(rl.allow(), "attempt {i} should be allowed");
        }
        // …and the next one is rejected (all within the window, no sleep).
        assert!(!rl.allow(), "attempt past the cap should be blocked");
    }

    #[test]
    fn typing_rate_limiter_saturates_then_blocks() {
        let mut rl = WindowRateLimiter::new(TYPING_RL_WINDOW, TYPING_RL_MAX);
        for i in 0..TYPING_RL_MAX {
            assert!(rl.allow(), "typing frame {i} should be allowed");
        }
        assert!(!rl.allow(), "typing frame past the cap should be blocked");
    }
}
