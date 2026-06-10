use chrono::{DateTime, Utc};
use sqlx::PgPool;

/// A row in the `messages` table after spec §8.4 migration 0005. The Day-1
/// `from_user` / `to_user` text columns are gone; routing happens by
/// `room_id` and the sender's `from_account_id` is the authenticated
/// identity (FK → `accounts.id`).
#[derive(Debug, Clone)]
pub struct MessageRow {
    /// ULID as text. Used as the wire-level `id` field.
    pub id: String,
    pub room_id: String,
    pub from_account_id: i64,
    pub body: String,
    pub ts: DateTime<Utc>,
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
}

impl Store {
    pub async fn connect(database_url: &str) -> anyhow::Result<Self> {
        let pool = PgPool::connect(database_url).await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn insert(&self, row: MessageRow) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO messages (id, room_id, from_account_id, body, ts)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(&row.id)
        .bind(&row.room_id)
        .bind(row.from_account_id)
        .bind(&row.body)
        .bind(row.ts)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Replay every message in `room_id` after `since_message_id` (exclusive),
    /// ordered by ts ascending. Pass `None` to replay the whole room.
    pub async fn messages_for_room(
        &self,
        room_id: &str,
        since_message_id: Option<&str>,
    ) -> anyhow::Result<Vec<MessageRow>> {
        let rows = if let Some(since) = since_message_id {
            sqlx::query_as::<_, (String, String, i64, String, DateTime<Utc>)>(
                "SELECT m.id, m.room_id, m.from_account_id, m.body, m.ts
                 FROM messages m
                 WHERE m.room_id = $1
                   AND m.ts > (SELECT ts FROM messages WHERE id = $2)
                 ORDER BY m.ts ASC",
            )
            .bind(room_id)
            .bind(since)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as::<_, (String, String, i64, String, DateTime<Utc>)>(
                "SELECT id, room_id, from_account_id, body, ts
                 FROM messages
                 WHERE room_id = $1
                 ORDER BY ts ASC",
            )
            .bind(room_id)
            .fetch_all(&self.pool)
            .await?
        };
        Ok(rows
            .into_iter()
            .map(|(id, room_id, from_account_id, body, ts)| MessageRow {
                id,
                room_id,
                from_account_id,
                body,
                ts,
            })
            .collect())
    }
}
