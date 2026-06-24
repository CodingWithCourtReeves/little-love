use serial_test::file_serial;

mod common;
use common::fresh_store;

use ed25519_dalek::SigningKey;
use littlelove_api::accounts::{last_seen_for, touch_last_seen};
use littlelove_api::rooms::account_id_by_username;

#[tokio::test]
#[file_serial(db)]
async fn touch_and_read_last_seen() {
    let store = fresh_store().await;
    let pool = store.pool();

    let sk = SigningKey::from_bytes(&[7u8; 32]);
    common::insert_account(&store, "court", &sk.verifying_key()).await;
    let id = account_id_by_username(pool, "court")
        .await
        .unwrap()
        .expect("account exists");

    // No session yet → null.
    assert!(last_seen_for(pool, id).await.unwrap().is_none());

    touch_last_seen(pool, id).await.unwrap();
    let t1 = last_seen_for(pool, id).await.unwrap().expect("stamped");

    touch_last_seen(pool, id).await.unwrap();
    let t2 = last_seen_for(pool, id).await.unwrap().unwrap();
    assert!(t2 >= t1, "second touch is not earlier than the first");
}
