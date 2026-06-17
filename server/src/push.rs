//! Push-notification composition + the `PushSender` seam. The actual APNs
//! transport (`ApnsSender`) lives behind the `PushSender` trait so the
//! send-trigger and token-hygiene logic is testable without a network.

use async_trait::async_trait;

/// Notification copy — generic and content-free (E2EE: the server never sees
/// the message, and we deliberately don't show content).
pub const PUSH_TITLE: &str = "Little Love";
pub const PUSH_BODY: &str = "💜 Your partner sent you a message";

/// One addressed push: the device token, its APNs environment, and the opaque
/// room id carried as custom data for tap deep-linking.
#[derive(Debug, Clone)]
pub struct PushMessage {
    pub token: String,
    pub environment: String,
    pub room_id: String,
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

/// We push only when the live fan-out reached zero sessions: an online partner
/// already got the message in-app and must not get a redundant banner.
pub fn should_push(delivered_sessions: usize) -> bool {
    delivered_sessions == 0
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pushes_only_when_no_live_session() {
        assert!(should_push(0));
        assert!(!should_push(1));
        assert!(!should_push(3));
    }

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
}
