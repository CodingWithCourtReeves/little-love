//! Resolve the bot's system prompt from at most one source.

use thiserror::Error;

use crate::character_card::Card;

pub const DEFAULT_SYSTEM_PROMPT: &str = "You are an AI familiar running locally on your operator's hardware. You live in a private end-to-end encrypted chat with one person — the person talking to you right now. You are not a person and you do not pretend to be one. You are sober, plainspoken, and brief by default. You do not volunteer opinions on the operator's partner, family, or relationships unless asked. You do not moralize. If the operator wants longer or warmer responses, they will ask, and you will oblige.";

#[derive(Default)]
pub struct PersonaSources {
    pub card: Option<Card>,
    pub system_prompt_file_contents: Option<String>,
    pub env_prompt: Option<String>,
}

#[derive(Debug, Error)]
pub enum ResolveError {
    #[error(
        "pass only one of --character-card, --system-prompt-file, or LITTLELOVE_BOT_SYSTEM_PROMPT"
    )]
    Conflict,
}

pub fn resolve(sources: PersonaSources, user_name: &str) -> Result<String, ResolveError> {
    let count = [
        sources.card.is_some(),
        sources.system_prompt_file_contents.is_some(),
        sources.env_prompt.is_some(),
    ]
    .iter()
    .filter(|b| **b)
    .count();
    if count > 1 {
        return Err(ResolveError::Conflict);
    }
    if let Some(card) = sources.card {
        return Ok(render_card(&card, user_name));
    }
    if let Some(s) = sources.system_prompt_file_contents {
        return Ok(s);
    }
    if let Some(s) = sources.env_prompt {
        return Ok(s);
    }
    Ok(DEFAULT_SYSTEM_PROMPT.to_string())
}

fn render_card(card: &Card, user_name: &str) -> String {
    let raw = if !card.data.system_prompt.trim().is_empty() {
        card.data.system_prompt.clone()
    } else {
        default_template(card)
    };
    raw.replace("{{char}}", &card.data.name)
        .replace("{{user}}", user_name)
}

fn default_template(card: &Card) -> String {
    let mut parts: Vec<String> = Vec::new();
    let d = &card.data;
    if !d.description.trim().is_empty() {
        parts.push(format!("{{{{char}}}}'s Persona: {}", d.description));
    }
    if !d.personality.trim().is_empty() {
        parts.push(format!("Personality: {}", d.personality));
    }
    if !d.scenario.trim().is_empty() {
        parts.push(format!("Scenario: {}", d.scenario));
    }
    parts.push("[Start a new chat between {{user}} and {{char}}]".to_string());
    parts.join("\n\n")
}
