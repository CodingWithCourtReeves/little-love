//! Push-notification composition + the `PushSender` seam. The actual APNs
//! transport (`ApnsSender`) lives behind the `PushSender` trait so the
//! send-trigger and token-hygiene logic is testable without a network.

use async_trait::async_trait;

/// Notification copy — generic and content-free (E2EE: the server never sees
/// the message, and we deliberately don't show content).
pub const PUSH_TITLE: &str = "Little Love";
pub const PUSH_BODY: &str = "💜 Your partner sent you a message";

/// Which kind of push this is. Alert = a visible message banner; Voip = a
/// data-only PushKit wake that must surface a CallKit incoming call on the
/// device (iOS-13 contract). They use different APNs topics and push-types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushKind {
    Alert,
    Voip,
}

/// One addressed push: the device token, its APNs environment, and the opaque
/// room id carried as custom data for tap deep-linking / call routing.
#[derive(Debug, Clone)]
pub struct PushMessage {
    pub token: String,
    pub environment: String,
    pub room_id: String,
    /// Recipient's total unread count → the app-icon badge. Ignored for Voip.
    pub badge: u32,
    /// Alert (message banner) or Voip (CallKit wake).
    pub push_type: PushKind,
    /// Carried as custom data on a Voip push so the client ties the CallKit UI
    /// to the incoming call. `None` for Alert pushes.
    pub call_id: Option<String>,
    /// Whether a Voip push is for a video call → the native CallKit screen shows
    /// the video affordance. Ignored for Alert pushes.
    pub video: bool,
}

/// The `a2` push-type for a `PushKind`.
pub(crate) fn apns_push_type(kind: PushKind) -> a2::PushType {
    match kind {
        PushKind::Alert => a2::PushType::Alert,
        PushKind::Voip => a2::PushType::Voip,
    }
}

/// What to do after a single send attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    /// APNs accepted the notification.
    Delivered,
    /// The token is permanently invalid — delete it.
    DropToken,
    /// A retryable / non-fatal error — keep the token, try again next time.
    Transient,
}

/// The transport seam. `ApnsSender` implements this over `a2`; tests use a fake.
#[async_trait]
pub trait PushSender: Send + Sync {
    async fn send(&self, msg: &PushMessage) -> SendOutcome;
}

/// Map an APNs HTTP status + reason string to an action. 410 Unregistered and
/// the 400 "bad/foreign token" reasons mean the token is dead; everything else
/// non-2xx is transient.
pub fn classify(code: u16, reason: Option<&str>) -> SendOutcome {
    match (code, reason) {
        (200, _) => SendOutcome::Delivered,
        (410, _) => SendOutcome::DropToken,
        (400, Some("BadDeviceToken")) | (400, Some("DeviceTokenNotForTopic")) => {
            SendOutcome::DropToken
        }
        _ => SendOutcome::Transient,
    }
}

use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions,
};
use std::sync::Arc;
use tracing::warn;

/// `a2`-backed APNs transport. Holds one HTTP/2 client per environment so a
/// couple's mixed sandbox/production tokens both work from a single sender.
pub struct ApnsSender {
    sandbox: Arc<Client>,
    production: Arc<Client>,
    topic: String,
    voip_topic: String,
}

impl ApnsSender {
    pub fn new(cfg: &crate::config::ApnsConfig) -> anyhow::Result<Self> {
        let mk = |endpoint: Endpoint| -> anyhow::Result<Client> {
            let mut pem = cfg.key_p8.as_bytes();
            let client = Client::token(
                &mut pem,
                &cfg.key_id,
                &cfg.team_id,
                ClientConfig::new(endpoint),
            )?;
            Ok(client)
        };
        Ok(Self {
            sandbox: Arc::new(mk(Endpoint::Sandbox)?),
            production: Arc::new(mk(Endpoint::Production)?),
            topic: cfg.topic.clone(),
            voip_topic: cfg.voip_topic.clone(),
        })
    }

    /// The topic to send a given push kind under (alert vs `.voip`).
    fn topic_for(&self, kind: PushKind) -> &str {
        match kind {
            PushKind::Alert => &self.topic,
            PushKind::Voip => &self.voip_topic,
        }
    }

    fn client_for(&self, environment: &str) -> &Client {
        if environment == "production" {
            &self.production
        } else {
            &self.sandbox
        }
    }
}

#[async_trait]
impl PushSender for ApnsSender {
    async fn send(&self, msg: &PushMessage) -> SendOutcome {
        let mut payload = match msg.push_type {
            PushKind::Alert => {
                let options = NotificationOptions {
                    apns_topic: Some(self.topic_for(PushKind::Alert)),
                    apns_push_type: Some(apns_push_type(PushKind::Alert)),
                    // Coalesce a burst in the same room into one banner (the badge
                    // still climbs) instead of stacking N identical "your partner
                    // sent…" rows. room_id is a 26-char ULID, well under the
                    // 64-byte limit, so new() always succeeds; .ok() degrades
                    // gracefully if that ever changes.
                    apns_collapse_id: a2::CollapseId::new(msg.room_id.as_str()).ok(),
                    ..Default::default()
                };
                DefaultNotificationBuilder::new()
                    .set_title(PUSH_TITLE)
                    .set_body(PUSH_BODY)
                    .set_sound("default")
                    .set_badge(msg.badge)
                    .set_mutable_content()
                    .build(msg.token.as_str(), options)
            }
            PushKind::Voip => {
                // Data-only wake: no alert/sound/badge. iOS requires a distinct
                // topic (`.voip`) and push-type; the app must report a CallKit
                // call on receipt (iOS-13 contract). No collapse — every call
                // wakes independently.
                let options = NotificationOptions {
                    apns_topic: Some(self.topic_for(PushKind::Voip)),
                    apns_push_type: Some(apns_push_type(PushKind::Voip)),
                    ..Default::default()
                };
                DefaultNotificationBuilder::new().build(msg.token.as_str(), options)
            }
        };
        // Opaque room id (and call id, for Voip) as custom data. No message
        // content ever; E2EE intact.
        if let Err(e) = payload.add_custom_data("room_id", &msg.room_id) {
            warn!("push: add_custom_data room_id failed: {e}");
            return SendOutcome::Transient;
        }
        if let Some(call_id) = &msg.call_id {
            if let Err(e) = payload.add_custom_data("call_id", call_id) {
                warn!("push: add_custom_data call_id failed: {e}");
                return SendOutcome::Transient;
            }
            // Only meaningful alongside a call_id (Voip). Lets the woken client
            // show the native video-call screen before any SDP is decrypted.
            if let Err(e) = payload.add_custom_data("video", &msg.video) {
                warn!("push: add_custom_data video failed: {e}");
                return SendOutcome::Transient;
            }
        }

        match self.client_for(&msg.environment).send(payload).await {
            Ok(resp) => classify(resp.code, None),
            Err(a2::Error::ResponseError(resp)) => {
                let reason = resp.error.as_ref().map(|e| format!("{:?}", e.reason));
                classify(resp.code, reason.as_deref())
            }
            Err(e) => {
                warn!("push: APNs send error: {e}");
                SendOutcome::Transient
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_410_drops_the_token() {
        assert!(matches!(
            classify(410, Some("Unregistered")),
            SendOutcome::DropToken
        ));
    }

    #[test]
    fn classify_bad_device_token_drops() {
        assert!(matches!(
            classify(400, Some("BadDeviceToken")),
            SendOutcome::DropToken
        ));
        assert!(matches!(
            classify(400, Some("DeviceTokenNotForTopic")),
            SendOutcome::DropToken
        ));
    }

    #[test]
    fn classify_200_is_delivered() {
        assert!(matches!(classify(200, None), SendOutcome::Delivered));
    }

    #[test]
    fn classify_other_errors_are_transient() {
        assert!(matches!(
            classify(429, Some("TooManyRequests")),
            SendOutcome::Transient
        ));
        assert!(matches!(classify(500, None), SendOutcome::Transient));
    }

    #[test]
    fn apns_push_type_maps_kind() {
        assert!(matches!(
            apns_push_type(PushKind::Alert),
            a2::PushType::Alert
        ));
        assert!(matches!(apns_push_type(PushKind::Voip), a2::PushType::Voip));
    }
}
