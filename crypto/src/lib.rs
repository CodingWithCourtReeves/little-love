//! LittleLove protocol crypto primitives.
//!
//! Shared by `server/` and `bot/`. The module split mirrors the v0.2
//! design doc sections so future readers can follow spec → code easily.

pub mod aead;
pub mod ecdh;
pub mod identity;
pub mod invite;
pub mod sig;
pub mod wordlist;
