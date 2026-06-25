//! Store-level read receipts: mark_read flips the partner's rows and reports
//! the flipped (id, sender) pairs; replay surfaces read state on the sender's
//! self-copy.

mod common;

use littlelove_api::store::MessageRow;

/// Insert one logical message court -> kaitlyn: the partner's recipient row
/// plus court's own self-copy, sharing one id.
async fn send_one(
    store: &littlelove_api::store::Store,
    id: &str,
    room: &str,
    court: i64,
    kait: i64,
) {
    for (rcpt, body) in [(kait, "to_kait"), (court, "self_copy")] {
        store
            .insert(MessageRow {
                id: id.to_string(),
                room_id: room.to_string(),
                from_account_id: court,
                recipient_account_id: rcpt,
                body: body.into(),
                ts: chrono::Utc::now(),
                read: false,
            })
            .await
            .unwrap();
    }
}

#[tokio::test]
#[serial_test::serial]
async fn mark_read_flips_partner_rows_and_reports_senders() {
    let store = common::fresh_store().await;
    let (court, kait, room) = common::seed_couple_room(&store).await;

    let id1 = "01J000000000000000000000AA".to_string();
    let id2 = "01J000000000000000000000BB".to_string();
    send_one(&store, &id1, &room, court, kait).await;
    send_one(&store, &id2, &room, court, kait).await;

    // Kaitlyn opens the chat, having seen everything up to id2.
    let flipped = store.mark_read(&room, kait, &id2).await.unwrap();

    // Both of court's messages flipped, each attributed to court.
    assert_eq!(flipped.len(), 2);
    assert!(flipped.iter().all(|(_, from)| *from == court));
    let mut ids: Vec<&str> = flipped.iter().map(|(id, _)| id.as_str()).collect();
    ids.sort();
    assert_eq!(ids, vec![id1.as_str(), id2.as_str()]);

    // Re-running is idempotent: nothing left unread to flip.
    let again = store.mark_read(&room, kait, &id2).await.unwrap();
    assert!(again.is_empty(), "second mark_read should flip nothing");
}

#[tokio::test]
#[serial_test::serial]
async fn read_sent_message_ids_lists_only_partner_read_ids() {
    let store = common::fresh_store().await;
    let (court, kait, room) = common::seed_couple_room(&store).await;

    let id1 = "01J000000000000000000000AA".to_string();
    let id2 = "01J000000000000000000000BB".to_string();
    send_one(&store, &id1, &room, court, kait).await;
    send_one(&store, &id2, &room, court, kait).await;

    // Nothing read yet → nothing to backfill.
    assert!(
        store
            .read_sent_message_ids(&room, court)
            .await
            .unwrap()
            .is_empty(),
        "no ids before the partner reads anything"
    );

    // Kaitlyn reads up to id1 only.
    store.mark_read(&room, kait, &id1).await.unwrap();
    assert_eq!(
        store.read_sent_message_ids(&room, court).await.unwrap(),
        vec![id1.clone()],
        "only the read message is reported, ascending"
    );

    // She catches up to id2; both are now reported.
    store.mark_read(&room, kait, &id2).await.unwrap();
    assert_eq!(
        store.read_sent_message_ids(&room, court).await.unwrap(),
        vec![id1, id2],
    );

    // The reader sees no backfill for her own (partner-authored) messages.
    assert!(
        store
            .read_sent_message_ids(&room, kait)
            .await
            .unwrap()
            .is_empty(),
        "read_sent_message_ids is scoped to the caller's own sent messages"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn replay_reports_read_state_on_senders_self_copy() {
    let store = common::fresh_store().await;
    let (court, kait, room) = common::seed_couple_room(&store).await;

    let id = "01J000000000000000000000AA".to_string();
    send_one(&store, &id, &room, court, kait).await;

    // Before the partner reads: court's self-copy replays as unread.
    let before = store
        .messages_for_recipient(&room, court, None)
        .await
        .unwrap();
    assert_eq!(before.len(), 1);
    assert!(!before[0].read, "should be unread before mark_read");

    store.mark_read(&room, kait, &id).await.unwrap();

    // After: court's self-copy replays as read.
    let after = store
        .messages_for_recipient(&room, court, None)
        .await
        .unwrap();
    assert_eq!(after.len(), 1);
    assert!(after[0].read, "should be read after partner mark_read");
}
