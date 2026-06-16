//! Room mutation helpers: create / rename / leave.

mod common;

use littlelove_api::rooms::{create_room_with_members, leave_room, rename_room, room_detail};

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
