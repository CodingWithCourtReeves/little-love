//! v0.3 store: one row per (message_id, recipient) with per-recipient replay.

mod common;

use littlelove_api::store::MessageRow;

#[tokio::test]
#[serial_test::serial]
async fn insert_and_replay_per_recipient() {
    let store = common::fresh_store().await;
    let (court, kait, riley, room) = common::seed_trio_room(&store).await;

    let ts = chrono::Utc::now();
    let id = ulid::Ulid::new().to_string();
    for (rcpt, body) in [(kait, "b_kait"), (riley, "b_riley")] {
        store
            .insert(MessageRow {
                id: id.clone(),
                room_id: room.clone(),
                from_account_id: court,
                recipient_account_id: rcpt,
                body: body.into(),
                ts,
                read: false,
            })
            .await
            .unwrap();
    }

    let kait_msgs = store
        .messages_for_recipient(&room, kait, None)
        .await
        .unwrap();
    assert_eq!(kait_msgs.len(), 1);
    assert_eq!(kait_msgs[0].body, "b_kait");
    assert_eq!(kait_msgs[0].id, id);

    let riley_msgs = store
        .messages_for_recipient(&room, riley, None)
        .await
        .unwrap();
    assert_eq!(riley_msgs.len(), 1);
    assert_eq!(riley_msgs[0].body, "b_riley");
}

#[tokio::test]
#[serial_test::serial]
async fn since_message_id_skips_replay_at_or_before() {
    let store = common::fresh_store().await;
    let (court, kait, _riley, room) = common::seed_trio_room(&store).await;

    let ts = chrono::Utc::now();
    // Hand-rolled, strictly-ordered ULID strings — two calls to Ulid::new() in
    // the same millisecond aren't guaranteed lexicographically monotonic.
    let id1 = "01J000000000000000000000AA".to_string();
    let id2 = "01J000000000000000000000BB".to_string();
    for (id, body) in [(&id1, "first"), (&id2, "second")] {
        store
            .insert(MessageRow {
                id: id.clone(),
                room_id: room.clone(),
                from_account_id: court,
                recipient_account_id: kait,
                body: body.into(),
                ts,
                read: false,
            })
            .await
            .unwrap();
    }

    let msgs = store
        .messages_for_recipient(&room, kait, Some(&id1))
        .await
        .unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].body, "second");
}
