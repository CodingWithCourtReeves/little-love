#![allow(clippy::field_reassign_with_default)]

use littlelove_bot::persona::{resolve, PersonaSources, ResolveError};

#[test]
fn default_prompt_when_no_sources() {
    let p = resolve(PersonaSources::default(), "court").expect("resolve");
    assert!(p.contains("AI familiar"));
}

#[test]
fn env_string_wins_over_default() {
    let mut s = PersonaSources::default();
    s.env_prompt = Some("custom env prompt".into());
    let p = resolve(s, "court").unwrap();
    assert_eq!(p, "custom env prompt");
}

#[test]
fn mutual_exclusion_errors() {
    let mut s = PersonaSources::default();
    s.system_prompt_file_contents = Some("a".into());
    s.env_prompt = Some("b".into());
    let err = resolve(s, "court").unwrap_err();
    assert!(matches!(err, ResolveError::Conflict));
}

#[test]
fn card_template_substitutes_user_and_char() {
    use littlelove_bot::character_card::{Card, CardData};
    let mut s = PersonaSources::default();
    s.card = Some(Card {
        spec: "chara_card_v2".into(),
        data: CardData {
            name: "Aria".into(),
            description: "{{char}} is the assistant for {{user}}.".into(),
            personality: "".into(),
            scenario: "".into(),
            system_prompt: "".into(),
            creator: None,
            character_version: None,
        },
    });
    let p = resolve(s, "court").unwrap();
    assert!(p.contains("Aria is the assistant for court"));
    assert!(p.contains("[Start a new chat between court and Aria]"));
}

#[test]
fn card_system_prompt_used_verbatim() {
    use littlelove_bot::character_card::{Card, CardData};
    let mut s = PersonaSources::default();
    s.card = Some(Card {
        spec: "chara_card_v2".into(),
        data: CardData {
            name: "Iris".into(),
            description: "drop".into(),
            personality: "drop".into(),
            scenario: "drop".into(),
            system_prompt: "You are {{char}}. Speak only when spoken to.".into(),
            creator: None,
            character_version: None,
        },
    });
    let p = resolve(s, "court").unwrap();
    assert_eq!(p, "You are Iris. Speak only when spoken to.");
}
