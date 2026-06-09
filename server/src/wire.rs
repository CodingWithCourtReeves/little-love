use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Inbound frames the server understands from a client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ClientFrame {
    Msg(MsgPayload),
    Hello(HelloPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelloPayload {
    pub since: chrono::DateTime<chrono::Utc>,
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

/// Inbound auth frames (kind-tagged per spec §8.2).
/// Distinct from the legacy `type`-tagged `ClientFrame` (Msg/Hello).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum AuthClientFrame {
    Identify(IdentifyPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentifyPayload {
    pub username: String,
    /// Base64-encoded Ed25519 signature over the domain-separated input
    /// (see spec §3.3 and §8.5.1).
    pub signature: String,
}

/// Outbound auth frames (kind-tagged per spec §8.2).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum AuthServerFrame {
    Challenge { nonce: String },
    Authenticated,
    Error { code: String, message: String },
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
            _ => panic!("expected Msg"),
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
    fn parses_a_hello_frame() {
        let raw = r#"{"type":"hello","since":"2026-06-08T00:00:00Z"}"#;
        let frame: ClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            ClientFrame::Hello(h) => {
                let expected: chrono::DateTime<chrono::Utc> =
                    "2026-06-08T00:00:00Z".parse().unwrap();
                assert_eq!(h.since, expected);
            }
            _ => panic!("expected Hello"),
        }
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

    #[test]
    fn parses_an_identify_frame() {
        let raw = r#"{"kind":"Identify","username":"court","signature":"AAAA"}"#;
        let frame: AuthClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            AuthClientFrame::Identify(p) => {
                assert_eq!(p.username, "court");
                assert_eq!(p.signature, "AAAA");
            }
        }
    }

    #[test]
    fn serializes_challenge_frame() {
        let f = AuthServerFrame::Challenge {
            nonce: "AAAA".to_string(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Challenge""#));
        assert!(s.contains(r#""nonce":"AAAA""#));
    }

    #[test]
    fn serializes_authenticated_frame() {
        let s = serde_json::to_string(&AuthServerFrame::Authenticated).unwrap();
        assert_eq!(s, r#"{"kind":"Authenticated"}"#);
    }

    #[test]
    fn serializes_error_frame() {
        let f = AuthServerFrame::Error {
            code: "InvalidSignature".into(),
            message: "bad sig".into(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Error""#));
        assert!(s.contains(r#""code":"InvalidSignature""#));
    }
}
