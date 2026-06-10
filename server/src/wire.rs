use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Day-1 legacy inbound frames (deprecated; preserved only for the on-disk
/// migration test harness). New v0.2 client frames use the kind-tagged
/// `RoomClientFrame` (see below).
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

/// Day-1 legacy outbound frames. Kept for compatibility while WT-C-era
/// client tests still consume `type:"msg"` shapes; the new room-scoped
/// `Message` frame lives in `RoomServerFrame`.
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

/// Inbound auth frames (kind-tagged per spec §8.2). Only the Identify frame
/// arrives here; once the client is past the handshake, it sends
/// `RoomClientFrame` shapes.
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

/// Outbound auth frames (kind-tagged per spec §8.2). Once a client is
/// authenticated the server starts emitting `RoomServerFrame` shapes.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum AuthServerFrame {
    Challenge { nonce: String },
    Authenticated,
    Error { code: String, message: String },
}

/// Post-Authenticated client frames (spec §8.2). All v0.2 authenticated
/// operations flow through here.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum RoomClientFrame {
    CreateInvite,
    ConsumeInvite {
        code: String,
        signature_over_token: String,
    },
    Subscribe {
        room_id: String,
        since_message_id: Option<String>,
    },
    Send {
        room_id: String,
        body: String,
        client_msg_id: Uuid,
    },
}

/// Post-Authenticated server frames (spec §8.2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind")]
pub enum RoomServerFrame {
    Rooms {
        rooms: Vec<RoomSummary>,
    },
    InviteCreated {
        code: String,
        qr_png_base64: String,
        expires_at: DateTime<Utc>,
    },
    InviteConsumed(RoomDescriptor),
    RoomCreated(RoomDescriptor),
    Message {
        id: String,
        room_id: String,
        from: String,
        ts: DateTime<Utc>,
        body: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        replayed: bool,
    },
    Error {
        code: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        message: String,
    },
}

/// Subset of a room used in the `Rooms` server frame. Matches the shape
/// returned by `POST /invites/{code}/preview` plus a `room_id` + timestamp.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RoomSummary {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
    pub created_at: DateTime<Utc>,
}

/// Used by `InviteConsumed` (sent to consumer) and `RoomCreated` (pushed to
/// the inviter). Same payload shape, different `kind` discriminant.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RoomDescriptor {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
}

/// Server error codes used in `RoomServerFrame::Error` (spec §8.2).
pub mod error_codes {
    pub const ALREADY_PAIRED: &str = "AlreadyPaired";
    pub const INVITE_NOT_FOUND: &str = "InviteNotFound";
    pub const INVITE_EXPIRED: &str = "InviteExpired";
    pub const INVITE_CONSUMED: &str = "InviteConsumed";
    pub const INVALID_SIGNATURE: &str = "InvalidSignature";
    pub const UNKNOWN_ROOM: &str = "UnknownRoom";
    pub const BAD_CODE: &str = "BadCode";
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

    #[test]
    fn parses_create_invite_frame() {
        let raw = r#"{"kind":"CreateInvite"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        assert!(matches!(frame, RoomClientFrame::CreateInvite));
    }

    #[test]
    fn parses_consume_invite_frame() {
        let raw = r#"{"kind":"ConsumeInvite","code":"a-b-c-d","signature_over_token":"AAAA"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::ConsumeInvite {
                code,
                signature_over_token,
            } => {
                assert_eq!(code, "a-b-c-d");
                assert_eq!(signature_over_token, "AAAA");
            }
            _ => panic!("expected ConsumeInvite"),
        }
    }

    #[test]
    fn parses_subscribe_frame_with_null_since() {
        let raw = r#"{"kind":"Subscribe","room_id":"01J","since_message_id":null}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::Subscribe {
                room_id,
                since_message_id,
            } => {
                assert_eq!(room_id, "01J");
                assert!(since_message_id.is_none());
            }
            _ => panic!("expected Subscribe"),
        }
    }

    #[test]
    fn parses_send_frame() {
        let raw = r#"{"kind":"Send","room_id":"01J","body":"ct","client_msg_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::Send {
                room_id,
                body,
                client_msg_id,
            } => {
                assert_eq!(room_id, "01J");
                assert_eq!(body, "ct");
                assert!(!client_msg_id.is_nil());
            }
            _ => panic!("expected Send"),
        }
    }

    #[test]
    fn serializes_rooms_frame() {
        let f = RoomServerFrame::Rooms {
            rooms: vec![RoomSummary {
                room_id: "01J".into(),
                peer_username: "kaitlyn".into(),
                peer_ed25519_pub: "AAAA".into(),
                peer_x25519_pub: "BBBB".into(),
                created_at: "2026-06-09T17:00:00Z".parse().unwrap(),
            }],
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Rooms""#));
        assert!(s.contains(r#""peer_username":"kaitlyn""#));
    }

    #[test]
    fn serializes_invite_created_frame() {
        let f = RoomServerFrame::InviteCreated {
            code: "amber-fern-locket-tide".into(),
            qr_png_base64: "".into(),
            expires_at: "2026-06-09T18:00:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"InviteCreated""#));
        assert!(s.contains(r#""code":"amber-fern-locket-tide""#));
    }

    #[test]
    fn serializes_room_created_frame() {
        let f = RoomServerFrame::RoomCreated(RoomDescriptor {
            room_id: "01J".into(),
            peer_username: "kaitlyn".into(),
            peer_ed25519_pub: "AAAA".into(),
            peer_x25519_pub: "BBBB".into(),
        });
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"RoomCreated""#));
        assert!(s.contains(r#""room_id":"01J""#));
    }

    #[test]
    fn serializes_invite_consumed_frame() {
        let f = RoomServerFrame::InviteConsumed(RoomDescriptor {
            room_id: "01J".into(),
            peer_username: "court".into(),
            peer_ed25519_pub: "AAAA".into(),
            peer_x25519_pub: "BBBB".into(),
        });
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"InviteConsumed""#));
    }

    #[test]
    fn serializes_room_message_frame() {
        let f = RoomServerFrame::Message {
            id: "01J".into(),
            room_id: "01J".into(),
            from: "court".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            body: "hi".into(),
            replayed: false,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Message""#));
        assert!(!s.contains("replayed"), "false replayed should be omitted");
    }

    #[test]
    fn serializes_room_error_frame() {
        let f = RoomServerFrame::Error {
            code: error_codes::ALREADY_PAIRED.into(),
            message: "".into(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Error""#));
        assert!(s.contains(r#""code":"AlreadyPaired""#));
        // empty message field is omitted
        assert!(!s.contains("\"message\""));
    }
}
