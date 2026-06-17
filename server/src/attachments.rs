//! DB helpers for the `attachments` ledger (migration 0011). The server records
//! blob → room ownership so it can authorize presigned download URLs. It never
//! stores or sees blob contents or the per-file content key.
use sqlx::PgPool;

pub async fn insert_attachment(
    pool: &PgPool,
    blob_key: &str,
    room_id: &str,
    uploader_account_id: i64,
    byte_size: i64,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO attachments (blob_key, room_id, uploader_account_id, byte_size)
         VALUES ($1, $2, $3, $4)",
    )
    .bind(blob_key)
    .bind(room_id)
    .bind(uploader_account_id)
    .bind(byte_size)
    .execute(pool)
    .await?;
    Ok(())
}

/// The room a blob belongs to, or `None` if no such blob. Used to authorize
/// download: the requester must be a member of this room.
pub async fn attachment_room(pool: &PgPool, blob_key: &str) -> sqlx::Result<Option<String>> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT room_id FROM attachments WHERE blob_key = $1")
            .bind(blob_key)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(r,)| r))
}
