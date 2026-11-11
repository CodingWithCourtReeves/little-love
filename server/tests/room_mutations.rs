//! Room mutation helpers: create / rename / leave / delete.

mod common;

use futures::future::join_all;
use littlelove_api::rooms::{
    create_room_with_members, delete_room, delete_room_unless_last, leave_room, rename_room,
    room_detail, DeleteRoomOutcome,
};

/// Rows referencing `room_id` in `table`.
async fn count_for_room(store: &littlelove_api::store::Store, table: &str, room_id: &str) -> i64 {
    let sql = format!("SELECT COUNT(*) FROM {table} WHERE room_id = $1");
    let (n,): (i64,) = sqlx::query_as(&sql)
        .bind(room_id)
        .fetch_one(store.pool())
        .await
        .unwrap();
    n
}

#[tokio::test]
#[serial_test::serial]
async fn delete_room_removes_room_with_messages_attachments_and_members() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;
    let room = create_room_with_members(store.pool(), court, Some(kait), "Travel".into())
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO messages (id, room_id, from_account_id, recipient_account_id, body, ts)
         VALUES ('01MSG', $1, $2, $3, 'ciphertext', now())",
    )
    .bind(&room)
    .bind(court)
    .bind(kait)
    .execute(store.pool())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO attachments (blob_key, room_id, uploader_account_id, byte_size)
         VALUES ('blob-1', $1, $2, 10)",
    )
    .bind(&room)
    .bind(court)
    .execute(store.pool())
    .await
    .unwrap();

    assert!(delete_room(store.pool(), &room).await.unwrap());

    assert!(room_detail(store.pool(), &room).await.unwrap().is_none());
    for table in ["room_members", "messages", "attachments"] {
        assert_eq!(count_for_room(&store, table, &room).await, 0, "{table}");
    }
}

#[tokio::test]
#[serial_test::serial]
async fn delete_room_on_missing_room_returns_false() {
    let _store = common::fresh_store().await;
    assert!(!delete_room(_store.pool(), "01NOPE").await.unwrap());
}

#[tokio::test]
#[serial_test::serial]
async fn delete_room_unless_last_refuses_the_last_room_and_misses_a_missing_one() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;
    let a = create_room_with_members(store.pool(), court, Some(kait), "A".into())
        .await
        .unwrap();
    let b = create_room_with_members(store.pool(), court, Some(kait), "B".into())
        .await
        .unwrap();

    let pool = store.pool();
    assert_eq!(
        delete_room_unless_last(pool, &a, court).await.unwrap(),
        DeleteRoomOutcome::Deleted
    );
    assert_eq!(
        delete_room_unless_last(pool, &b, kait).await.unwrap(),
        DeleteRoomOutcome::LastRoom
    );
    assert!(room_detail(pool, &b).await.unwrap().is_some());
    assert_eq!(
        delete_room_unless_last(pool, "01NOPE", court)
            .await
            .unwrap(),
        DeleteRoomOutcome::NotFound
    );
}

/// Both partners deleting a different one of their last two rooms at once:
/// the last-room check and the delete are one locked step, so exactly one
/// delete wins and the couple keeps a room.
#[tokio::test]
#[serial_test::serial]
async fn parallel_deletes_of_the_last_two_rooms_leave_one() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;
    for _ in 0..20 {
        let a = create_room_with_members(store.pool(), court, Some(kait), "A".into())
            .await
            .unwrap();
        let b = create_room_with_members(store.pool(), court, Some(kait), "B".into())
            .await
            .unwrap();
        let (p1, p2) = (store.pool().clone(), store.pool().clone());
        let (ra, rb) = (a.clone(), b.clone());
        let results = join_all([
            tokio::spawn(async move { delete_room_unless_last(&p1, &ra, court).await }),
            tokio::spawn(async move { delete_room_unless_last(&p2, &rb, kait).await }),
        ])
        .await;
        let outcomes: Vec<_> = results.into_iter().map(|r| r.unwrap().unwrap()).collect();
        let deleted = outcomes
            .iter()
            .filter(|o| **o == DeleteRoomOutcome::Deleted)
            .count();
        assert_eq!(deleted, 1, "{outcomes:?}");
        let (rooms,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM room_members WHERE account_id = $1")
                .bind(court)
                .fetch_one(store.pool())
                .await
                .unwrap();
        assert_eq!(rooms, 1);
        // Reset for the next round: drop the survivor directly.
        for r in [&a, &b] {
            delete_room(store.pool(), r).await.unwrap();
        }
    }
}

/// A message insert in another room holds `FOR KEY SHARE` on its sender's
/// account row (the `from_account_id` FK check) until it commits. The delete's
/// account lock must not wait on it: a full `FOR UPDATE` would, and with the
/// insert also holding the room row the two deadlock.
#[tokio::test]
#[serial_test::serial]
async fn delete_room_unless_last_does_not_wait_on_a_message_insert() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;
    let keep = create_room_with_members(store.pool(), court, Some(kait), "Keep".into())
        .await
        .unwrap();
    let doomed = create_room_with_members(store.pool(), court, Some(kait), "Doomed".into())
        .await
        .unwrap();

    let mut sending = store.pool().begin().await.unwrap();
    sqlx::query(
        "INSERT INTO messages (id, room_id, from_account_id, recipient_account_id, body, ts)
         VALUES ('01MSG', $1, $2, $3, 'ciphertext', now())",
    )
    .bind(&keep)
    .bind(court)
    .bind(kait)
    .execute(&mut *sending)
    .await
    .unwrap();

    let outcome = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        delete_room_unless_last(store.pool(), &doomed, court),
    )
    .await
    .expect("delete waited on the open message insert")
    .unwrap();
    assert_eq!(outcome, DeleteRoomOutcome::Deleted);
    sending.commit().await.unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn create_room_with_two_humans() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;

    let room = create_room_with_members(store.pool(), court, Some(kait), "Garden".into())
        .await
        .unwrap();

    let detail = room_detail(store.pool(), &room).await.unwrap().unwrap();
    assert_eq!(detail.name, "Garden");
    assert_eq!(detail.members.len(), 2);
}

#[tokio::test]
#[serial_test::serial]
async fn rename_room_changes_name() {
    let store = common::fresh_store().await;
    let (court, kait) = common::seed_two_humans(&store).await;
    let room = create_room_with_members(store.pool(), court, Some(kait), "Garden".into())
        .await
        .unwrap();

    rename_room(store.pool(), &room, "Garden 🌿").await.unwrap();

    let detail = room_detail(store.pool(), &room).await.unwrap().unwrap();
    assert_eq!(detail.name, "Garden 🌿");
}

#[tokio::test]
#[serial_test::serial]
async fn leave_room_removes_member_and_cascades_when_last_member_leaves() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;
    let room = create_room_with_members(store.pool(), court, None, "Solo".into())
        .await
        .unwrap();

    let outcome = leave_room(store.pool(), &room, court).await.unwrap();
    assert!(
        outcome.room_deleted,
        "last member left → room cascade-deleted"
    );
    assert!(room_detail(store.pool(), &room).await.unwrap().is_none());
}

#[tokio::test]
#[serial_test::serial]
async fn leave_room_keeps_room_when_other_member_remains() {
    let store = common::fresh_store().await;
    let (court, kait, _riley, room) = common::seed_trio_room(&store).await;

    let outcome = leave_room(store.pool(), &room, court).await.unwrap();
    assert!(!outcome.room_deleted);

    let detail = room_detail(store.pool(), &room).await.unwrap().unwrap();
    assert!(detail.members.iter().any(|m| m.username == "kaitlyn"));
    assert!(!detail.members.iter().any(|m| m.username == "court"));
    let _ = kait;
}
