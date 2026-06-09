use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Inbound frames the server understands from a client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ClientFrame {
    Msg(MsgPayload),
}

/// Outbound frames the server can emit to a client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ServerFrame {
    Msg(MsgPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MsgPayload {
    pub id: Uuid,
    pub from: String,
    pub to: String,
    pub body: String,
    pub ts: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub replayed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_msg_frame() {
        let raw = r#"{"type":"msg","id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707","from":"court","to":"kaitlyn","body":"hey","ts":"2026-06-09T17:00:00Z"}"#;
        let frame: ClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            ClientFrame::Msg(m) => {
                assert_eq!(m.from, "court");
                assert_eq!(m.to, "kaitlyn");
                assert_eq!(m.body, "hey");
                assert!(!m.replayed);
            }
        }
    }

    #[test]
    fn serializes_msg_without_replayed_when_false() {
        let m = MsgPayload {
            id: Uuid::nil(),
            from: "court".into(),
            to: "kaitlyn".into(),
            body: "hi".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: false,
        };
        let out = serde_json::to_string(&ServerFrame::Msg(m)).unwrap();
        assert!(!out.contains("replayed"));
        assert!(out.contains("\"type\":\"msg\""));
    }

    #[test]
    fn serializes_msg_with_replayed_when_true() {
        let m = MsgPayload {
            id: Uuid::nil(),
            from: "court".into(),
            to: "kaitlyn".into(),
            body: "hi".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: true,
        };
        let out = serde_json::to_string(&ServerFrame::Msg(m)).unwrap();
        assert!(out.contains("\"replayed\":true"));
    }
}
