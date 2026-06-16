//! LittleLove protocol crypto primitives.
//!
//! Used by `server/`. The module split mirrors the design doc sections so
//! future readers can follow spec → code easily.

pub mod aead;
pub mod ecdh;
pub mod identity;
pub mod invite;
pub mod sig;
pub mod wordlist;
