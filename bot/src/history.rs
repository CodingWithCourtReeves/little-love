//! Bounded in-memory conversation history.
//!
//! Items are role-tagged so we can shape OpenAI chat-completions messages.

use std::collections::VecDeque;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

#[derive(Debug, Clone)]
pub struct Turn {
    pub role: Role,
    pub content: String,
}

pub struct History {
    cap: usize,
    buf: VecDeque<Turn>,
}

impl History {
    pub fn new(cap: usize) -> Self {
        Self {
            cap: cap.max(1),
            buf: VecDeque::with_capacity(cap),
        }
    }

    pub fn push(&mut self, role: Role, content: String) {
        if self.buf.len() == self.cap {
            self.buf.pop_front();
        }
        self.buf.push_back(Turn { role, content });
    }

    pub fn iter(&self) -> impl Iterator<Item = &Turn> {
        self.buf.iter()
    }
    pub fn len(&self) -> usize {
        self.buf.len()
    }
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eviction_drops_oldest() {
        let mut h = History::new(3);
        h.push(Role::User, "a".into());
        h.push(Role::Assistant, "b".into());
        h.push(Role::User, "c".into());
        h.push(Role::Assistant, "d".into());
        let items: Vec<_> = h.iter().map(|t| t.content.clone()).collect();
        assert_eq!(items, vec!["b", "c", "d"]);
    }

    #[test]
    fn capacity_of_zero_clamps_to_one() {
        let mut h = History::new(0);
        h.push(Role::User, "x".into());
        assert_eq!(h.len(), 1);
    }
}
