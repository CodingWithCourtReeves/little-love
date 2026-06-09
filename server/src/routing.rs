use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

use crate::wire::ServerFrame;

pub type Sender = mpsc::UnboundedSender<ServerFrame>;

#[derive(Debug, Default, Clone)]
pub struct Routing {
    inner: Arc<RwLock<HashMap<String, Sender>>>,
}

impl Routing {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, username: String, sender: Sender) {
        self.inner.write().await.insert(username, sender);
    }

    pub async fn unregister(&self, username: &str) {
        self.inner.write().await.remove(username);
    }

    /// Send to the recipient if they have an active connection.
    /// Returns true if delivered.
    pub async fn deliver(&self, recipient: &str, frame: ServerFrame) -> bool {
        let guard = self.inner.read().await;
        match guard.get(recipient) {
            Some(tx) => tx.send(frame).is_ok(),
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::MsgPayload;
    use uuid::Uuid;

    fn msg(from: &str, to: &str, body: &str) -> ServerFrame {
        ServerFrame::Msg(MsgPayload {
            id: Uuid::new_v4(),
            from: from.into(),
            to: to.into(),
            body: body.into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: false,
        })
    }

    #[tokio::test]
    async fn deliver_returns_false_when_recipient_offline() {
        let r = Routing::new();
        assert!(!r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
    }

    #[tokio::test]
    async fn deliver_returns_true_and_sends_when_recipient_online() {
        let r = Routing::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx).await;
        assert!(r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
        let received = rx.recv().await.unwrap();
        match received {
            ServerFrame::Msg(m) => assert_eq!(m.body, "hi"),
        }
    }

    #[tokio::test]
    async fn unregister_drops_the_sender() {
        let r = Routing::new();
        let (tx, _rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx).await;
        r.unregister("kaitlyn").await;
        assert!(!r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
    }
}
