//! Dev-only seed tool for the two-simulator test harness
//! (scripts/sim-couple.sh). Creates + pairs the `court`/`kaitlyn` couple and
//! their shared room directly in the **local dev** Postgres, reusing the exact
//! store functions the integration tests use. Idempotent.
//!
//! SECURITY: this binary is gated behind the `dev-seed` cargo feature
//! (`required-features` in Cargo.toml), so it is NOT compiled into the default /
//! release build — the production `littlelove-api` artifact contains none of
//! this code, and there is no HTTP route to reach it. As defence-in-depth it
//! also refuses to run against any `DATABASE_URL` that isn't localhost.
//!
//! Run via the harness:
//!   cargo run -p littlelove-api --features dev-seed --bin seed_couple -- <fixture.json>

use std::collections::HashMap;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use littlelove_api::rooms::{create_room_with_members, set_partner_link};
use serde::Deserialize;
use sqlx::postgres::PgPoolOptions;
use sqlx::Row;

#[derive(Deserialize)]
struct FixtureEntry {
    ed25519_pub: String,
    x25519_pub: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let db_url =
        std::env::var("DATABASE_URL").map_err(|_| anyhow::anyhow!("DATABASE_URL is required"))?;
    // Defence-in-depth: never touch a non-local database.
    if !(db_url.contains("127.0.0.1") || db_url.contains("localhost")) {
        anyhow::bail!("refusing to seed: DATABASE_URL is not localhost ({db_url})");
    }

    let fixture_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "scripts/dev-couple.json".to_string());
    let raw = std::fs::read_to_string(&fixture_path)
        .map_err(|e| anyhow::anyhow!("reading {fixture_path}: {e}"))?;
    let fixture: HashMap<String, FixtureEntry> = serde_json::from_str(&raw)?;

    let pool = PgPoolOptions::new().connect(&db_url).await?;

    // Upsert both accounts with the fixture pubkeys (update keys on conflict so a
    // regenerated fixture re-syncs), collecting their ids.
    let mut ids: HashMap<String, i64> = HashMap::new();
    for username in ["court", "kaitlyn"] {
        let entry = fixture
            .get(username)
            .ok_or_else(|| anyhow::anyhow!("fixture missing user {username}"))?;
        let ed = decode_pubkey(&entry.ed25519_pub)?;
        let x = decode_pubkey(&entry.x25519_pub)?;
        let row = sqlx::query(
            "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
             VALUES ($1, $2, $3)
             ON CONFLICT (username)
               DO UPDATE SET ed25519_pub = EXCLUDED.ed25519_pub,
                             x25519_pub  = EXCLUDED.x25519_pub
             RETURNING id",
        )
        .bind(username)
        .bind(&ed)
        .bind(&x)
        .fetch_one(&pool)
        .await?;
        ids.insert(username.to_string(), row.get::<i64, _>("id"));
    }
    let court = ids["court"];
    let kaitlyn = ids["kaitlyn"];

    // Pair them (idempotent; no-op if already linked to each other).
    set_partner_link(&pool, court, kaitlyn).await?;

    // Create the couple room only if they don't already share one.
    let existing: Option<(String,)> = sqlx::query_as(
        "SELECT room_id FROM room_members
         WHERE account_id IN ($1, $2)
         GROUP BY room_id
         HAVING count(DISTINCT account_id) = 2
         LIMIT 1",
    )
    .bind(court)
    .bind(kaitlyn)
    .fetch_optional(&pool)
    .await?;

    let room_id = match existing {
        Some((id,)) => {
            println!("✓ couple already paired; reusing room {id}");
            id
        }
        None => {
            // Unnamed room = the partner DM (RoomShape.partner on the client).
            let id = create_room_with_members(&pool, court, Some(kaitlyn), String::new()).await?;
            println!("✓ created couple room {id}");
            id
        }
    };

    println!("✓ seeded: court(id={court}) <-> kaitlyn(id={kaitlyn}) in room {room_id}");
    Ok(())
}

fn decode_pubkey(s: &str) -> anyhow::Result<Vec<u8>> {
    let bytes = B64.decode(s)?;
    anyhow::ensure!(
        bytes.len() == 32,
        "pubkey must be 32 bytes, got {}",
        bytes.len()
    );
    Ok(bytes)
}
