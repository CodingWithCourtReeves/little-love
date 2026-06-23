use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

use crate::wire::RoomServerFrame;

pub type Sender = mpsc::UnboundedSender<RoomServerFrame>;

/// Routes server frames to all open WSS sessions for a given username.
/// One user can have multiple concurrent sessions (spec §7), so the
/// inner value is a `Vec<Sender>` rather than a single channel.
#[derive(Debug, Default, Clone)]
pub struct Routing {
    inner: Arc<RwLock<HashMap<String, Vec<Sender>>>>,
}

impl Routing {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a sender for `username`. Multiple senders coexist; each open
    /// session gets its own.
    pub async fn register(&self, username: String, sender: Sender) {
        self.inner
            .write()
            .await
            .entry(username)
            .or_default()
            .push(sender);
    }

    /// Drop one specific sender from `username`'s list. Identity is by
    /// the underlying channel pointer (`same_channel`).
    pub async fn unregister(&self, username: &str, sender: &Sender) {
        let mut guard = self.inner.write().await;
        if let Some(senders) = guard.get_mut(username) {
            senders.retain(|s| !s.same_channel(sender));
            if senders.is_empty() {
                guard.remove(username);
            }
        }
    }

    /// Whether `username` has at least one open session — i.e. is online.
    pub async fn is_online(&self, username: &str) -> bool {
        self.inner.read().await.contains_key(username)
    }

    /// Fan-out a frame to every open session for `username`. Returns the
    /// number of sessions the frame was queued for. Closed senders are
    /// pruned implicitly on the next register/unregister.
    pub async fn deliver(&self, username: &str, frame: RoomServerFrame) -> usize {
        let guard = self.inner.read().await;
        let Some(senders) = guard.get(username) else {
            return 0;
        };
        let mut delivered = 0;
        for tx in senders {
            if tx.send(frame.clone()).is_ok() {
                delivered += 1;
            }
        }
        delivered
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{error_codes, RoomServerFrame};

    fn err_frame() -> RoomServerFrame {
        RoomServerFrame::Error {
            code: error_codes::UNKNOWN_ROOM.into(),
            message: "".into(),
        }
    }

    #[tokio::test]
    async fn deliver_returns_zero_when_offline() {
        let r = Routing::new();
        assert_eq!(r.deliver("kaitlyn", err_frame()).await, 0);
    }

    #[tokio::test]
    async fn is_online_tracks_sessions() {
        let r = Routing::new();
        assert!(!r.is_online("kaitlyn").await);
        let (tx, _rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx.clone()).await;
        assert!(r.is_online("kaitlyn").await);
        r.unregister("kaitlyn", &tx).await;
        assert!(!r.is_online("kaitlyn").await);
    }

    #[tokio::test]
    async fn deliver_reaches_a_single_session() {
        let r = Routing::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx).await;
        assert_eq!(r.deliver("kaitlyn", err_frame()).await, 1);
        assert!(rx.recv().await.is_some());
    }

    #[tokio::test]
    async fn deliver_fans_out_to_all_sessions() {
        let r = Routing::new();
        let (tx1, mut rx1) = mpsc::unbounded_channel();
        let (tx2, mut rx2) = mpsc::unbounded_channel();
        r.register("court".into(), tx1).await;
        r.register("court".into(), tx2).await;
        assert_eq!(r.deliver("court", err_frame()).await, 2);
        assert!(rx1.recv().await.is_some());
        assert!(rx2.recv().await.is_some());
    }

    #[tokio::test]
    async fn unregister_drops_only_the_named_sender() {
        let r = Routing::new();
        let (tx1, mut rx1) = mpsc::unbounded_channel();
        let (tx2, mut rx2) = mpsc::unbounded_channel();
        r.register("court".into(), tx1.clone()).await;
        r.register("court".into(), tx2.clone()).await;
        r.unregister("court", &tx1).await;
        assert_eq!(r.deliver("court", err_frame()).await, 1);
        // tx1's rx should NOT have received the post-unregister delivery.
        // The pre-unregister state had nothing buffered; rx1 sees nothing now.
        let try_rx1 = tokio::time::timeout(std::time::Duration::from_millis(50), rx1.recv()).await;
        assert!(
            try_rx1.is_err(),
            "rx1 should have no message after unregister"
        );
        assert!(rx2.recv().await.is_some());
    }
}
