//! Background summary refresh: snapshot under lock, call LLM, commit under lock.
//!
//! See docs/superpowers/specs/2026-06-10-bot-memory-design.md §6.

use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::sync::Mutex;

use crate::llm::{ChatMessage, LlmClient};
use crate::memory::{parse_summary_response, Memory, Role, SummarySnapshot};

/// Build the EVENTS:/CHARACTER: prompt described in spec §6.
pub fn build_summary_messages(
    snap: &SummarySnapshot,
    character_name: &str,
    peer_name: &str,
) -> Vec<ChatMessage> {
    let prev_events = snap
        .prev_events
        .clone()
        .unwrap_or_else(|| "(none — first summary)".to_string());
    let prev_character = snap
        .prev_character
        .clone()
        .unwrap_or_else(|| "(none — first summary)".to_string());
    let mut new_turns = String::new();
    for t in &snap.new_turns {
        let tag = match t.role {
            Role::User => "[user]",
            Role::Assistant => "[assistant]",
        };
        new_turns.push_str(&format!("{tag} {}\n", t.content));
    }
    let last_id = snap
        .new_turns
        .last()
        .map(|t| t.id)
        .unwrap_or(snap.covers_up_to_turn_id);
    let first_new_id = snap
        .new_turns
        .first()
        .map(|t| t.id)
        .unwrap_or(snap.covers_up_to_turn_id + 1);
    let covers_to = snap.covers_up_to_turn_id;

    let user_content = format!(
        "You are summarizing a conversation between {character_name} and {peer_name}.

Previous summary (covers turns 1..{covers_to}):
EVENTS:
{prev_events}

CHARACTER:
{prev_character}

New turns to incorporate ({first_new_id}..{last_id}):
{new_turns}
Produce an updated summary as exactly two sections.

EVENTS:
Compressed \"what happened\" narrative — combine previous events with the new turns.
Keep names, decisions, places, emotional beats. Drop trivia. Max 400 words.

CHARACTER:
Speaking as {character_name}, write a brief first-person reflection — how you've been
feeling, what you've learned about {peer_name}, what feels significant. Max 200 words.

Reply with EVENTS: followed by the events text, then CHARACTER: on a new line followed
by the character text. Nothing else."
    );

    vec![ChatMessage {
        role: "user".into(),
        content: user_content,
    }]
}

/// Snapshot under lock → LLM call (no lock) → commit under lock. Never blocks the reply loop.
pub async fn run_summary_refresh(
    memory: Arc<Mutex<Memory>>,
    llm: Arc<LlmClient>,
    character_name: String,
    peer_name: String,
) -> Result<()> {
    let snap = {
        let m = memory.lock().await;
        m.snapshot_for_summary().context("snapshot_for_summary")?
    };
    if snap.new_turns.is_empty() {
        return Ok(());
    }
    let msgs = build_summary_messages(&snap, &character_name, &peer_name);
    let raw = llm.chat(&msgs).await.context("LLM summary call")?;
    let (events, character) = parse_summary_response(&raw).context("parse summary")?;
    let mut m = memory.lock().await;
    m.commit_summary(events, character, snap.covers_up_to_turn_id)
        .context("commit_summary")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::{SummarySnapshot, TurnRecord};

    #[test]
    fn build_summary_messages_includes_prev_summary_and_new_turns() {
        let snap = SummarySnapshot {
            prev_events: Some("did A".into()),
            prev_character: Some("felt warm".into()),
            covers_up_to_turn_id: 3,
            new_turns: vec![
                TurnRecord {
                    id: 4,
                    ts: 0,
                    role: Role::User,
                    content: "hi".into(),
                },
                TurnRecord {
                    id: 5,
                    ts: 0,
                    role: Role::Assistant,
                    content: "hey".into(),
                },
            ],
        };
        let msgs = build_summary_messages(&snap, "Nova", "alice");
        assert_eq!(msgs.len(), 1);
        let c = &msgs[0].content;
        assert!(c.contains("Nova"));
        assert!(c.contains("alice"));
        assert!(c.contains("did A"));
        assert!(c.contains("felt warm"));
        assert!(c.contains("[user] hi"));
        assert!(c.contains("[assistant] hey"));
        assert!(c.contains("4..5"));
        assert!(c.contains("1..3"));
    }

    #[test]
    fn build_summary_messages_handles_empty_prev_summary() {
        let snap = SummarySnapshot {
            prev_events: None,
            prev_character: None,
            covers_up_to_turn_id: 0,
            new_turns: vec![TurnRecord {
                id: 1,
                ts: 0,
                role: Role::User,
                content: "hello".into(),
            }],
        };
        let msgs = build_summary_messages(&snap, "Nova", "alice");
        assert!(msgs[0].content.contains("(none — first summary)"));
    }
}
