//! In-memory registry of call invites awaiting delivery.
//!
//! When a caller sends `CallInvite`, the server forwards it to any of the
//! callee's open sessions *and* holds it here briefly so a callee woken by a
//! VoIP push can fetch the encrypted offer once its WS (re)connects. Purely
//! ephemeral — no SDP ever touches disk (E2EE: the offer is opaque ciphertext
//! anyway, but we still never persist it).

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long a held invite lives before it's swept — the ring timeout (35s) plus
/// slack for the callee's cold-start + WS reconnect.
pub const PENDING_TTL: Duration = Duration::from_secs(45);

/// One held call invite addressed to a callee.
#[derive(Debug, Clone)]
pub struct Pending {
    pub call_id: String,
    pub room_id: String,
    /// Caller username (becomes `CallInvite.from` on delivery).
    pub from: String,
    /// Encrypted SDP offer (opaque to the server).
    pub offer: String,
    /// Whether this is a video call (shapes the woken callee's CallKit screen).
    pub video: bool,
    pub expires_at: Instant,
}

/// Thread-safe map of callee `account_id` → outstanding invites. A couple only
/// ever has one live call, but we keep a small vec per account for robustness
/// across rapid reconnects / glare.
#[derive(Default)]
pub struct PendingCalls {
    inner: Mutex<HashMap<i64, Vec<Pending>>>,
}

impl PendingCalls {
    pub fn new() -> Self {
        Self::default()
    }

    /// Hold an invite for `callee_account_id`.
    pub fn insert(&self, callee_account_id: i64, p: Pending) {
        self.inner
            .lock()
            .unwrap()
            .entry(callee_account_id)
            .or_default()
            .push(p);
    }

    /// Take (and remove) all still-valid invites for a callee — called when the
    /// callee's WS connects so it can resume a call it was woken for.
    pub fn take_for(&self, callee_account_id: i64, now: Instant) -> Vec<Pending> {
        match self.inner.lock().unwrap().remove(&callee_account_id) {
            Some(v) => v.into_iter().filter(|p| p.expires_at > now).collect(),
            None => Vec::new(),
        }
    }

    /// Drop a specific held call (e.g. caller cancelled before the callee
    /// reconnected).
    pub fn remove(&self, callee_account_id: i64, call_id: &str) {
        let mut g = self.inner.lock().unwrap();
        if let Some(v) = g.get_mut(&callee_account_id) {
            v.retain(|p| p.call_id != call_id);
            if v.is_empty() {
                g.remove(&callee_account_id);
            }
        }
    }

    /// Sweep expired entries (run periodically).
    pub fn expire_due(&self, now: Instant) {
        self.inner.lock().unwrap().retain(|_, v| {
            v.retain(|p| p.expires_at > now);
            !v.is_empty()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending(call_id: &str, expires_at: Instant) -> Pending {
        Pending {
            call_id: call_id.into(),
            room_id: "room".into(),
            from: "court".into(),
            offer: "ENC".into(),
            video: false,
            expires_at,
        }
    }

    #[test]
    fn take_for_returns_then_clears() {
        let base = Instant::now();
        let pc = PendingCalls::new();
        pc.insert(7, pending("c1", base + Duration::from_secs(45)));

        let first = pc.take_for(7, base);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].call_id, "c1");
        // A second take finds nothing — take is destructive.
        assert!(pc.take_for(7, base).is_empty());
    }

    #[test]
    fn take_for_filters_expired() {
        let base = Instant::now();
        let pc = PendingCalls::new();
        pc.insert(7, pending("old", base + Duration::from_secs(45)));
        // Caller asks far in the future → the entry has expired.
        assert!(pc.take_for(7, base + Duration::from_secs(100)).is_empty());
    }

    #[test]
    fn remove_drops_named_call() {
        let base = Instant::now();
        let pc = PendingCalls::new();
        pc.insert(7, pending("c1", base + Duration::from_secs(45)));
        pc.insert(7, pending("c2", base + Duration::from_secs(45)));
        pc.remove(7, "c1");
        let left = pc.take_for(7, base);
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].call_id, "c2");
    }

    #[test]
    fn expire_due_clears_old_entries() {
        let base = Instant::now();
        let pc = PendingCalls::new();
        pc.insert(7, pending("old", base + Duration::from_secs(10)));
        pc.insert(8, pending("fresh", base + Duration::from_secs(60)));
        pc.expire_due(base + Duration::from_secs(30));
        assert!(pc.take_for(7, base).is_empty(), "old swept");
        assert_eq!(pc.take_for(8, base).len(), 1, "fresh kept");
    }
}
