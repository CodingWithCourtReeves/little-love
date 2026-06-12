use chrono::{DateTime, Utc};
use sqlx::PgPool;

/// One per-recipient row in the v0.3 `messages` table. The same logical
/// message has N rows (one per recipient) sharing the same `id`/`room_id`/
/// `from_account_id`/`ts`, each with its own addressed `body` ciphertext.
/// Composite PK is `(id, recipient_account_id)`.
#[derive(Debug, Clone)]
pub struct MessageRow {
    pub id: String,
    pub room_id: String,
    pub from_account_id: i64,
    pub recipient_account_id: i64,
    pub body: String,
    pub ts: DateTime<Utc>,
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
}

type MessageDbRow = (String, String, i64, i64, String, DateTime<Utc>);

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
            "INSERT INTO messages (id, room_id, from_account_id, recipient_account_id, body, ts)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (id, recipient_account_id) DO NOTHING",
        )
        .bind(&row.id)
        .bind(&row.room_id)
        .bind(row.from_account_id)
        .bind(row.recipient_account_id)
        .bind(&row.body)
        .bind(row.ts)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Atomically insert all per-recipient rows for one logical Send. Either
    /// every recipient lands or none do — without this, a mid-loop failure
    /// would leave earlier recipients with a row the sender thinks failed
    /// (sender 500s and retries → duplicates for earlier recipients, nothing
    /// for later ones).
    pub async fn insert_many(&self, rows: &[MessageRow]) -> anyhow::Result<()> {
        let mut tx = self.pool.begin().await?;
        for row in rows {
            sqlx::query(
                "INSERT INTO messages (id, room_id, from_account_id, recipient_account_id, body, ts)
                 VALUES ($1, $2, $3, $4, $5, $6)
                 ON CONFLICT (id, recipient_account_id) DO NOTHING",
            )
            .bind(&row.id)
            .bind(&row.room_id)
            .bind(row.from_account_id)
            .bind(row.recipient_account_id)
            .bind(&row.body)
            .bind(row.ts)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Replay every message in `room_id` addressed to `recipient_account_id`,
    /// after `since_message_id` (exclusive). Ordered by ULID `id ASC` —
    /// ULIDs are monotonic so this is the correct replay order in v0.3.
    ///
    /// Invariant: `since_message_id` (and every stored `id`) is a canonical
    /// 26-char Crockford-base32 ULID — `Ulid::new().to_string()` always emits
    /// uppercase, and we never accept rows from any other source. The `id > $3`
    /// string comparison relies on consistent casing across all historical
    /// rows; if that ever changes (mixed-case ULIDs, externally inserted ids),
    /// the ordering will silently misbehave.
    pub async fn messages_for_recipient(
        &self,
        room_id: &str,
        recipient_account_id: i64,
        since_message_id: Option<&str>,
    ) -> anyhow::Result<Vec<MessageRow>> {
        let rows = if let Some(since) = since_message_id {
            sqlx::query_as::<_, MessageDbRow>(
                "SELECT id, room_id, from_account_id, recipient_account_id, body, ts
                 FROM messages
                 WHERE room_id = $1 AND recipient_account_id = $2 AND id > $3
                 ORDER BY id ASC",
            )
            .bind(room_id)
            .bind(recipient_account_id)
            .bind(since)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as::<_, MessageDbRow>(
                "SELECT id, room_id, from_account_id, recipient_account_id, body, ts
                 FROM messages
                 WHERE room_id = $1 AND recipient_account_id = $2
                 ORDER BY id ASC",
            )
            .bind(room_id)
            .bind(recipient_account_id)
            .fetch_all(&self.pool)
            .await?
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, room_id, from_account_id, recipient_account_id, body, ts)| MessageRow {
                    id,
                    room_id,
                    from_account_id,
                    recipient_account_id,
                    body,
                    ts,
                },
            )
            .collect())
    }
}
