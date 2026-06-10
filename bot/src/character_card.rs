//! Character Card v2/v3 PNG parser.

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::Deserialize;

const MAX_CARD_JSON: usize = 1 << 20; // 1 MiB

#[derive(Debug, Deserialize)]
pub struct Card {
    pub spec: String,
    pub data: CardData,
}

#[derive(Debug, Deserialize, Default)]
pub struct CardData {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub personality: String,
    #[serde(default)]
    pub scenario: String,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub creator: Option<String>,
    #[serde(default)]
    pub character_version: Option<String>,
}

/// Drop-noted fields: parsed/ignored. We log their presence on the
/// startup line so the operator sees what was silently skipped.
#[derive(Debug, Deserialize, Default)]
struct DropNotes {
    #[serde(default)]
    first_mes: Option<String>,
    #[serde(default)]
    mes_example: Option<String>,
    #[serde(default)]
    alternate_greetings: Option<Vec<String>>,
    #[serde(default)]
    character_book: Option<serde_json::Value>,
    #[serde(default)]
    post_history_instructions: Option<String>,
}

pub fn parse_png(bytes: &[u8]) -> Result<Card> {
    let decoder = png::Decoder::new(bytes);
    let reader = decoder.read_info().context("decode png header")?;
    let info = reader.info();

    let pick = info
        .utf8_text
        .iter()
        .find(|c| c.keyword == "ccv3")
        .or_else(|| info.utf8_text.iter().find(|c| c.keyword == "chara"));
    let text = pick.ok_or_else(|| anyhow!("no ccv3 or chara iTXt chunk in PNG"))?;

    let payload = text.get_text().context("itxt text")?;
    let decoded = B64
        .decode(payload.trim().as_bytes())
        .context("base64-decode CCv2 payload")?;
    if decoded.len() > MAX_CARD_JSON {
        return Err(anyhow!("card JSON too large: {} bytes", decoded.len()));
    }
    let card: Card = serde_json::from_slice(&decoded).context("parse CCv2 JSON")?;
    if card.data.name.trim().is_empty() {
        return Err(anyhow!("card has no name"));
    }
    // Parse drop-notes for the log line; ignore errors.
    let dropped: DropNotes = serde_json::from_slice::<serde_json::Value>(&decoded)
        .ok()
        .and_then(|v| v.get("data").cloned())
        .and_then(|d| serde_json::from_value(d).ok())
        .unwrap_or_default();
    let mut drops = Vec::new();
    if dropped.first_mes.is_some() {
        drops.push("first_mes");
    }
    if dropped.mes_example.is_some() {
        drops.push("mes_example");
    }
    if dropped
        .alternate_greetings
        .as_ref()
        .is_some_and(|v| !v.is_empty())
    {
        drops.push("alternate_greetings");
    }
    if dropped.character_book.is_some() {
        drops.push("character_book");
    }
    if dropped.post_history_instructions.is_some() {
        drops.push("post_history_instructions");
    }
    if !drops.is_empty() {
        tracing::info!("character card dropped fields: {}", drops.join(", "));
    }
    tracing::info!(
        "loaded character card: {:?} ({}, by {}, version {})",
        card.data.name,
        card.spec,
        card.data.creator.as_deref().unwrap_or("unknown"),
        card.data.character_version.as_deref().unwrap_or("unknown"),
    );
    Ok(card)
}
