//! Monogamy enforcement on the `room_members.account_id` unique index
//! (migration 0004). Spec §4.2: "An account can be in at most one
//! couples-room."

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, sign_invite_consume_b64,
    spawn_server,
};

#[file_serial(db)]
#[tokio::test]
async fn consume_invite_from_already_paired_consumer_returns_already_paired() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    let third_sk = SigningKey::from_bytes(&[3u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    insert_account(&store, "third", &third_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    // 1. court + kaitlyn pair successfully.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    court
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code = next_frame(&mut court).await["code"]
        .as_str()
        .unwrap()
        .to_string();
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&kaitlyn_sk, &canonical);
    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let consumed = next_frame(&mut kaitlyn).await;
    assert_eq!(consumed["kind"], "InviteConsumed");
    let _ = next_frame(&mut court).await; // Court's RoomCreated

    // 2. third creates an invite.
    let mut third = handshake_as(addr, "third", &third_sk).await;
    drain_rooms(&mut third).await;
    third
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code2 = next_frame(&mut third).await["code"]
        .as_str()
        .unwrap()
        .to_string();

    // 3. kaitlyn (already paired) tries to consume third's invite.
    let canonical2 = littlelove_api::invites::decode_code(&code2).unwrap();
    let sig2 = sign_invite_consume_b64(&kaitlyn_sk, &canonical2);
    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code2,
                "signature_over_token": sig2,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut kaitlyn).await;
    assert_eq!(frame["kind"], "Error");
    // v0.3: already-paired humans get a MonogamyViolation when trying to
    // partner with someone who isn't their existing partner.
    assert_eq!(frame["code"], "MonogamyViolation");
}

/// Critical property: when the consumer is already paired (the partner-link
/// step fails), the invite must remain pending — not silently marked
/// consumed. The reviewer flagged that the prior version of ConsumeInvite
/// swallowed set_partner_link errors and called mark_consumed anyway, which
/// would burn the invite without recording the pairing on either side.
#[file_serial(db)]
#[tokio::test]
async fn consume_invite_failing_monogamy_does_not_consume_the_invite() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    let third_sk = SigningKey::from_bytes(&[3u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    insert_account(&store, "third", &third_sk.verifying_key()).await;
    let pool = store.pool().clone();
    let addr = spawn_server(Some(store)).await;

    // 1. court + kaitlyn pair.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    court
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code = next_frame(&mut court).await["code"]
        .as_str()
        .unwrap()
        .to_string();
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&kaitlyn_sk, &canonical);
    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let _ = next_frame(&mut kaitlyn).await;
    let _ = next_frame(&mut court).await;

    // 2. third creates an invite.
    let mut third = handshake_as(addr, "third", &third_sk).await;
    drain_rooms(&mut third).await;
    third
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code2 = next_frame(&mut third).await["code"]
        .as_str()
        .unwrap()
        .to_string();

    // 3. kaitlyn (already paired with court) tries to consume third's invite.
    //    The atomic set_partner_link inside the consume handler must reject
    //    this AND leave third's invite available for someone else.
    let canonical2 = littlelove_api::invites::decode_code(&code2).unwrap();
    let sig2 = sign_invite_consume_b64(&kaitlyn_sk, &canonical2);
    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code2,
                "signature_over_token": sig2,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut kaitlyn).await;
    assert_eq!(frame["kind"], "Error");
    assert_eq!(frame["code"], "MonogamyViolation");

    // 4. Third's invite must STILL be pending — not consumed.
    let token_hash = littlelove_api::invites::sha256(&canonical2);
    let (consumed_at,): (Option<chrono::DateTime<chrono::Utc>>,) =
        sqlx::query_as("SELECT consumed_at FROM invites WHERE token_hash = $1")
            .bind(token_hash)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(
        consumed_at.is_none(),
        "invite must remain pending when partner-link fails, got consumed_at = {consumed_at:?}"
    );
}

#[file_serial(db)]
#[tokio::test]
async fn consuming_own_invite_returns_already_paired() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    court
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code = next_frame(&mut court).await["code"]
        .as_str()
        .unwrap()
        .to_string();
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&court_sk, &canonical);
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut court).await;
    assert_eq!(frame["kind"], "Error");
    assert_eq!(frame["code"], "AlreadyPaired");
}
