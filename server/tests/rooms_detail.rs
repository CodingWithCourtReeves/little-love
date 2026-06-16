//! `RoomDetail` carries the multi-member roster + room name.

mod common;

use std::collections::HashSet;

use littlelove_api::rooms::{members_for_room, room_detail};

#[tokio::test]
#[serial_test::serial]
async fn members_for_room_returns_full_roster() {
    let store = common::fresh_store().await;
    let (court, kait, riley, room) = common::seed_trio_room(&store).await;

    let members = members_for_room(store.pool(), &room).await.unwrap();
    assert_eq!(members.len(), 3);

    let usernames: HashSet<String> = members.iter().map(|m| m.username.clone()).collect();
    let expected: HashSet<String> = ["court", "kaitlyn", "riley"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(usernames, expected);

    let detail = room_detail(store.pool(), &room).await.unwrap().unwrap();
    assert_eq!(detail.members.len(), 3);
    assert_eq!(detail.room_id, room);

    let _ = (court, kait, riley);
}
