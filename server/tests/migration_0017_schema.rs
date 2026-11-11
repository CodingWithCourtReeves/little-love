//! Migration 0017: messages cascade with their room, so DeleteRoom can remove
//! a channel that has messages.

use serial_test::file_serial;

mod common;

#[file_serial(db)]
#[tokio::test]
async fn messages_room_id_fk_cascades_on_delete() {
    let store = common::fresh_store().await;
    let (rule,): (String,) = sqlx::query_as(
        "SELECT delete_rule FROM information_schema.referential_constraints
         WHERE constraint_name = 'messages_room_id_fkey'",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!(rule, "CASCADE");
}
