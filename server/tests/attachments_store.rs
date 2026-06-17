mod common;

use littlelove_api::attachments::{attachment_room, insert_attachment};

#[tokio::test]
#[serial_test::serial]
async fn insert_then_lookup_room() {
    let store = common::fresh_store().await;
    let (_court, _kait, _riley, room_id) = common::seed_trio_room(&store).await;
    let uploader = littlelove_api::rooms::account_id_by_username(store.pool(), "court")
        .await
        .unwrap()
        .unwrap();

    insert_attachment(store.pool(), "01JBLOBKEY", &room_id, uploader, 1234)
        .await
        .unwrap();

    let found = attachment_room(store.pool(), "01JBLOBKEY").await.unwrap();
    assert_eq!(found.as_deref(), Some(room_id.as_str()));
    assert!(attachment_room(store.pool(), "missing")
        .await
        .unwrap()
        .is_none());
}
