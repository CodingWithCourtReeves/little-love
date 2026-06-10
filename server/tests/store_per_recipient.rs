//! v0.3 store: one row per (message_id, recipient) with per-recipient replay.

mod common;

use littlelove_api::store::MessageRow;

#[tokio::test]
#[serial_test::serial]
async fn insert_and_replay_per_recipient() {
    let store = common::fresh_store().await;
    let (court, kait, garden, room) = common::seed_couple_plus_bot(&store).await;

    let ts = chrono::Utc::now();
    let id = ulid::Ulid::new().to_string();
    for (rcpt, body) in [(kait, "b_kait"), (garden, "b_garden")] {
        store
            .insert(MessageRow {
                id: id.clone(),
                room_id: room.clone(),
                from_account_id: court,
                recipient_account_id: rcpt,
                body: body.into(),
                ts,
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

    let garden_msgs = store
        .messages_for_recipient(&room, garden, None)
        .await
        .unwrap();
    assert_eq!(garden_msgs.len(), 1);
    assert_eq!(garden_msgs[0].body, "b_garden");
}

#[tokio::test]
#[serial_test::serial]
async fn since_message_id_skips_replay_at_or_before() {
    let store = common::fresh_store().await;
    let (court, kait, _garden, room) = common::seed_couple_plus_bot(&store).await;

    let ts = chrono::Utc::now();
    let id1 = ulid::Ulid::new().to_string();
    let id2 = ulid::Ulid::new().to_string();
    for (id, body) in [(&id1, "first"), (&id2, "second")] {
        store
            .insert(MessageRow {
                id: id.clone(),
                room_id: room.clone(),
                from_account_id: court,
                recipient_account_id: kait,
                body: body.into(),
                ts,
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
