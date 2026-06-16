use std::collections::{HashMap, HashSet};

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
use crate::invites::{
    create_invite_record, default_expiry, lookup_invite, mark_consumed, qr_png_base64,
    room_for_invite, InviteState,
};
use crate::rooms::{
    account_id_by_username, create_room_with_members, is_member, leave_room,
    list_rooms_for_account, members_for_room, partner_account_id_for, rename_room, room_detail,
    set_partner_link, CreateRoomError, Member, MonogamyError, PairError,
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

const MAX_ROOM_NAME_CHARS: usize = 64;
/// Hard cap on recipients per Send. Rooms with this many addressed peers are
/// well past the product target (a couple in a shared room); the cap is a DoS
/// bound, not a product limit.
const MAX_SEND_RECIPIENTS: usize = 16;
/// Hard cap on per-recipient ciphertext (base64). 64 KiB comfortably fits a
/// long text message plus its envelope; binary attachments aren't in scope
/// yet.
const MAX_BODY_BYTES: usize = 65_536;

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
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

    let outbound = tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            let text = match serde_json::to_string(&frame) {
                Ok(s) => s,
                Err(e) => {
                    warn!("failed to serialize outbound frame: {e}");
                    continue;
                }
            };
            if sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(msg)) = stream.next().await {
        if let Message::Text(text) = msg {
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
                Err(e) => warn!("invalid frame from {}: {e}", me.username),
            }
        }
    }

    state.routing.unregister(&me.username, &tx).await;
    outbound.abort();
    info!(username = %me.username, "client disconnected");
}

fn send_error(tx: &mpsc::UnboundedSender<RoomServerFrame>, code: &str, message: &str) {
    let _ = tx.send(RoomServerFrame::Error {
        code: code.to_string(),
        message: message.to_string(),
    });
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
            client_msg_id: None,
        });
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
            client_msg_id: None,
        };
        state.routing.deliver(&m.username, frame).await;
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
                client_msg_id: Some(client_msg_id),
            };
            state.routing.deliver(&me.username, frame).await;
        }
    }
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

// Tests + the REST preview handler use this; keep it reachable.
#[allow(dead_code)]
fn _ensure_account_id_lookup_is_used() {
    let _ = account_id_by_username;
}
