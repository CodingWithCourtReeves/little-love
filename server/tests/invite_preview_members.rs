//! POST /invites/{code}/preview returns the full room roster (spec §8.1).

mod common;

#[tokio::test]
#[serial_test::serial]
async fn invite_preview_returns_room_roster() {
    let store = common::fresh_store().await;

    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let pool = store.pool().clone();
    let addr = common::spawn_server(Some(store)).await;

    // Seed a room hosted by court + an invite tied to that room. A joining
    // partner previews the roster before consuming.
    let (court_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'court'")
        .fetch_one(&pool)
        .await
        .unwrap();
    let room_id =
        littlelove_api::rooms::create_room_with_members(&pool, court_id, None, "Travel".into())
            .await
            .unwrap();

    let (canonical, code, hash) = littlelove_crypto::invite::generate_invite();
    let expires_at = littlelove_api::invites::default_expiry(chrono::Utc::now());
    littlelove_api::invites::create_invite_record(&pool, court_id, &hash, expires_at, Some(&room_id))
        .await
        .unwrap();
    let _ = canonical;

    let resp: serde_json::Value = reqwest::Client::new()
        .post(format!("http://{addr}/invites/{code}/preview"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(resp["room_id"].as_str().unwrap(), room_id);
    assert_eq!(resp["name"], "Travel");
    let members = resp["members"].as_array().unwrap();
    assert_eq!(members.len(), 1);
    let usernames: Vec<&str> = members
        .iter()
        .map(|m| m["username"].as_str().unwrap())
        .collect();
    assert!(usernames.contains(&"court"));
}
