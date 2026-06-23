use std::collections::HashMap;

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

/// Post-Authenticated client frames (spec §8.2).
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
        /// Map from recipient `x25519_pub_b64` to the addressed ciphertext (spec §6.2).
        bodies: HashMap<String, String>,
        client_msg_id: Uuid,
    },
    RequestUpload {
        request_id: Uuid,
        room_id: String,
        byte_size: i64,
    },
    RequestDownload {
        blob_key: String,
    },
    CreateRoom {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        invite_human_partner: bool,
    },
    RenameRoom {
        room_id: String,
        name: String,
    },
    LeaveRoom {
        room_id: String,
    },
    /// Sent when the client opens a chat: acknowledges every message in the
    /// room up to and including `up_to_message_id` as read.
    MarkRead {
        room_id: String,
        up_to_message_id: String,
    },
    /// Register (or refresh) this device's APNs token for the authenticated
    /// account. Sent after the OS grants notification permission and on token
    /// refresh.
    RegisterPush {
        device_id: String,
        apns_token: String,
        environment: String,
    },
    /// Drop this device's APNs token (logout / permission revoked).
    UnregisterPush {
        device_id: String,
    },
    /// Transient typing presence. Relayed to the other room member(s) and
    /// never stored. The client sends `typing:true` while composing and
    /// `typing:false` when it stops (or on send); a short client-side timeout
    /// covers a dropped `typing:false`.
    Typing {
        room_id: String,
        typing: bool,
    },
    /// Publish my E2EE profile (display name + avatar ref). `envelope` is the
    /// base64 ciphertext, sealed with the pairwise room key; the server stores
    /// it opaquely and relays it to my partner.
    PublishProfile {
        envelope: String,
        #[serde(default)]
        avatar_key: Option<String>,
    },
}

/// Post-Authenticated server frames (spec §8.2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind")]
pub enum RoomServerFrame {
    Rooms {
        rooms: Vec<RoomDetail>,
    },

    InviteCreated {
        code: String,
        qr_png_base64: String,
        expires_at: DateTime<Utc>,
    },

    InviteConsumed {
        room_id: String,
        name: String,
        members: Vec<Member>,
    },

    RoomCreated {
        room_id: String,
        name: String,
        members: Vec<Member>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pending_invite: Option<PendingInvite>,
    },

    RoomRenamed {
        room_id: String,
        name: String,
    },

    MemberLeft {
        room_id: String,
        username: String,
    },

    Message {
        id: String,
        room_id: String,
        from: String,
        ts: DateTime<Utc>,
        body: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        replayed: bool,
        /// True on the sender's own self-copy once the partner has read this
        /// message. Set on `Subscribe` replay so double hearts survive a
        /// restart; omitted (false) for unread messages and incoming ones.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        read: bool,
        /// Echoed back to the sender on their own self-copy so the client can
        /// reconcile the optimistic local echo (keyed by this id) with the
        /// authoritative server row. Absent for messages addressed to other
        /// recipients and for replayed history (not persisted).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client_msg_id: Option<Uuid>,
    },

    /// Relayed to a sender when the partner reads one or more of their
    /// messages. `message_ids` are the ids that just flipped to read.
    Read {
        room_id: String,
        message_ids: Vec<String>,
        reader: String,
    },

    /// Relayed presence: `from` is composing (or stopped) in `room_id`. Not
    /// persisted — a fresh subscriber never replays it.
    Typing {
        room_id: String,
        from: String,
        typing: bool,
    },

    /// Partner presence: `user` is now online or offline. Server-authoritative —
    /// derived from the partner's authenticated WS sessions; clients never send
    /// this, and it is delivered only to the user's linked partner. Not
    /// persisted; a fresh connection learns current state on connect.
    Presence {
        user: String,
        online: bool,
    },

    /// Relayed profile: `user` published a new profile. Delivered to the linked
    /// partner on publish and on connect (latest stored). `envelope` is opaque
    /// base64 ciphertext, sealed with the pairwise room key.
    Profile {
        user: String,
        envelope: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        avatar_key: Option<String>,
    },

    UploadGranted {
        request_id: Uuid,
        blob_key: String,
        url: String,
        expires_at: DateTime<Utc>,
    },

    DownloadGranted {
        blob_key: String,
        url: String,
        expires_at: DateTime<Utc>,
    },

    Error {
        code: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        message: String,
    },
}

/// One member of a room (spec §7.1).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Member {
    /// Stable account id. `#[serde(default)]` keeps older payloads (which omit
    /// it) deserializable.
    #[serde(default)]
    pub account_id: i64,
    pub username: String,
    pub ed25519_pub: String,
    pub x25519_pub: String,
}

/// Carried inside `Rooms`, `RoomCreated`, `InviteConsumed` payloads (spec §7.1).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RoomDetail {
    pub room_id: String,
    pub name: String,
    pub members: Vec<Member>,
    pub created_at: DateTime<Utc>,
}

/// Inlined into `RoomCreated` when the creator asked for an invite at room-
/// creation time (spec §5.2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingInvite {
    pub code: String,
    pub qr_png_base64: String,
    pub expires_at: DateTime<Utc>,
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
    pub const FAN_OUT_MISMATCH: &str = "FanOutMismatch";
    pub const MONOGAMY_VIOLATION: &str = "MonogamyViolation";
    pub const BODY_TOO_LARGE: &str = "BodyTooLarge";
    pub const BLOB_TOO_LARGE: &str = "BlobTooLarge";
    pub const UNKNOWN_BLOB: &str = "UnknownBlob";
    pub const R2_UNAVAILABLE: &str = "R2Unavailable";
    pub const RATE_LIMITED: &str = "RateLimited";
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
    fn parses_send_frame_with_bodies_map() {
        let raw = r#"{"kind":"Send","room_id":"01J","bodies":{"AAAA":"ct1","BBBB":"ct2"},"client_msg_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::Send {
                room_id,
                bodies,
                client_msg_id,
            } => {
                assert_eq!(room_id, "01J");
                assert_eq!(bodies.len(), 2);
                assert_eq!(bodies["AAAA"], "ct1");
                assert_eq!(bodies["BBBB"], "ct2");
                assert!(!client_msg_id.is_nil());
            }
            _ => panic!("expected Send"),
        }
    }

    #[test]
    fn parses_create_room_frame_with_defaults() {
        let raw = r#"{"kind":"CreateRoom"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::CreateRoom {
                name,
                invite_human_partner,
            } => {
                assert!(name.is_none());
                assert!(!invite_human_partner);
            }
            _ => panic!("expected CreateRoom"),
        }
    }

    #[test]
    fn parses_create_room_frame_with_fields() {
        let raw = r#"{"kind":"CreateRoom","name":"Travel","invite_human_partner":true}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::CreateRoom {
                name,
                invite_human_partner,
            } => {
                assert_eq!(name.as_deref(), Some("Travel"));
                assert!(invite_human_partner);
            }
            _ => panic!("expected CreateRoom"),
        }
    }

    #[test]
    fn parses_rename_room_frame() {
        let raw = r#"{"kind":"RenameRoom","room_id":"01J","name":"New name"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::RenameRoom { room_id, name } => {
                assert_eq!(room_id, "01J");
                assert_eq!(name, "New name");
            }
            _ => panic!("expected RenameRoom"),
        }
    }

    #[test]
    fn parses_leave_room_frame() {
        let raw = r#"{"kind":"LeaveRoom","room_id":"01J"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::LeaveRoom { room_id } => {
                assert_eq!(room_id, "01J");
            }
            _ => panic!("expected LeaveRoom"),
        }
    }

    #[test]
    fn serializes_rooms_frame_with_member_roster() {
        let f = RoomServerFrame::Rooms {
            rooms: vec![RoomDetail {
                room_id: "01J".into(),
                name: "".into(),
                members: vec![
                    Member {
                        account_id: 1,
                        username: "court".into(),
                        ed25519_pub: "AAAA".into(),
                        x25519_pub: "BBBB".into(),
                    },
                    Member {
                        account_id: 2,
                        username: "kaitlyn".into(),
                        ed25519_pub: "CCCC".into(),
                        x25519_pub: "DDDD".into(),
                    },
                ],
                created_at: "2026-06-09T17:00:00Z".parse().unwrap(),
            }],
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Rooms""#));
        assert!(s.contains(r#""members":["#));
        assert!(s.contains(r#""username":"court""#));
        assert!(s.contains(r#""username":"kaitlyn""#));
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
    fn serializes_room_created_with_pending_invite() {
        let f = RoomServerFrame::RoomCreated {
            room_id: "01J".into(),
            name: "Travel planning".into(),
            members: vec![],
            pending_invite: Some(PendingInvite {
                code: "amber-fern-locket-tide".into(),
                qr_png_base64: "".into(),
                expires_at: "2026-06-09T18:00:00Z".parse().unwrap(),
            }),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"RoomCreated""#));
        assert!(s.contains(r#""pending_invite":{"#));
        assert!(s.contains(r#""code":"amber-fern-locket-tide""#));
    }

    #[test]
    fn serializes_room_created_omits_null_pending_invite() {
        let f = RoomServerFrame::RoomCreated {
            room_id: "01J".into(),
            name: "".into(),
            members: vec![],
            pending_invite: None,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(!s.contains("pending_invite"));
    }

    #[test]
    fn serializes_invite_consumed_frame() {
        let f = RoomServerFrame::InviteConsumed {
            room_id: "01J".into(),
            name: "".into(),
            members: vec![Member {
                account_id: 1,
                username: "court".into(),
                ed25519_pub: "AAAA".into(),
                x25519_pub: "BBBB".into(),
            }],
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"InviteConsumed""#));
        assert!(s.contains(r#""username":"court""#));
    }

    #[test]
    fn serializes_room_renamed_frame() {
        let f = RoomServerFrame::RoomRenamed {
            room_id: "01J".into(),
            name: "Travel".into(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"RoomRenamed""#));
        assert!(s.contains(r#""name":"Travel""#));
    }

    #[test]
    fn serializes_member_left_frame() {
        let f = RoomServerFrame::MemberLeft {
            room_id: "01J".into(),
            username: "kaitlyn".into(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"MemberLeft""#));
        assert!(s.contains(r#""username":"kaitlyn""#));
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
            read: false,
            client_msg_id: None,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Message""#));
        assert!(!s.contains("replayed"), "false replayed should be omitted");
        assert!(
            !s.contains("client_msg_id"),
            "absent client_msg_id should be omitted"
        );
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
        assert!(!s.contains("\"message\""));
    }

    #[test]
    fn error_codes_module_carries_pairing_codes() {
        assert_eq!(error_codes::FAN_OUT_MISMATCH, "FanOutMismatch");
        assert_eq!(error_codes::MONOGAMY_VIOLATION, "MonogamyViolation");
        assert_eq!(error_codes::ALREADY_PAIRED, "AlreadyPaired");
    }

    #[test]
    fn parses_mark_read_frame() {
        let raw = r#"{"kind":"MarkRead","room_id":"01J","up_to_message_id":"01JX"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::MarkRead {
                room_id,
                up_to_message_id,
            } => {
                assert_eq!(room_id, "01J");
                assert_eq!(up_to_message_id, "01JX");
            }
            _ => panic!("expected MarkRead"),
        }
    }

    #[test]
    fn parses_register_push_frame() {
        let raw = r#"{"kind":"RegisterPush","device_id":"dev-1","apns_token":"abcd","environment":"sandbox"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::RegisterPush {
                device_id,
                apns_token,
                environment,
            } => {
                assert_eq!(device_id, "dev-1");
                assert_eq!(apns_token, "abcd");
                assert_eq!(environment, "sandbox");
            }
            _ => panic!("expected RegisterPush"),
        }
    }

    #[test]
    fn parses_unregister_push_frame() {
        let raw = r#"{"kind":"UnregisterPush","device_id":"dev-1"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        assert!(
            matches!(frame, RoomClientFrame::UnregisterPush { device_id } if device_id == "dev-1")
        );
    }

    #[test]
    fn parses_request_upload_frame() {
        let raw = r#"{"kind":"RequestUpload","request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707","room_id":"01J","byte_size":1048576}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::RequestUpload {
                room_id, byte_size, ..
            } => {
                assert_eq!(room_id, "01J");
                assert_eq!(byte_size, 1_048_576);
            }
            _ => panic!("expected RequestUpload"),
        }
    }

    #[test]
    fn serializes_read_frame() {
        let f = RoomServerFrame::Read {
            room_id: "01J".into(),
            message_ids: vec!["01JA".into(), "01JB".into()],
            reader: "kaitlyn".into(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Read""#));
        assert!(s.contains(r#""reader":"kaitlyn""#));
        assert!(s.contains(r#""message_ids":["01JA","01JB"]"#));
    }

    #[test]
    fn serializes_message_frame_with_read_true() {
        let f = RoomServerFrame::Message {
            id: "01J".into(),
            room_id: "01J".into(),
            from: "court".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            body: "hi".into(),
            replayed: true,
            read: true,
            client_msg_id: None,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""read":true"#));
    }

    #[test]
    fn message_frame_omits_read_when_false() {
        let f = RoomServerFrame::Message {
            id: "01J".into(),
            room_id: "01J".into(),
            from: "court".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            body: "hi".into(),
            replayed: false,
            read: false,
            client_msg_id: None,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(!s.contains("read"), "false read should be omitted: {s}");
    }

    #[test]
    fn parses_typing_frame() {
        let raw = r#"{"kind":"Typing","room_id":"01J","typing":true}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            RoomClientFrame::Typing { room_id, typing } => {
                assert_eq!(room_id, "01J");
                assert!(typing);
            }
            _ => panic!("expected Typing"),
        }
    }

    #[test]
    fn serializes_typing_server_frame() {
        let f = RoomServerFrame::Typing {
            room_id: "01J".into(),
            from: "court".into(),
            typing: false,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Typing""#));
        assert!(s.contains(r#""from":"court""#));
        assert!(s.contains(r#""typing":false"#));
    }

    #[test]
    fn serializes_presence_server_frame() {
        let f = RoomServerFrame::Presence {
            user: "kaitlyn".into(),
            online: true,
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"Presence""#));
        assert!(s.contains(r#""user":"kaitlyn""#));
        assert!(s.contains(r#""online":true"#));
    }

    #[test]
    fn parses_request_download_frame() {
        let raw = r#"{"kind":"RequestDownload","blob_key":"01JBLOB"}"#;
        let frame: RoomClientFrame = serde_json::from_str(raw).unwrap();
        assert!(
            matches!(frame, RoomClientFrame::RequestDownload { blob_key } if blob_key == "01JBLOB")
        );
    }

    #[test]
    fn serializes_upload_granted_frame() {
        let f = RoomServerFrame::UploadGranted {
            request_id: Uuid::nil(),
            blob_key: "01JBLOB".into(),
            url: "https://r2/put".into(),
            expires_at: "2026-06-16T18:00:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"UploadGranted""#));
        assert!(s.contains(r#""blob_key":"01JBLOB""#));
    }

    #[test]
    fn serializes_download_granted_frame() {
        let f = RoomServerFrame::DownloadGranted {
            blob_key: "01JBLOB".into(),
            url: "https://r2/get".into(),
            expires_at: "2026-06-16T18:00:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&f).unwrap();
        assert!(s.contains(r#""kind":"DownloadGranted""#));
    }
}
