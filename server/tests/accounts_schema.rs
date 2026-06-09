use littlelove_api::store::Store;
use serial_test::serial;

fn db_url() -> String {
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

#[tokio::test]
#[serial]
async fn accounts_table_has_required_columns() {
    let store = Store::connect(&db_url()).await.unwrap();
    let rows: Vec<(String, String, bool)> = sqlx::query_as(
        "SELECT column_name, data_type, is_nullable = 'YES'
         FROM information_schema.columns
         WHERE table_name = 'accounts'
         ORDER BY ordinal_position",
    )
    .fetch_all(store.pool())
    .await
    .unwrap();

    let by_name: std::collections::HashMap<_, _> = rows
        .into_iter()
        .map(|(n, t, nullable)| (n, (t, nullable)))
        .collect();

    let (id_ty, id_null) = by_name.get("id").expect("id column");
    assert_eq!(id_ty, "bigint");
    assert!(!id_null);

    let (uname_ty, uname_null) = by_name.get("username").expect("username column");
    assert_eq!(uname_ty, "text");
    assert!(!uname_null);

    let (ed_ty, ed_null) = by_name.get("ed25519_pub").expect("ed25519_pub column");
    assert_eq!(ed_ty, "bytea");
    assert!(!ed_null);

    let (x_ty, x_null) = by_name.get("x25519_pub").expect("x25519_pub column");
    assert_eq!(x_ty, "bytea");
    assert!(!x_null);

    let (ts_ty, ts_null) = by_name.get("created_at").expect("created_at column");
    assert_eq!(ts_ty, "timestamp with time zone");
    assert!(!ts_null);
}

#[tokio::test]
#[serial]
async fn accounts_username_is_unique() {
    let store = Store::connect(&db_url()).await.unwrap();
    sqlx::query("TRUNCATE TABLE accounts RESTART IDENTITY CASCADE")
        .execute(store.pool())
        .await
        .unwrap();

    sqlx::query("INSERT INTO accounts (username, ed25519_pub, x25519_pub) VALUES ($1, $2, $3)")
        .bind("court")
        .bind(&[0u8; 32][..])
        .bind(&[0u8; 32][..])
        .execute(store.pool())
        .await
        .unwrap();

    let dup =
        sqlx::query("INSERT INTO accounts (username, ed25519_pub, x25519_pub) VALUES ($1, $2, $3)")
            .bind("court")
            .bind(&[1u8; 32][..])
            .bind(&[1u8; 32][..])
            .execute(store.pool())
            .await;
    assert!(
        dup.is_err(),
        "duplicate username must violate unique constraint"
    );
}
