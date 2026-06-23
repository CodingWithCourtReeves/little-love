//! Store-level device push token CRUD: upsert is idempotent per (account,
//! device) and updates the token; delete removes it; load returns a couple's
//! own tokens only.

mod common;

use littlelove_api::push_tokens::{
    delete_token, delete_token_value, tokens_for_account, upsert_token, voip_tokens_for,
    KIND_ALERT, KIND_VOIP,
};

#[tokio::test]
#[serial_test::serial]
async fn upsert_is_idempotent_and_updates_token() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;

    upsert_token(store.pool(), court, "dev-1", "tokenAAAA", "sandbox", KIND_ALERT)
        .await
        .unwrap();
    // Re-register same device with a refreshed token: still one row, new value.
    upsert_token(store.pool(), court, "dev-1", "tokenBBBB", "production", KIND_ALERT)
        .await
        .unwrap();

    let tokens = tokens_for_account(store.pool(), court).await.unwrap();
    assert_eq!(tokens.len(), 1, "one row per (account, device)");
    assert_eq!(tokens[0].apns_token, "tokenBBBB");
    assert_eq!(tokens[0].environment, "production");
}

#[tokio::test]
#[serial_test::serial]
async fn delete_by_device_and_by_value() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;

    upsert_token(store.pool(), court, "dev-1", "tokAAA", "sandbox", KIND_ALERT)
        .await
        .unwrap();
    upsert_token(store.pool(), court, "dev-2", "tokBBB", "sandbox", KIND_ALERT)
        .await
        .unwrap();

    delete_token(store.pool(), court, "dev-1").await.unwrap();
    let after = tokens_for_account(store.pool(), court).await.unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].apns_token, "tokBBB");

    // Token-hygiene path: delete by the token value (device id unknown to APNs).
    delete_token_value(store.pool(), court, "tokBBB")
        .await
        .unwrap();
    assert!(tokens_for_account(store.pool(), court)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
#[serial_test::serial]
async fn alert_and_voip_tokens_coexist_per_device() {
    let store = common::fresh_store().await;
    let (court, _kait) = common::seed_two_humans(&store).await;

    // The same device registers both an alert and a voip token (distinct rows).
    upsert_token(store.pool(), court, "dev-1", "alertTOK", "sandbox", KIND_ALERT)
        .await
        .unwrap();
    upsert_token(store.pool(), court, "dev-1", "voipTOK", "sandbox", KIND_VOIP)
        .await
        .unwrap();

    // The alert path sees only the alert token...
    let alert = tokens_for_account(store.pool(), court).await.unwrap();
    assert_eq!(alert.len(), 1);
    assert_eq!(alert[0].apns_token, "alertTOK");

    // ...and the voip path sees only the voip token.
    let voip = voip_tokens_for(store.pool(), court).await.unwrap();
    assert_eq!(voip.len(), 1);
    assert_eq!(voip[0].apns_token, "voipTOK");
}
