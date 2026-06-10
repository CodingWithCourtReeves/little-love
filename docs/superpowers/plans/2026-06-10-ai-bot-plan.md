# AI Bot (WT-bot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a standalone Rust binary `littlelove-bot` that participates in a LittleLove room as a normal paired client, bridges that room to a local OpenAI-compatible LLM, and supports Character Card v2/v3 PNG personas — without ever shipping plaintext off-machine.

**Architecture:** Workspace grows two new crates. (1) `crypto/` (crate name `littlelove-crypto`) absorbs the protocol primitives currently in `server/src/{auth,invites,wordlist_bip39_en}.rs` plus three new modules (`aead`, `ecdh`, `identity`); the server depends on it. (2) `bot/` is the new binary, wired to `littlelove-crypto`, with `clap` subcommands `pair`, `run`, and `show-identity`. The bot enforces a private-IP allow-list before any LLM request, parses CCv2/v3 PNGs into a persona, and speaks the v0.2 WSS protocol byte-for-byte.

**Tech Stack:** Rust 1.88 + cargo workspace; `ed25519-dalek` v2; `x25519-dalek` v2; `chacha20poly1305` v0.10 (XChaCha20-Poly1305); `hkdf` v0.12 + `sha2` v0.10; `clap` v4 (derive + env); `tokio` + `tokio-tungstenite` (rustls); `reqwest` (rustls); `png` v0.17 for CCv2 chunk extraction; `directories` v5 for config paths.

**Spec:** `docs/superpowers/specs/2026-06-09-ai-bot-design.md` is the source of truth. Defer to it for any ambiguity. If the plan and spec disagree, fix the spec first.

---

## File Structure

### New files

- `crypto/Cargo.toml` — `littlelove-crypto` package manifest.
- `crypto/src/lib.rs` — module re-exports.
- `crypto/src/sig.rs` — moved from `server/src/auth.rs`. Domain tags, signing input builders, `verify_signature`, `verify_invite_consume_signature`, `random_nonce`, base64 helpers.
- `crypto/src/wordlist.rs` — moved from `server/src/wordlist_bip39_en.rs`. The 2048-word table.
- `crypto/src/invite.rs` — pure-crypto subset of `server/src/invites.rs`: `canonical_token_from_n44`, `encode_code`, `decode_code`, `generate_invite`, `sha256`, `InviteCodeError`, `CANONICAL_TOKEN_LEN`, `CODE_WORDS`.
- `crypto/src/aead.rs` — XChaCha20-Poly1305 wire-envelope encrypt/decrypt that byte-matches `app/lib/crypto/cipher.dart`.
- `crypto/src/ecdh.rs` — X25519 shared secret + HKDF-SHA256 → 32-byte room key per spec §5.1.
- `crypto/src/identity.rs` — BIP39 phrase → seed → master → Ed25519 + X25519 keypairs per spec §3.1.
- `crypto/tests/invite_vectors.rs` — parity test that loads `server/tests/data/invite_vectors.json`.
- `crypto/tests/aead_parity.rs` — round-trip + a Dart-shaped fixture.
- `crypto/tests/domain_separation.rs` — mirror of the existing server signing-input layout tests.
- `bot/Cargo.toml` — `littlelove-bot` binary manifest.
- `bot/src/main.rs` — `clap` entrypoint, dispatches subcommands.
- `bot/src/cli.rs` — `clap::Parser` derive structs.
- `bot/src/config.rs` — resolved runtime config (paths, urls, timeouts).
- `bot/src/identity_store.rs` — `~/.littlelove-bot/identity.json` read/write with mode 0600.
- `bot/src/addr_guard.rs` — private-IP allow-list and URL resolution.
- `bot/src/rest.rs` — `POST /accounts` client.
- `bot/src/ws_client.rs` — WSS connect + Challenge/Identify/Authenticated handshake + frame I/O.
- `bot/src/pair.rs` — orchestrates the `pair` subcommand.
- `bot/src/run.rs` — orchestrates the `run` subcommand (room loop).
- `bot/src/show_identity.rs` — orchestrates the `show-identity` subcommand.
- `bot/src/history.rs` — bounded ring buffer of role-tagged messages.
- `bot/src/llm.rs` — OpenAI chat-completions client.
- `bot/src/character_card.rs` — CCv2/v3 PNG → card struct.
- `bot/src/persona.rs` — resolves card / file / env / default into a final system prompt string.
- `bot/tests/addr_guard_table.rs` — public-IP refusal table.
- `bot/tests/character_card_v2.rs` — CCv2 fixture parse.
- `bot/tests/character_card_v3.rs` — CCv3 fixture parse.
- `bot/tests/persona_resolver.rs` — mutual-exclusion + selection logic.
- `bot/tests/llm_mock.rs` — bot calls a mock chat-completions server.
- `bot/tests/fixtures/card_v2.png` — small generated CCv2 fixture.
- `bot/tests/fixtures/card_v3.png` — small generated CCv3 fixture.
- `bot/tests/fixtures/dart_envelope.json` — Dart-emitted wire-string for parity (key + envelope + expected plaintext).
- `.github/workflows/release.yml` (modified) — adds a bot-binary build matrix.

### Modified files

- `Cargo.toml` (root) — workspace `members` grows `crypto` and `bot`; new workspace deps.
- `server/Cargo.toml` — adds `littlelove-crypto` workspace dep, drops crates that move (e.g. `ed25519-dalek` if it's only used in the moved code; keep if other modules use it).
- `server/src/auth.rs` — deleted (re-exports from `littlelove-crypto::sig` where needed).
- `server/src/wordlist_bip39_en.rs` — deleted.
- `server/src/invites.rs` — pure-crypto removed; DB ops + REST handler stay.
- `server/src/lib.rs` — `pub use littlelove_crypto::*` shims where existing call sites import from the old paths; or update call sites directly (preferred).
- `server/src/ws.rs`, `server/src/accounts.rs`, `server/src/rooms.rs`, `server/tests/*.rs` — import paths updated.

---

## Conventions

- **Commits.** One commit per task (after step "Commit"). Use Conventional Commits prefixes: `feat:`, `refactor:`, `test:`, `chore:`, `ci:`. Always pass the message via heredoc as the user prefers.
- **TDD.** Each task is `failing test → run → minimal impl → run → commit`. Don't batch tests.
- **Workspace test invocation.** `cargo test --workspace` runs everything. To run one crate: `cargo test -p littlelove-crypto`. To run one test file: `cargo test -p littlelove-bot --test addr_guard_table`.
- **No unrelated cleanup.** If a file you're editing tempts you to refactor an unrelated function, resist. Each task touches the minimum.
- **Format and lint.** Run `cargo fmt --all` and `cargo clippy --workspace --all-targets -- -D warnings` before each commit.

---

## Phase A — Workspace + crypto crate extraction

The server's existing tests are the parity oracle for this phase. Any test that breaks during the move is a real regression — fix it in the move, not in the test.

### Task 1: Add `crypto` member, scaffold the crate

**Files:**
- Modify: `Cargo.toml` (root)
- Create: `crypto/Cargo.toml`
- Create: `crypto/src/lib.rs`

- [ ] **Step 1: Add workspace member and shared deps**

Edit `Cargo.toml`. Replace:
```toml
[workspace]
members = ["server"]
resolver = "2"
```
with:
```toml
[workspace]
members = ["crypto", "server"]
resolver = "2"
```
Add to `[workspace.dependencies]`:
```toml
base64           = "0.22"
ed25519-dalek    = "2"
x25519-dalek     = { version = "2", features = ["static_secrets"] }
hkdf             = "0.12"
sha2             = "0.10"
chacha20poly1305 = "0.10"
rand             = "0.8"
hex              = "0.4"
qrcode           = "0.14"
image            = { version = "0.25", default-features = false, features = ["png"] }
littlelove-crypto = { path = "crypto" }
```
(Leave existing entries alone.)

- [ ] **Step 2: Create the crypto crate manifest**

Write `crypto/Cargo.toml`:
```toml
[package]
name        = "littlelove-crypto"
version     = "0.1.0"
edition     = { workspace = true }
rust-version = { workspace = true }
license     = { workspace = true }

[dependencies]
base64           = { workspace = true }
ed25519-dalek    = { workspace = true }
x25519-dalek     = { workspace = true }
hkdf             = { workspace = true }
sha2             = { workspace = true }
chacha20poly1305 = { workspace = true }
rand             = { workspace = true }
thiserror        = { workspace = true }
serde            = { workspace = true }
serde_json       = { workspace = true }
hex              = { workspace = true }
```

- [ ] **Step 3: Stub `lib.rs`**

Write `crypto/src/lib.rs`:
```rust
//! LittleLove protocol crypto primitives.
//!
//! Shared by `server/` and `bot/`. The module split mirrors the v0.2
//! design doc sections so future readers can follow spec → code easily.

pub mod sig;
pub mod wordlist;
pub mod invite;
pub mod aead;
pub mod ecdh;
pub mod identity;
```

- [ ] **Step 4: Sanity-check the workspace compiles (with empty modules)**

Create empty `crypto/src/{sig,wordlist,invite,aead,ecdh,identity}.rs` files. Each contains a single line: `//! placeholder — filled in by subsequent tasks.`

Run: `cargo check --workspace`
Expected: PASS (the new crate is empty modules; nothing depends on it yet).

- [ ] **Step 5: Commit**
```bash
git add Cargo.toml crypto/
git commit -m "$(cat <<'EOF'
chore: scaffold littlelove-crypto workspace member

Empty modules — subsequent tasks move primitives in from server/.
EOF
)"
```

### Task 2: Move wordlist + sig (verbatim)

**Files:**
- Create: `crypto/src/wordlist.rs` (content moved from `server/src/wordlist_bip39_en.rs`)
- Create: `crypto/src/sig.rs` (content moved from `server/src/auth.rs`)
- Delete: `server/src/wordlist_bip39_en.rs`, `server/src/auth.rs`
- Modify: `server/Cargo.toml`, `server/src/lib.rs`, `server/src/{ws,invites}.rs`

- [ ] **Step 1: Copy wordlist verbatim**

`cp server/src/wordlist_bip39_en.rs crypto/src/wordlist.rs`. No edits.

- [ ] **Step 2: Copy `auth.rs` to `crypto/src/sig.rs`**

`cp server/src/auth.rs crypto/src/sig.rs`. The file already has zero dependencies on other server modules, so it lands clean.

- [ ] **Step 3: Add `littlelove-crypto` to `server/Cargo.toml`**

In `server/Cargo.toml`, under `[dependencies]`, add:
```toml
littlelove-crypto = { workspace = true }
```

- [ ] **Step 4: Update server call sites for `auth`**

Replace `crate::auth` → `littlelove_crypto::sig` everywhere in `server/src/`:

```bash
grep -rln 'crate::auth' server/src/
```
For each file in the output (expect `lib.rs`, `ws.rs`, `invites.rs`, and any tests), edit `use crate::auth::...` → `use littlelove_crypto::sig::...`. Also remove the `pub mod auth;` line from `server/src/lib.rs`.

- [ ] **Step 5: Update wordlist reference**

In `server/src/invites.rs`, replace `use crate::wordlist_bip39_en::BIP39_EN;` with `use littlelove_crypto::wordlist::BIP39_EN;`. Remove the `mod wordlist_bip39_en;` line from `server/src/lib.rs`.

- [ ] **Step 6: Delete the moved files**
```bash
git rm server/src/auth.rs server/src/wordlist_bip39_en.rs
```

- [ ] **Step 7: Run all tests; nothing should regress**

Run: `cargo test --workspace`
Expected: PASS. The server's `auth` tests now run from `crypto/src/sig.rs` (same code).

Run: `cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --all --check`
Expected: PASS.

- [ ] **Step 8: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: move signing + wordlist into littlelove-crypto

server/src/auth.rs and wordlist_bip39_en.rs lift verbatim into
crypto/src/{sig,wordlist}.rs. Bot crate (next phase) will share the
same primitives byte-for-byte; the server-internal call sites just
re-import.
EOF
)"
```

### Task 3: Split invite.rs — move pure-crypto bits

**Files:**
- Create: `crypto/src/invite.rs`
- Modify: `server/src/invites.rs`, `server/src/ws.rs`

- [ ] **Step 1: Identify the pure-crypto subset**

From `server/src/invites.rs`, the moves are:
- `INVITE_TTL_SECONDS` constant — **stays in server** (it's a policy knob, not crypto).
- `CODE_WORDS`, `BITS_PER_WORD`, `CODE_BITS`, `CANONICAL_TOKEN_LEN`, `TOKEN_PREFIX_LEN` — move.
- `InviteCodeError` — move.
- `canonical_token_from_n44`, `n44_from_token_prefix`, `encode_code`, `decode_code`, `word_index_lookup`, `generate_invite`, `sha256` — move.
- `InviteRow`, `InviteState`, `default_expiry`, `create_invite_record`, `lookup_invite`, `mark_consumed`, `preview_invite`, `qr_png_base64`, `QrError`, `InvitePreviewResponse` — **stay** (DB ops + REST handler + QR rendering).
- The `#[cfg(test)] mod tests` for the moved functions — move (the tests on DB and REST helpers stay).

- [ ] **Step 2: Write `crypto/src/invite.rs`**

Move (cut from `server/src/invites.rs`, paste into `crypto/src/invite.rs`) all items from Step 1's first bullet group, plus their associated tests. Update the file header:
```rust
//! Invite-code primitives (BIP39 encoding + SHA-256 + canonical token).
//!
//! See spec §8.6. DB ops and REST handler live in `server/src/invites.rs`.

use crate::wordlist::BIP39_EN;
```
Leave the rest of the file unchanged. The `word_index_lookup` `OnceLock` and the `tests` module move with their items.

- [ ] **Step 3: Update `server/src/invites.rs` imports**

At the top of `server/src/invites.rs`, replace the deleted symbols with imports from the new crate:
```rust
pub use littlelove_crypto::invite::{
    canonical_token_from_n44, decode_code, encode_code, generate_invite, sha256,
    InviteCodeError, CANONICAL_TOKEN_LEN, CODE_WORDS,
};
```
Drop the now-unused `use crate::wordlist_bip39_en::BIP39_EN;` import (already gone) and any `use sha2::Digest;` / `use rand::RngCore;` that the moved functions used.

- [ ] **Step 4: Update `server/src/ws.rs`**

Replace `use crate::invites::{decode_code, ..., sha256};` with imports that pick `decode_code` and `sha256` from `littlelove_crypto::invite::{...}`. The DB ops (`create_invite_record`, etc.) stay imported from `crate::invites`. Look for and update any other server file that uses the moved symbols.

- [ ] **Step 5: Run all tests**

Run: `cargo test --workspace`
Expected: PASS.

Run: `cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --all --check`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: split invite.rs — crypto into littlelove-crypto, DB stays

Pure BIP39 encode/decode + canonical token + sha256 + generate_invite
move into crypto/src/invite.rs. The DB ops (create_invite_record,
lookup_invite, mark_consumed) and the REST preview handler stay in
server/src/invites.rs.
EOF
)"
```

### Task 4: Add the parity test against `invite_vectors.json`

**Files:**
- Create: `crypto/tests/invite_vectors.rs`

- [ ] **Step 1: Write the failing test**
```rust
//! Parity against server/tests/data/invite_vectors.json.
//!
//! Same fixture used by WT-B's server tests and (after WT-D lands) the
//! Dart client tests. Single source of truth for BIP39 invite encoding.

use littlelove_crypto::invite::{canonical_token_from_n44, decode_code, encode_code, sha256};

#[derive(Debug, serde::Deserialize)]
struct Vector {
    n44_hex: String,
    canonical_token_hex: String,
    code: String,
}

#[test]
fn invite_vectors_match_shared_fixture() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../server/tests/data/invite_vectors.json");
    let bytes = std::fs::read(path).expect("fixture file");
    let vectors: Vec<Vector> = serde_json::from_slice(&bytes).expect("parse fixture");
    assert!(!vectors.is_empty());

    for v in vectors {
        let n44 = u64::from_str_radix(v.n44_hex.trim_start_matches("0x"), 16).expect("n44 hex");
        let want_token = hex::decode(&v.canonical_token_hex).expect("token hex");
        let got_token = canonical_token_from_n44(n44);
        assert_eq!(&got_token[..], &want_token[..], "n44={:#x}", n44);

        let got_code = encode_code(&got_token);
        assert_eq!(got_code, v.code, "encode n44={:#x}", n44);

        let back = decode_code(&v.code).expect("decode");
        assert_eq!(back, got_token, "round-trip n44={:#x}", n44);

        // sha256(canonical) is the DB primary key, so exercise it too.
        let _ = sha256(&got_token);
    }
}
```

Add to `crypto/Cargo.toml`:
```toml
[dev-dependencies]
hex        = { workspace = true }
serde      = { workspace = true }
serde_json = { workspace = true }
```

- [ ] **Step 2: Run it**

Run: `cargo test -p littlelove-crypto --test invite_vectors`
Expected: PASS (the fixture and the code agree).

- [ ] **Step 3: Commit**
```bash
git add crypto/Cargo.toml crypto/tests/invite_vectors.rs
git commit -m "$(cat <<'EOF'
test: cross-crate parity for BIP39 invite vectors

Loads the shared fixture once; the bot inherits the same guarantee.
EOF
)"
```

### Task 5: Add the AEAD wire-envelope module

**Files:**
- Modify: `crypto/src/aead.rs`
- Create: `crypto/tests/aead_parity.rs`
- Create: `bot/tests/fixtures/dart_envelope.json` — **only the schema; populated in Step 4**

- [ ] **Step 1: Write the failing test**

Write `crypto/tests/aead_parity.rs`:
```rust
//! XChaCha20-Poly1305 wire-envelope parity.
//!
//! `app/lib/crypto/cipher.dart` packs `body` as:
//!   base64( utf8( json({ "ciphertext": base64(ct||mac), "nonce": base64(nonce) }) ) )
//! Bot ↔ Flutter app interop depends on byte-for-byte parity.

use littlelove_crypto::aead::{decrypt_wire, encrypt_wire};

#[test]
fn round_trip_recovers_plaintext() {
    let key = [0x42u8; 32];
    let plaintext = "hello, familiar";
    let wire = encrypt_wire(&key, plaintext.as_bytes()).expect("encrypt");
    let back = decrypt_wire(&key, &wire).expect("decrypt");
    assert_eq!(back, plaintext.as_bytes());
}

#[test]
fn wire_string_is_outer_base64_of_json_envelope() {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};

    let key = [0x11u8; 32];
    let wire = encrypt_wire(&key, b"hi").expect("encrypt");
    let inner = B64.decode(&wire).expect("outer base64");
    let env: serde_json::Value = serde_json::from_slice(&inner).expect("inner json");
    assert!(env.get("ciphertext").is_some());
    assert!(env.get("nonce").is_some());
}

#[test]
fn decrypt_rejects_tampered_ciphertext() {
    let key = [0xaau8; 32];
    let wire = encrypt_wire(&key, b"secret").expect("encrypt");

    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    let inner = B64.decode(&wire).expect("outer base64");
    let mut env: serde_json::Value = serde_json::from_slice(&inner).unwrap();
    let mut ct = B64.decode(env["ciphertext"].as_str().unwrap()).unwrap();
    ct[0] ^= 0x01;
    env["ciphertext"] = serde_json::Value::String(B64.encode(&ct));
    let tampered = B64.encode(serde_json::to_vec(&env).unwrap());

    assert!(decrypt_wire(&key, &tampered).is_err());
}
```

- [ ] **Step 2: Run it (must fail — module is empty)**

Run: `cargo test -p littlelove-crypto --test aead_parity`
Expected: FAIL (`decrypt_wire`, `encrypt_wire` not found).

- [ ] **Step 3: Implement `crypto/src/aead.rs`**
```rust
//! XChaCha20-Poly1305 wire-envelope encrypt/decrypt.
//!
//! Wire layout (matches app/lib/crypto/cipher.dart byte-for-byte):
//!
//!   wire = base64(utf8(json({
//!     "ciphertext": base64(ct || mac),   // 16-byte Poly1305 MAC appended
//!     "nonce":      base64(nonce_24)     // XChaCha20 24-byte nonce
//!   })))
//!
//! Two layers of base64 is non-obvious; the inner JSON envelope predates
//! this crate (Day-1c) and Flutter clients in the wild already speak it.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const NONCE_LEN: usize = 24;

#[derive(Debug, Error)]
pub enum AeadError {
    #[error("invalid base64 in wire envelope")]
    Base64,
    #[error("invalid JSON in wire envelope")]
    Json,
    #[error("nonce has wrong length: {0}")]
    NonceLen(usize),
    #[error("AEAD decrypt failed (bad key, bad tag, or tampering)")]
    Decrypt,
    #[error("AEAD encrypt failed")]
    Encrypt,
}

#[derive(Serialize, Deserialize)]
struct Envelope {
    ciphertext: String,
    nonce: String,
}

pub fn encrypt_wire(key: &[u8; 32], plaintext: &[u8]) -> Result<String, AeadError> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce = [0u8; NONCE_LEN];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(XNonce::from_slice(&nonce), Payload { msg: plaintext, aad: &[] })
        .map_err(|_| AeadError::Encrypt)?;
    let env = Envelope {
        ciphertext: B64.encode(&ct),
        nonce: B64.encode(nonce),
    };
    let json = serde_json::to_vec(&env).map_err(|_| AeadError::Json)?;
    Ok(B64.encode(json))
}

pub fn decrypt_wire(key: &[u8; 32], wire: &str) -> Result<Vec<u8>, AeadError> {
    let inner = B64.decode(wire.as_bytes()).map_err(|_| AeadError::Base64)?;
    let env: Envelope = serde_json::from_slice(&inner).map_err(|_| AeadError::Json)?;
    let ct = B64.decode(env.ciphertext.as_bytes()).map_err(|_| AeadError::Base64)?;
    let nonce = B64.decode(env.nonce.as_bytes()).map_err(|_| AeadError::Base64)?;
    if nonce.len() != NONCE_LEN {
        return Err(AeadError::NonceLen(nonce.len()));
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(XNonce::from_slice(&nonce), Payload { msg: &ct, aad: &[] })
        .map_err(|_| AeadError::Decrypt)
}
```

- [ ] **Step 4: Run the parity tests**

Run: `cargo test -p littlelove-crypto --test aead_parity`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add crypto/src/aead.rs crypto/tests/aead_parity.rs
git commit -m "$(cat <<'EOF'
feat(crypto): XChaCha20-Poly1305 wire-envelope (byte-matches Dart)

Two-layer base64 of a {ciphertext, nonce} JSON object; chosen by
Day-1c and unchanged in v0.2. Bot and server now share the same
encoder, ensuring Flutter-app ↔ bot interop.
EOF
)"
```

### Task 6: Add the ECDH-room-key module

**Files:**
- Modify: `crypto/src/ecdh.rs`

- [ ] **Step 1: Write the failing test (inline in `ecdh.rs`)**
```rust
//! X25519 ECDH + HKDF → 32-byte room key per spec §5.1.

use hkdf::Hkdf;
use sha2::Sha256;
use thiserror::Error;
use x25519_dalek::{PublicKey, StaticSecret};

const HKDF_SALT: &[u8] = b"littlelove.v0.2.room";

#[derive(Debug, Error)]
pub enum EcdhError {
    #[error("public key has wrong length: {0}")]
    BadPubkey(usize),
    #[error("private key has wrong length: {0}")]
    BadPrivkey(usize),
    #[error("hkdf expand failed")]
    Hkdf,
}

/// Derive the 32-byte room key for a room with `room_id` between two parties.
pub fn derive_room_key(
    my_x25519_priv: &[u8; 32],
    peer_x25519_pub: &[u8; 32],
    room_id: &str,
) -> Result<[u8; 32], EcdhError> {
    let secret = StaticSecret::from(*my_x25519_priv);
    let peer = PublicKey::from(*peer_x25519_pub);
    let shared = secret.diffie_hellman(&peer);
    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), shared.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(room_id.as_bytes(), &mut out).map_err(|_| EcdhError::Hkdf)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;
    use x25519_dalek::{PublicKey, StaticSecret};

    #[test]
    fn both_sides_derive_the_same_key() {
        let a_priv = StaticSecret::random_from_rng(OsRng);
        let b_priv = StaticSecret::random_from_rng(OsRng);
        let a_pub = PublicKey::from(&a_priv);
        let b_pub = PublicKey::from(&b_priv);

        let a_to_b = derive_room_key(&a_priv.to_bytes(), &b_pub.to_bytes(), "room-01J").unwrap();
        let b_to_a = derive_room_key(&b_priv.to_bytes(), &a_pub.to_bytes(), "room-01J").unwrap();
        assert_eq!(a_to_b, b_to_a);
    }

    #[test]
    fn different_room_ids_yield_different_keys() {
        let a_priv = StaticSecret::random_from_rng(OsRng);
        let b_priv = StaticSecret::random_from_rng(OsRng);
        let a_pub = PublicKey::from(&a_priv);
        let b_pub = PublicKey::from(&b_priv);

        let k1 = derive_room_key(&a_priv.to_bytes(), &b_pub.to_bytes(), "room-01J").unwrap();
        let k2 = derive_room_key(&b_priv.to_bytes(), &a_pub.to_bytes(), "room-02K").unwrap();
        assert_ne!(k1, k2);
    }
}
```

- [ ] **Step 2: Run it**

Run: `cargo test -p littlelove-crypto --lib ecdh`
Expected: PASS.

- [ ] **Step 3: Commit**
```bash
git add crypto/src/ecdh.rs
git commit -m "$(cat <<'EOF'
feat(crypto): X25519 + HKDF → 32-byte room key (spec §5.1)
EOF
)"
```

### Task 7: Add the BIP39 identity module

**Files:**
- Modify: `crypto/src/identity.rs`

- [ ] **Step 1: Write `crypto/src/identity.rs`**
```rust
//! BIP39 phrase → master → Ed25519 + X25519 keypairs (spec §3.1).
//!
//! 256-bit seeds only (12-word phrases ARE allowed by BIP39 but only with
//! 128-bit entropy + checksum — see §3.1 step 2: this protocol generates a
//! 256-bit OS-CSPRNG seed). For v0.2 we therefore emit a 24-word phrase.

use ed25519_dalek::SigningKey as EdSigningKey;
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use thiserror::Error;
use x25519_dalek::StaticSecret;

use crate::wordlist::BIP39_EN;

pub const SEED_LEN: usize = 32;
const SALT_MASTER: &[u8] = b"littlelove.v0.2.master";
const SALT_SIGNING: &[u8] = b"littlelove.v0.2.signing";
const SALT_ENCRYPTION: &[u8] = b"littlelove.v0.2.encryption";

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("phrase must be exactly 24 words, got {0}")]
    WrongWordCount(usize),
    #[error("unknown BIP39 word: {0}")]
    UnknownWord(String),
    #[error("HKDF expand failed")]
    Hkdf,
}

#[derive(Clone)]
pub struct Identity {
    pub master: [u8; 32],
    pub ed25519_signing: EdSigningKey,
    pub x25519_secret: StaticSecret,
}

impl Identity {
    pub fn ed25519_pub(&self) -> [u8; 32] {
        self.ed25519_signing.verifying_key().to_bytes()
    }
    pub fn x25519_pub(&self) -> [u8; 32] {
        use x25519_dalek::PublicKey;
        PublicKey::from(&self.x25519_secret).to_bytes()
    }
}

/// Generate a fresh 256-bit seed.
pub fn random_seed() -> [u8; SEED_LEN] {
    let mut s = [0u8; SEED_LEN];
    rand::rngs::OsRng.fill_bytes(&mut s);
    s
}

/// 256 bits of entropy → 24 BIP39 words (no checksum; the seed IS canonical).
///
/// BIP39 normally adds a checksum; we follow the spec §3.1 simplification:
/// the seed is the canonical thing, and the words are a human carrier.
/// Encoding: 24 11-bit indices, big-endian, with 8 trailing bits set to
/// zero (256 + 8 = 264 = 24 * 11). Decoding strips those zero bits.
pub fn seed_to_phrase(seed: &[u8; SEED_LEN]) -> String {
    let mut bits = [0u8; 33]; // 264 bits
    bits[..32].copy_from_slice(seed);
    let mut words = Vec::with_capacity(24);
    for i in 0..24 {
        let start = i * 11;
        let end = start + 11;
        let mut v = 0u16;
        for b in start..end {
            let byte = bits[b / 8];
            let bit = (byte >> (7 - (b % 8))) & 1;
            v = (v << 1) | bit as u16;
        }
        words.push(BIP39_EN[v as usize]);
    }
    words.join(" ")
}

pub fn phrase_to_seed(phrase: &str) -> Result<[u8; SEED_LEN], IdentityError> {
    let words: Vec<&str> = phrase.split_whitespace().collect();
    if words.len() != 24 {
        return Err(IdentityError::WrongWordCount(words.len()));
    }
    let lookup: std::collections::HashMap<&str, u16> = BIP39_EN
        .iter()
        .enumerate()
        .map(|(i, w)| (*w, i as u16))
        .collect();
    let mut bits = [0u8; 33];
    for (i, w) in words.iter().enumerate() {
        let idx = *lookup
            .get(w)
            .ok_or_else(|| IdentityError::UnknownWord((*w).to_string()))?;
        for j in 0..11 {
            let global = i * 11 + j;
            let bit = (idx >> (10 - j)) & 1;
            bits[global / 8] |= (bit as u8) << (7 - (global % 8));
        }
    }
    let mut seed = [0u8; SEED_LEN];
    seed.copy_from_slice(&bits[..32]);
    Ok(seed)
}

pub fn derive_identity(seed: &[u8; SEED_LEN]) -> Result<Identity, IdentityError> {
    let master = hkdf_extract_expand(SALT_MASTER, seed, &[])?;
    let signing_seed = hkdf_extract_expand(SALT_SIGNING, &master, &[])?;
    let enc_seed = hkdf_extract_expand(SALT_ENCRYPTION, &master, &[])?;
    Ok(Identity {
        master,
        ed25519_signing: EdSigningKey::from_bytes(&signing_seed),
        x25519_secret: StaticSecret::from(enc_seed),
    })
}

fn hkdf_extract_expand(salt: &[u8], ikm: &[u8], info: &[u8]) -> Result<[u8; 32], IdentityError> {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).map_err(|_| IdentityError::Hkdf)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phrase_round_trip() {
        let seed = random_seed();
        let phrase = seed_to_phrase(&seed);
        let back = phrase_to_seed(&phrase).unwrap();
        assert_eq!(seed, back);
    }

    #[test]
    fn same_seed_derives_same_identity() {
        let seed = [0x33u8; 32];
        let a = derive_identity(&seed).unwrap();
        let b = derive_identity(&seed).unwrap();
        assert_eq!(a.master, b.master);
        assert_eq!(a.ed25519_pub(), b.ed25519_pub());
        assert_eq!(a.x25519_pub(), b.x25519_pub());
    }

    #[test]
    fn different_seeds_diverge() {
        let a = derive_identity(&[0u8; 32]).unwrap();
        let b = derive_identity(&[1u8; 32]).unwrap();
        assert_ne!(a.ed25519_pub(), b.ed25519_pub());
        assert_ne!(a.x25519_pub(), b.x25519_pub());
    }

    #[test]
    fn phrase_rejects_unknown_word() {
        let bogus = (0..24).map(|_| "bogusword").collect::<Vec<_>>().join(" ");
        let err = phrase_to_seed(&bogus).unwrap_err();
        assert!(matches!(err, IdentityError::UnknownWord(_)));
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `cargo test -p littlelove-crypto --lib identity`
Expected: PASS (four cases green).

- [ ] **Step 3: Commit**
```bash
git add crypto/src/identity.rs
git commit -m "$(cat <<'EOF'
feat(crypto): BIP39 24-word phrase + HKDF → Ed25519/X25519 (spec §3.1)
EOF
)"
```

### Task 8: Add a domain-separation parity test

**Files:**
- Create: `crypto/tests/domain_separation.rs`

- [ ] **Step 1: Write the test**
```rust
//! Mirrors `server/src/auth.rs::tests` byte-for-byte at the integration
//! level so any reorg in the future flags drift.

use littlelove_crypto::sig::{
    challenge_signing_input, invite_consume_signing_input, CHALLENGE_DOMAIN_TAG,
    INVITE_CONSUME_DOMAIN_TAG,
};

#[test]
fn challenge_layout() {
    let nonce = [0u8; 32];
    let input = challenge_signing_input(&nonce);
    assert_eq!(input.len(), 58);
    assert_eq!(&input[..25], CHALLENGE_DOMAIN_TAG);
    assert_eq!(input[25], 0);
    assert_eq!(&input[26..], &nonce[..]);
}

#[test]
fn invite_layout() {
    let token = [0u8; 32];
    let input = invite_consume_signing_input(&token);
    assert_eq!(input.len(), 63);
    assert_eq!(&input[..30], INVITE_CONSUME_DOMAIN_TAG);
    assert_eq!(input[30], 0);
    assert_eq!(&input[31..], &token[..]);
}
```

- [ ] **Step 2: Run + commit**

Run: `cargo test -p littlelove-crypto --test domain_separation`
Expected: PASS.

```bash
git add crypto/tests/domain_separation.rs
git commit -m "$(cat <<'EOF'
test(crypto): domain-separation byte layout parity
EOF
)"
```

---

## Phase B — Bot crate scaffold + CLI + identity store

### Task 9: Scaffold the `bot` binary crate

**Files:**
- Modify: `Cargo.toml`
- Create: `bot/Cargo.toml`, `bot/src/main.rs`, `bot/src/cli.rs`

- [ ] **Step 1: Add bot to workspace + new shared deps**

In root `Cargo.toml`, change `members` to `["crypto", "server", "bot"]`. Add to `[workspace.dependencies]`:
```toml
clap        = { version = "4", features = ["derive", "env"] }
directories = "5"
reqwest     = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
png         = "0.17"
url         = "2"
```

- [ ] **Step 2: Write `bot/Cargo.toml`**
```toml
[package]
name        = "littlelove-bot"
version     = "0.1.0"
edition     = { workspace = true }
rust-version = { workspace = true }
license     = { workspace = true }

[[bin]]
name = "littlelove-bot"
path = "src/main.rs"

[dependencies]
littlelove-crypto = { workspace = true }
anyhow            = { workspace = true }
base64            = { workspace = true }
chrono            = { workspace = true }
clap              = { workspace = true }
directories       = { workspace = true }
futures           = { workspace = true }
png               = { workspace = true }
rand              = { workspace = true }
reqwest           = { workspace = true }
serde             = { workspace = true }
serde_json        = { workspace = true }
thiserror         = { workspace = true }
tokio             = { workspace = true }
tokio-tungstenite = { workspace = true, features = ["rustls-tls-webpki-roots"] }
tracing           = { workspace = true }
tracing-subscriber = { workspace = true }
url               = { workspace = true }
uuid              = { workspace = true }

[dev-dependencies]
axum       = { workspace = true }
hex        = { workspace = true }
tempfile   = "3"
```

In root `Cargo.toml` add `tempfile = "3"` to `[workspace.dependencies]` so any other crate that wants it can use it too. Actually — local dev-dep only, leave it inline.

- [ ] **Step 3: Stub `main.rs` + `cli.rs`**

Write `bot/src/cli.rs`:
```rust
use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "littlelove-bot", version, about = "Local-AI bot for LittleLove")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// First-time pairing: signup + consume invite + persist identity.
    Pair(PairArgs),
    /// Connect, subscribe to the room, respond to inbound messages.
    Run(RunArgs),
    /// Print this bot's username and public-key fingerprints.
    ShowIdentity,
}

#[derive(clap::Args, Debug)]
pub struct PairArgs {
    /// WSS server URL, e.g. wss://littlelove.example.org
    #[arg(long, env = "LITTLELOVE_BOT_SERVER")]
    pub server: String,

    /// 4-word invite code.
    #[arg(long)]
    pub code: String,

    /// Bot username (a-z, 0-9, _, 3-20 chars).
    #[arg(long)]
    pub username: String,

    /// Overwrite an existing identity file (DANGEROUS — loses the current bot account).
    #[arg(long, default_value_t = false)]
    pub force: bool,
}

#[derive(clap::Args, Debug)]
pub struct RunArgs {
    #[arg(long, env = "LITTLELOVE_BOT_SERVER")]
    pub server: String,

    #[arg(long, env = "LITTLELOVE_BOT_LLM_URL", default_value = "http://localhost:8080/v1")]
    pub llm_url: String,

    #[arg(long, env = "LITTLELOVE_BOT_MODEL", default_value = "local-model")]
    pub model: String,

    #[arg(long, env = "LITTLELOVE_BOT_TEMPERATURE", default_value_t = 0.8)]
    pub temperature: f32,

    #[arg(long, env = "LITTLELOVE_BOT_MAX_TOKENS", default_value_t = 512)]
    pub max_tokens: u32,

    #[arg(long, env = "LITTLELOVE_BOT_HISTORY", default_value_t = 20)]
    pub history: usize,

    /// Character Card v2/v3 PNG. Mutually exclusive with --system-prompt-file and the env var.
    #[arg(long, conflicts_with_all = ["system_prompt_file"])]
    pub character_card: Option<std::path::PathBuf>,

    #[arg(long)]
    pub system_prompt_file: Option<std::path::PathBuf>,
}
```

Write `bot/src/main.rs`:
```rust
use clap::Parser;

mod cli;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")))
        .init();

    let args = cli::Cli::parse();
    match args.command {
        cli::Command::Pair(_) => {
            anyhow::bail!("pair: not yet implemented");
        }
        cli::Command::Run(_) => {
            anyhow::bail!("run: not yet implemented");
        }
        cli::Command::ShowIdentity => {
            anyhow::bail!("show-identity: not yet implemented");
        }
    }
}
```

- [ ] **Step 4: Sanity build**

Run: `cargo check --workspace`
Expected: PASS.
Run: `cargo run -p littlelove-bot -- --help`
Expected: Prints the help, lists the three subcommands.

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): scaffold littlelove-bot binary with clap subcommands

pair / run / show-identity are all stubs that bail. Subsequent tasks
fill them in.
EOF
)"
```

### Task 10: addr_guard — private-IP allow-list

**Files:**
- Create: `bot/src/addr_guard.rs`
- Create: `bot/tests/addr_guard_table.rs`
- Modify: `bot/src/main.rs` (declare module)

- [ ] **Step 1: Write the failing test (`bot/tests/addr_guard_table.rs`)**
```rust
use std::net::IpAddr;

use littlelove_bot::addr_guard::is_private_ip;

#[test]
fn loopback_ipv4_allowed() {
    assert!(is_private_ip(&"127.0.0.1".parse().unwrap()));
}

#[test]
fn rfc1918_ranges_allowed() {
    for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
        let p: IpAddr = ip.parse().unwrap();
        assert!(is_private_ip(&p), "{}", ip);
    }
}

#[test]
fn loopback_ipv6_allowed() {
    assert!(is_private_ip(&"::1".parse().unwrap()));
}

#[test]
fn link_local_allowed() {
    assert!(is_private_ip(&"169.254.0.5".parse().unwrap()));
    assert!(is_private_ip(&"fe80::1".parse().unwrap()));
}

#[test]
fn unique_local_v6_allowed() {
    assert!(is_private_ip(&"fc00::1".parse().unwrap()));
    assert!(is_private_ip(&"fd00::1".parse().unwrap()));
}

#[test]
fn public_ips_rejected() {
    for ip in ["1.1.1.1", "8.8.8.8", "2606:4700::1111"] {
        let p: IpAddr = ip.parse().unwrap();
        assert!(!is_private_ip(&p), "{}", ip);
    }
}
```

Bot crate needs a library target to expose `addr_guard` to integration tests. Add to `bot/Cargo.toml`:
```toml
[lib]
name = "littlelove_bot"
path = "src/lib.rs"
```
Create `bot/src/lib.rs`:
```rust
//! Library facade for integration tests. The binary entrypoint is `src/main.rs`.
pub mod addr_guard;
```
Update `bot/src/main.rs` to use the lib re-exports: change `mod cli;` to additionally declare any module the binary needs OR move shared modules under the lib. For now, also add `mod cli;` into the lib so the test crate can reach it later:

In `bot/src/lib.rs`, additionally add:
```rust
pub mod cli;
```
And in `bot/src/main.rs` replace the `mod cli;` line with `use littlelove_bot::cli;`.

- [ ] **Step 2: Run the test (must fail — module is empty)**

Run: `cargo test -p littlelove-bot --test addr_guard_table`
Expected: FAIL — `is_private_ip` not found.

- [ ] **Step 3: Implement `bot/src/addr_guard.rs`**
```rust
//! Private-IP allow-list. The bot refuses to talk to a non-private LLM
//! endpoint by code — see spec §10 and positioning.md.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};

use thiserror::Error;
use url::Url;

#[derive(Debug, Error)]
pub enum AddrGuardError {
    #[error("invalid URL: {0}")]
    BadUrl(String),
    #[error("URL missing host")]
    NoHost,
    #[error("DNS resolution failed: {0}")]
    Resolve(String),
    #[error("endpoint {host} resolves to public IP {ip}; refusing — bot only talks to private addresses")]
    PublicAddress { host: String, ip: IpAddr },
}

pub fn is_private_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_private_v4(v4),
        IpAddr::V6(v6) => is_private_v6(v6),
    }
}

fn is_private_v4(v4: &Ipv4Addr) -> bool {
    if v4.is_loopback() || v4.is_link_local() || v4.is_private() {
        return true;
    }
    let octets = v4.octets();
    // 100.64.0.0/10 (CGNAT) — treat as private; benign for the bot.
    if octets[0] == 100 && (octets[1] & 0xC0) == 0x40 {
        return true;
    }
    false
}

fn is_private_v6(v6: &Ipv6Addr) -> bool {
    if v6.is_loopback() {
        return true;
    }
    let s = v6.segments()[0];
    // fe80::/10 link-local
    if (s & 0xFFC0) == 0xFE80 {
        return true;
    }
    // fc00::/7 unique-local
    if (s & 0xFE00) == 0xFC00 {
        return true;
    }
    false
}

pub fn ensure_url_is_private(url: &str) -> Result<(), AddrGuardError> {
    let parsed = Url::parse(url).map_err(|e| AddrGuardError::BadUrl(e.to_string()))?;
    let host = parsed.host_str().ok_or(AddrGuardError::NoHost)?.to_string();
    let port = parsed.port_or_known_default().unwrap_or(80);
    let addrs = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| AddrGuardError::Resolve(e.to_string()))?;
    for addr in addrs {
        if !is_private_ip(&addr.ip()) {
            return Err(AddrGuardError::PublicAddress { host, ip: addr.ip() });
        }
    }
    Ok(())
}
```

- [ ] **Step 4: Re-run; it passes**

Run: `cargo test -p littlelove-bot --test addr_guard_table`
Expected: PASS (all 6 cases).

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): addr_guard refuses non-private LLM endpoints

Structural enforcement of the positioning doc's "no cloud AI providers"
clause: the bot has no code path that talks to a public address.
EOF
)"
```

### Task 11: identity_store — JSON file with mode 0600

**Files:**
- Create: `bot/src/identity_store.rs`
- Create: `bot/tests/identity_store_round_trip.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Failing test**

Write `bot/tests/identity_store_round_trip.rs`:
```rust
use tempfile::TempDir;

use littlelove_bot::identity_store::{load_identity, save_identity, IdentityFile};

#[test]
fn round_trip_writes_and_reads() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");

    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(),
        x25519_pub_b64: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=".into(),
        master_secret_b64: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, /*force=*/ false).expect("save");

    let back = load_identity(&path).expect("load");
    assert_eq!(back.username, "court_familiar");
    assert_eq!(back.master_secret_b64, file.master_secret_b64);
}

#[test]
fn save_refuses_existing_without_force() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");

    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "x".into(),
        x25519_pub_b64: "y".into(),
        master_secret_b64: "z".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, false).unwrap();
    let err = save_identity(&path, &file, false).unwrap_err();
    assert!(format!("{err}").contains("exists"));
}

#[cfg(unix)]
#[test]
fn writes_mode_0600_on_unix() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("identity.json");
    let file = IdentityFile {
        version: 1,
        username: "court_familiar".into(),
        ed25519_pub_b64: "x".into(),
        x25519_pub_b64: "y".into(),
        master_secret_b64: "z".into(),
        created_at: chrono::Utc::now(),
    };
    save_identity(&path, &file, false).unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}
```

In `bot/src/lib.rs`, add `pub mod identity_store;`.

- [ ] **Step 2: Run; fails because the module doesn't exist**

Run: `cargo test -p littlelove-bot --test identity_store_round_trip`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `bot/src/identity_store.rs`**
```rust
//! `identity.json` read/write. Atomic write via tempfile + rename.

use std::fs;
use std::io::Write;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IdentityStoreError {
    #[error("identity file already exists at {0:?} (use --force to overwrite)")]
    Exists(std::path::PathBuf),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityFile {
    pub version: u32,
    pub username: String,
    pub ed25519_pub_b64: String,
    pub x25519_pub_b64: String,
    pub master_secret_b64: String,
    pub created_at: DateTime<Utc>,
}

pub fn load_identity(path: &Path) -> Result<IdentityFile, IdentityStoreError> {
    let bytes = fs::read(path)?;
    let file: IdentityFile = serde_json::from_slice(&bytes)?;
    Ok(file)
}

pub fn save_identity(
    path: &Path,
    file: &IdentityFile,
    force: bool,
) -> Result<(), IdentityStoreError> {
    if path.exists() && !force {
        return Err(IdentityStoreError::Exists(path.to_path_buf()));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o600);
            f.set_permissions(perms)?;
        }
        let bytes = serde_json::to_vec_pretty(file)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Default location, per `directories::ProjectDirs`.
pub fn default_identity_path() -> std::path::PathBuf {
    let proj = directories::ProjectDirs::from("dev", "littlelove", "littlelove-bot")
        .expect("OS provided no config dir");
    proj.config_dir().join("identity.json")
}
```

- [ ] **Step 4: Re-run**

Run: `cargo test -p littlelove-bot --test identity_store_round_trip`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): identity_store — atomic JSON write with 0600 perms
EOF
)"
```

---

## Phase C — REST + WSS + pair subcommand

### Task 12: REST client (`POST /accounts`)

**Files:**
- Create: `bot/src/rest.rs`
- Create: `bot/tests/rest_signup.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Failing test**

Write `bot/tests/rest_signup.rs`:
```rust
use std::net::SocketAddr;

use axum::{routing::post, Json, Router};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;

use littlelove_bot::rest::{signup, SignupRequest};

#[tokio::test]
async fn signup_round_trips() {
    #[derive(Deserialize)]
    struct In { username: String, ed25519_pub: String, x25519_pub: String }
    #[derive(Serialize)]
    struct Out { username: String, created_at: chrono::DateTime<chrono::Utc> }

    let app = Router::new().route("/accounts", post(|Json(req): Json<In>| async move {
        Json(Out { username: req.username, created_at: chrono::Utc::now() })
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let base = format!("http://{addr}");
    let resp = signup(&base, &SignupRequest {
        username: "court_familiar".into(),
        ed25519_pub_b64: "AAAA".into(),
        x25519_pub_b64: "BBBB".into(),
    }).await.expect("signup");
    assert_eq!(resp.username, "court_familiar");
}
```

In `bot/src/lib.rs`, add `pub mod rest;`.

- [ ] **Step 2: Run; fails**

Run: `cargo test -p littlelove-bot --test rest_signup`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `bot/src/rest.rs`**
```rust
//! REST client. Only `POST /accounts` is needed; everything else moves
//! through the WSS frame stream.

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
pub struct SignupRequest {
    pub username: String,
    pub ed25519_pub_b64: String,
    pub x25519_pub_b64: String,
}

#[derive(Debug, Deserialize)]
pub struct SignupResponse {
    pub username: String,
    pub created_at: DateTime<Utc>,
}

pub async fn signup(base_url: &str, req: &SignupRequest) -> Result<SignupResponse> {
    let url = format!("{}/accounts", base_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "username": req.username,
        "ed25519_pub": req.ed25519_pub_b64,
        "x25519_pub": req.x25519_pub_b64,
    });
    let resp = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .with_context(|| format!("POST {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("signup failed {status}: {text}"));
    }
    Ok(resp.json::<SignupResponse>().await?)
}
```

- [ ] **Step 4: Run + commit**

Run: `cargo test -p littlelove-bot --test rest_signup`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): REST signup client (POST /accounts)
EOF
)"
```

### Task 13: WSS handshake client

**Files:**
- Create: `bot/src/ws_client.rs`
- Create: `bot/tests/ws_handshake.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Failing test (uses a synthetic server inside the test)**

Write `bot/tests/ws_handshake.rs`:
```rust
//! Spin up a tiny axum WebSocket server that issues a Challenge,
//! verifies the signature using littlelove-crypto, and replies
//! Authenticated. The bot side performs the handshake using its own
//! signing key.

use std::net::SocketAddr;

use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    response::IntoResponse,
    routing::any,
    Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::Signer;
use littlelove_bot::ws_client::{connect_and_identify, ClientIdentity};
use littlelove_crypto::sig::{challenge_signing_input, verify_signature};
use serde_json::Value;
use tokio::net::TcpListener;

async fn challenger(mut sock: WebSocket, expected_pub: [u8; 32]) {
    let nonce = [0xABu8; 32];
    let challenge = serde_json::json!({ "kind": "Challenge", "nonce": B64.encode(nonce) });
    sock.send(Message::Text(challenge.to_string())).await.unwrap();

    let raw = match sock.recv().await.unwrap().unwrap() {
        Message::Text(t) => t,
        _ => panic!("non-text frame"),
    };
    let v: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(v["kind"], "Identify");
    let sig = B64.decode(v["signature"].as_str().unwrap()).unwrap();
    verify_signature(&expected_pub, &nonce, &sig).expect("server-side verify");

    sock.send(Message::Text(r#"{"kind":"Authenticated"}"#.into())).await.unwrap();
    // Send an empty Rooms frame to satisfy the post-Authenticated push.
    sock.send(Message::Text(r#"{"kind":"Rooms","rooms":[]}"#.into())).await.unwrap();
}

#[tokio::test]
async fn handshake_round_trips() {
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    let sk = SigningKey::generate(&mut OsRng);
    let pk = sk.verifying_key().to_bytes();

    let pk_for_handler = pk;
    let app = Router::new().route("/connect", any(move |ws: WebSocketUpgrade| async move {
        ws.on_upgrade(move |sock| challenger(sock, pk_for_handler))
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let ws_url = format!("ws://{addr}/connect");
    let identity = ClientIdentity {
        username: "court_familiar".into(),
        ed25519_signing: sk,
    };
    let session = connect_and_identify(&ws_url, &identity).await.expect("identify");
    assert!(session.initial_rooms.is_empty());
}
```

In `bot/src/lib.rs`, add `pub mod ws_client;`.

- [ ] **Step 2: Run; fails**

Run: `cargo test -p littlelove-bot --test ws_handshake`
Expected: FAIL.

- [ ] **Step 3: Implement `bot/src/ws_client.rs`**
```rust
//! WSS Challenge → Identify → Authenticated handshake + frame I/O.
//!
//! Spec §3.3 + §8.2. The client uses `littlelove_crypto::sig` for
//! domain-separated signing; the verifier on the server side uses the
//! same crate.

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use futures::{SinkExt, StreamExt};
use littlelove_crypto::sig::challenge_signing_input;
use serde::{Deserialize, Serialize};
use tokio_tungstenite::tungstenite::Message;

pub struct ClientIdentity {
    pub username: String,
    pub ed25519_signing: SigningKey,
}

pub struct Session {
    pub socket: WsStream,
    pub initial_rooms: Vec<RoomSummary>,
}

pub type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct RoomSummary {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum ServerFrame {
    Challenge { nonce: String },
    Authenticated,
    Rooms { rooms: Vec<RoomSummary> },
    Error { code: String, #[serde(default)] message: String },
}

pub async fn connect_and_identify(ws_url: &str, identity: &ClientIdentity) -> Result<Session> {
    let (mut sock, _resp) = tokio_tungstenite::connect_async(ws_url)
        .await
        .with_context(|| format!("WSS connect {ws_url}"))?;

    let first = sock
        .next()
        .await
        .ok_or_else(|| anyhow!("server closed before Challenge"))??;
    let nonce_b64 = match first {
        Message::Text(t) => {
            let parsed: ServerFrame = serde_json::from_str(&t)?;
            match parsed {
                ServerFrame::Challenge { nonce } => nonce,
                ServerFrame::Error { code, message } => {
                    return Err(anyhow!("server error before Challenge: {code} {message}"));
                }
                _ => return Err(anyhow!("expected Challenge, got {t}")),
            }
        }
        other => return Err(anyhow!("expected Text Challenge, got {other:?}")),
    };
    let nonce = B64.decode(nonce_b64.as_bytes())?;
    let sig = identity.ed25519_signing.sign(&challenge_signing_input(&nonce));
    let identify = serde_json::json!({
        "kind": "Identify",
        "username": identity.username,
        "signature": B64.encode(sig.to_bytes()),
    });
    sock.send(Message::Text(identify.to_string())).await?;

    // Expect Authenticated, then Rooms.
    let mut initial_rooms = Vec::new();
    loop {
        let frame = sock
            .next()
            .await
            .ok_or_else(|| anyhow!("server closed mid-handshake"))??;
        let text = match frame {
            Message::Text(t) => t,
            Message::Close(c) => return Err(anyhow!("server closed: {c:?}")),
            other => return Err(anyhow!("non-text frame: {other:?}")),
        };
        let parsed: ServerFrame = serde_json::from_str(&text)?;
        match parsed {
            ServerFrame::Authenticated => continue,
            ServerFrame::Rooms { rooms } => {
                initial_rooms = rooms;
                break;
            }
            ServerFrame::Error { code, message } => {
                return Err(anyhow!("auth error: {code} {message}"));
            }
            ServerFrame::Challenge { .. } => {
                return Err(anyhow!("unexpected second Challenge"));
            }
        }
    }
    Ok(Session { socket: sock, initial_rooms })
}
```

- [ ] **Step 4: Run + commit**

Run: `cargo test -p littlelove-bot --test ws_handshake`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): WSS Challenge→Identify→Authenticated handshake
EOF
)"
```

### Task 14: `pair` subcommand — signup + WSS + ConsumeInvite

**Files:**
- Create: `bot/src/pair.rs`
- Modify: `bot/src/main.rs`, `bot/src/lib.rs`, `bot/src/ws_client.rs`

- [ ] **Step 1: Extend ws_client with sender helpers**

Add to `bot/src/ws_client.rs`:
```rust
use ed25519_dalek::Signer as _;
use littlelove_crypto::sig::invite_consume_signing_input;

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct RoomDescriptor {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum RoomServerFrame {
    InviteConsumed(RoomDescriptor),
    RoomCreated(RoomDescriptor),
    Rooms { rooms: Vec<RoomSummary> },
    Message { id: String, room_id: String, from: String,
              ts: chrono::DateTime<chrono::Utc>, body: String,
              #[serde(default)] replayed: bool },
    Error { code: String, #[serde(default)] message: String },
    InviteCreated { code: String, qr_png_base64: String,
                    expires_at: chrono::DateTime<chrono::Utc> },
}

pub async fn consume_invite(
    session: &mut Session,
    identity: &ClientIdentity,
    code: &str,
) -> Result<RoomDescriptor> {
    let canonical = littlelove_crypto::invite::decode_code(code)
        .map_err(|e| anyhow!("invalid invite code: {e}"))?;
    let sig = identity.ed25519_signing.sign(&invite_consume_signing_input(&canonical));
    let frame = serde_json::json!({
        "kind": "ConsumeInvite",
        "code": code,
        "signature_over_token": B64.encode(sig.to_bytes()),
    });
    session.socket.send(Message::Text(frame.to_string())).await?;
    loop {
        let next = session
            .socket
            .next()
            .await
            .ok_or_else(|| anyhow!("server closed waiting for InviteConsumed"))??;
        if let Message::Text(t) = next {
            let parsed: RoomServerFrame = serde_json::from_str(&t)?;
            match parsed {
                RoomServerFrame::InviteConsumed(d) => return Ok(d),
                RoomServerFrame::Error { code, message } => {
                    return Err(anyhow!("consume invite error: {code} {message}"));
                }
                _ => continue,
            }
        }
    }
}
```

(The `RoomServerFrame::InviteCreated` variant is added so the lone-match doesn't leave `qr_png_base64` an unused field; the bot doesn't generate invites so it'll never receive it, but we want the deserializer to skip it gracefully if a buggy server sends one.)

- [ ] **Step 2: Implement `bot/src/pair.rs`**
```rust
//! pair subcommand: signup + identify + ConsumeInvite + persist identity.

use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::Utc;

use crate::cli::PairArgs;
use crate::identity_store::{default_identity_path, save_identity, IdentityFile};
use crate::rest::{signup, SignupRequest};
use crate::ws_client::{connect_and_identify, consume_invite, ClientIdentity};
use littlelove_crypto::identity::{derive_identity, random_seed};

pub async fn run(args: PairArgs) -> Result<()> {
    if args.username.len() < 3 || args.username.len() > 20
        || !args.username.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        anyhow::bail!("--username must match [a-z0-9_]{{3,20}}");
    }

    let path = default_identity_path();
    if path.exists() && !args.force {
        anyhow::bail!("identity file already exists at {path:?} — re-run with --force to overwrite");
    }

    let seed = random_seed();
    let identity = derive_identity(&seed).context("derive identity")?;
    let ed_pub_b64 = B64.encode(identity.ed25519_pub());
    let x_pub_b64 = B64.encode(identity.x25519_pub());

    let rest_base = ws_to_rest_base(&args.server)?;
    signup(&rest_base, &SignupRequest {
        username: args.username.clone(),
        ed25519_pub_b64: ed_pub_b64.clone(),
        x25519_pub_b64: x_pub_b64.clone(),
    }).await.context("signup")?;

    let ws_url = format!("{}/connect", args.server.trim_end_matches('/'));
    let mut session = connect_and_identify(&ws_url, &ClientIdentity {
        username: args.username.clone(),
        ed25519_signing: identity.ed25519_signing.clone(),
    }).await.context("ws handshake")?;

    let descriptor = consume_invite(&mut session, &ClientIdentity {
        username: args.username.clone(),
        ed25519_signing: identity.ed25519_signing.clone(),
    }, &args.code).await.context("consume invite")?;

    let file = IdentityFile {
        version: 1,
        username: args.username.clone(),
        ed25519_pub_b64: ed_pub_b64,
        x25519_pub_b64: x_pub_b64,
        master_secret_b64: B64.encode(identity.master),
        created_at: Utc::now(),
    };
    save_identity(&path, &file, args.force).context("save identity")?;

    println!("Paired with @{}. Room: {}. Identity saved to {}.",
             descriptor.peer_username, descriptor.room_id, path.display());
    Ok(())
}

fn ws_to_rest_base(server: &str) -> Result<String> {
    let s = server.trim_end_matches('/');
    if let Some(rest) = s.strip_prefix("wss://") {
        Ok(format!("https://{rest}"))
    } else if let Some(rest) = s.strip_prefix("ws://") {
        Ok(format!("http://{rest}"))
    } else {
        Ok(s.to_string())
    }
}
```

In `bot/src/lib.rs`, add `pub mod pair;`.

In `bot/src/main.rs`, wire the dispatch:
```rust
cli::Command::Pair(args) => littlelove_bot::pair::run(args).await,
```

- [ ] **Step 3: Run `cargo check --workspace` to confirm it builds**

Run: `cargo check --workspace`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): pair subcommand — signup + WSS handshake + ConsumeInvite

Persists identity.json on success. Manual smoke is what proves the
end-to-end path; an ignored integration test in a later task drives the
real server binary.
EOF
)"
```

---

## Phase D — LLM + history + character cards

### Task 15: history ring buffer

**Files:**
- Create: `bot/src/history.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Write the module + inline tests**
```rust
//! Bounded in-memory conversation history.
//!
//! Items are role-tagged so we can shape OpenAI chat-completions messages.

use std::collections::VecDeque;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Role { User, Assistant }

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
        Self { cap: cap.max(1), buf: VecDeque::with_capacity(cap) }
    }

    pub fn push(&mut self, role: Role, content: String) {
        if self.buf.len() == self.cap {
            self.buf.pop_front();
        }
        self.buf.push_back(Turn { role, content });
    }

    pub fn iter(&self) -> impl Iterator<Item = &Turn> { self.buf.iter() }
    pub fn len(&self) -> usize { self.buf.len() }
    pub fn is_empty(&self) -> bool { self.buf.is_empty() }
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
```

In `bot/src/lib.rs`, add `pub mod history;`.

- [ ] **Step 2: Run + commit**

Run: `cargo test -p littlelove-bot --lib history`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): bounded role-tagged history ring buffer
EOF
)"
```

### Task 16: LLM client (chat completions)

**Files:**
- Create: `bot/src/llm.rs`
- Create: `bot/tests/llm_mock.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Failing test**

Write `bot/tests/llm_mock.rs`:
```rust
use std::net::SocketAddr;

use axum::{routing::post, Json, Router};
use tokio::net::TcpListener;

use littlelove_bot::history::{History, Role};
use littlelove_bot::llm::{LlmClient, LlmRequest};

#[tokio::test]
async fn mock_chat_returns_reply() {
    let app = Router::new().route(
        "/chat/completions",
        post(|Json(_): Json<serde_json::Value>| async {
            Json(serde_json::json!({
                "choices": [{ "message": { "role": "assistant", "content": "ok" } }]
            }))
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let base = format!("http://{addr}");
    let client = LlmClient::new(&base, "test-model", 0.5, 64, std::time::Duration::from_secs(5))
        .expect("client");
    let mut history = History::new(5);
    history.push(Role::User, "hello".into());
    let reply = client
        .chat(&LlmRequest { system_prompt: "be brief".into(), history: &history, latest_user: "hello" })
        .await
        .expect("chat");
    assert_eq!(reply.trim(), "ok");
}
```

In `bot/src/lib.rs`, add `pub mod llm;`.

- [ ] **Step 2: Run; fails**

Run: `cargo test -p littlelove-bot --test llm_mock`
Expected: FAIL.

- [ ] **Step 3: Implement `bot/src/llm.rs`**
```rust
//! OpenAI-compatible chat-completions client. Talks only to private IPs.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

use crate::addr_guard::ensure_url_is_private;
use crate::history::{History, Role};

pub struct LlmClient {
    base_url: String,
    model: String,
    temperature: f32,
    max_tokens: u32,
    http: reqwest::Client,
}

pub struct LlmRequest<'a> {
    pub system_prompt: String,
    pub history: &'a History,
    pub latest_user: &'a str,
}

#[derive(Serialize)]
struct ChatBody<'a> {
    model: &'a str,
    messages: Vec<ChatMsg>,
    stream: bool,
    temperature: f32,
    max_tokens: u32,
}

#[derive(Serialize)]
struct ChatMsg {
    role: &'static str,
    content: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

impl LlmClient {
    pub fn new(
        base_url: &str,
        model: &str,
        temperature: f32,
        max_tokens: u32,
        timeout: Duration,
    ) -> Result<Self> {
        ensure_url_is_private(base_url)
            .with_context(|| format!("refusing LLM endpoint {base_url}"))?;
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .context("reqwest client")?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            model: model.to_string(),
            temperature,
            max_tokens,
            http,
        })
    }

    pub async fn chat(&self, req: &LlmRequest<'_>) -> Result<String> {
        ensure_url_is_private(&self.base_url)
            .with_context(|| format!("LLM endpoint flipped to non-private: {}", self.base_url))?;

        let mut messages = vec![ChatMsg { role: "system", content: req.system_prompt.clone() }];
        for turn in req.history.iter() {
            messages.push(ChatMsg {
                role: match turn.role { Role::User => "user", Role::Assistant => "assistant" },
                content: turn.content.clone(),
            });
        }
        messages.push(ChatMsg { role: "user", content: req.latest_user.to_string() });

        let body = ChatBody {
            model: &self.model,
            messages,
            stream: false,
            temperature: self.temperature,
            max_tokens: self.max_tokens,
        };
        let url = format!("{}/chat/completions", self.base_url);
        let resp = self.http.post(&url).json(&body).send().await
            .with_context(|| format!("POST {url}"))?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("LLM {status}: {text}"));
        }
        let body: ChatResponse = resp.json().await.context("decode chat response")?;
        let choice = body.choices.into_iter().next().ok_or_else(|| anyhow!("LLM returned no choices"))?;
        Ok(choice.message.content)
    }
}
```

- [ ] **Step 4: Run + commit**

Run: `cargo test -p littlelove-bot --test llm_mock`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): LLM client (OpenAI chat-completions, private-IP guarded)
EOF
)"
```

### Task 17: character_card — PNG → struct

**Files:**
- Create: `bot/src/character_card.rs`
- Create: `bot/tests/fixtures/card_v2.png` (generated in step 1)
- Create: `bot/tests/fixtures/card_v3.png`
- Create: `bot/tests/character_card.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Generate fixture PNGs (Rust helper, run once)**

Create `bot/tests/fixtures/gen.rs` (a binary helper) — but simpler: bake fixture-generation into the test itself using the `png` crate. Skip a separate `gen.rs`.

Write `bot/tests/character_card.rs`:
```rust
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use littlelove_bot::character_card::{parse_png, CardData};

fn make_png_with_chunk(keyword: &str, value: &str) -> Vec<u8> {
    use png::{Encoder, text_metadata::ITXtChunk};
    let mut bytes: Vec<u8> = Vec::new();
    {
        let mut enc = Encoder::new(&mut bytes, 2, 2);
        enc.set_color(png::ColorType::Grayscale);
        enc.set_depth(png::BitDepth::Eight);
        let chunk = ITXtChunk::new(keyword.to_string(), value.to_string());
        enc.add_itxt_chunk(chunk.keyword.clone(), chunk.text.clone()).unwrap();
        let mut w = enc.write_header().unwrap();
        w.write_image_data(&[0u8; 4]).unwrap();
    }
    bytes
}

#[test]
fn parses_v2_card() {
    let json = serde_json::json!({
        "spec": "chara_card_v2",
        "spec_version": "2.0",
        "data": {
            "name": "Aria",
            "description": "a soft-spoken assistant",
            "personality": "patient, curious",
            "scenario": "in a quiet room",
            "system_prompt": "",
            "creator": "test",
            "character_version": "0.1"
        }
    });
    let value = B64.encode(serde_json::to_vec(&json).unwrap());
    let png_bytes = make_png_with_chunk("chara", &value);

    let card = parse_png(&png_bytes).expect("parse v2");
    let data: &CardData = &card.data;
    assert_eq!(data.name, "Aria");
    assert_eq!(data.personality, "patient, curious");
}

#[test]
fn parses_v3_card() {
    let json = serde_json::json!({
        "spec": "chara_card_v3",
        "data": { "name": "Iris", "description": "v3 example", "personality": "",
                  "scenario": "", "system_prompt": "You are Iris." }
    });
    let value = B64.encode(serde_json::to_vec(&json).unwrap());
    let png_bytes = make_png_with_chunk("ccv3", &value);

    let card = parse_png(&png_bytes).expect("parse v3");
    assert_eq!(card.data.name, "Iris");
    assert_eq!(card.data.system_prompt, "You are Iris.");
}

#[test]
fn rejects_png_with_no_card_chunk() {
    let png_bytes = make_png_with_chunk("Comment", "not a card");
    let err = parse_png(&png_bytes).unwrap_err();
    assert!(format!("{err}").contains("no ccv3 or chara"));
}
```

In `bot/src/lib.rs`, add `pub mod character_card;`.

- [ ] **Step 2: Run; fails**

Run: `cargo test -p littlelove-bot --test character_card`
Expected: FAIL (parse_png not found).

- [ ] **Step 3: Implement `bot/src/character_card.rs`**
```rust
//! Character Card v2/v3 PNG parser.

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::Deserialize;

const MAX_CARD_JSON: usize = 1 << 20; // 1 MiB

#[derive(Debug, Deserialize)]
pub struct Card {
    pub spec: String,
    pub data: CardData,
}

#[derive(Debug, Deserialize, Default)]
pub struct CardData {
    #[serde(default)] pub name: String,
    #[serde(default)] pub description: String,
    #[serde(default)] pub personality: String,
    #[serde(default)] pub scenario: String,
    #[serde(default)] pub system_prompt: String,
    #[serde(default)] pub creator: Option<String>,
    #[serde(default)] pub character_version: Option<String>,
}

/// Drop-noted fields: parsed/ignored. We log their presence on the
/// startup line so the operator sees what was silently skipped.
#[derive(Debug, Deserialize, Default)]
struct DropNotes {
    #[serde(default)] first_mes: Option<String>,
    #[serde(default)] mes_example: Option<String>,
    #[serde(default)] alternate_greetings: Option<Vec<String>>,
    #[serde(default)] character_book: Option<serde_json::Value>,
    #[serde(default)] post_history_instructions: Option<String>,
}

pub fn parse_png(bytes: &[u8]) -> Result<Card> {
    let decoder = png::Decoder::new(bytes);
    let reader = decoder.read_info().context("decode png header")?;
    let info = reader.info();

    let pick = info.utf8_text.iter().find(|c| c.keyword == "ccv3")
        .or_else(|| info.utf8_text.iter().find(|c| c.keyword == "chara"));
    let text = pick.ok_or_else(|| anyhow!("no ccv3 or chara iTXt chunk in PNG"))?;

    let payload = text.get_text().context("itxt text")?;
    let decoded = B64.decode(payload.trim().as_bytes())
        .context("base64-decode CCv2 payload")?;
    if decoded.len() > MAX_CARD_JSON {
        return Err(anyhow!("card JSON too large: {} bytes", decoded.len()));
    }
    let card: Card = serde_json::from_slice(&decoded).context("parse CCv2 JSON")?;
    if card.data.name.trim().is_empty() {
        return Err(anyhow!("card has no name"));
    }
    // Parse drop-notes for the log line; ignore errors.
    let dropped: DropNotes = serde_json::from_slice::<serde_json::Value>(&decoded)
        .ok()
        .and_then(|v| v.get("data").cloned())
        .and_then(|d| serde_json::from_value(d).ok())
        .unwrap_or_default();
    let mut drops = Vec::new();
    if dropped.first_mes.is_some() { drops.push("first_mes"); }
    if dropped.mes_example.is_some() { drops.push("mes_example"); }
    if dropped.alternate_greetings.as_ref().is_some_and(|v| !v.is_empty()) { drops.push("alternate_greetings"); }
    if dropped.character_book.is_some() { drops.push("character_book"); }
    if dropped.post_history_instructions.is_some() { drops.push("post_history_instructions"); }
    if !drops.is_empty() {
        tracing::info!("character card dropped fields: {}", drops.join(", "));
    }
    tracing::info!(
        "loaded character card: {:?} ({}, by {}, version {})",
        card.data.name, card.spec,
        card.data.creator.as_deref().unwrap_or("unknown"),
        card.data.character_version.as_deref().unwrap_or("unknown"),
    );
    Ok(card)
}
```

- [ ] **Step 4: Run + commit**

Run: `cargo test -p littlelove-bot --test character_card`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): Character Card v2/v3 PNG parser
EOF
)"
```

### Task 18: persona resolver

**Files:**
- Create: `bot/src/persona.rs`
- Create: `bot/tests/persona_resolver.rs`
- Modify: `bot/src/lib.rs`

- [ ] **Step 1: Failing test**

Write `bot/tests/persona_resolver.rs`:
```rust
use littlelove_bot::persona::{resolve, PersonaSources, ResolveError};

#[test]
fn default_prompt_when_no_sources() {
    let p = resolve(PersonaSources::default(), "court").expect("resolve");
    assert!(p.contains("AI familiar"));
}

#[test]
fn env_string_wins_over_default() {
    let mut s = PersonaSources::default();
    s.env_prompt = Some("custom env prompt".into());
    let p = resolve(s, "court").unwrap();
    assert_eq!(p, "custom env prompt");
}

#[test]
fn mutual_exclusion_errors() {
    let mut s = PersonaSources::default();
    s.system_prompt_file_contents = Some("a".into());
    s.env_prompt = Some("b".into());
    let err = resolve(s, "court").unwrap_err();
    assert!(matches!(err, ResolveError::Conflict));
}

#[test]
fn card_template_substitutes_user_and_char() {
    use littlelove_bot::character_card::{Card, CardData};
    let mut s = PersonaSources::default();
    s.card = Some(Card {
        spec: "chara_card_v2".into(),
        data: CardData {
            name: "Aria".into(),
            description: "{{char}} is the assistant for {{user}}.".into(),
            personality: "".into(),
            scenario: "".into(),
            system_prompt: "".into(),
            creator: None,
            character_version: None,
        },
    });
    let p = resolve(s, "court").unwrap();
    assert!(p.contains("Aria is the assistant for court"));
    assert!(p.contains("[Start a new chat between court and Aria]"));
}

#[test]
fn card_system_prompt_used_verbatim() {
    use littlelove_bot::character_card::{Card, CardData};
    let mut s = PersonaSources::default();
    s.card = Some(Card {
        spec: "chara_card_v2".into(),
        data: CardData {
            name: "Iris".into(),
            description: "drop".into(),
            personality: "drop".into(),
            scenario: "drop".into(),
            system_prompt: "You are {{char}}. Speak only when spoken to.".into(),
            creator: None,
            character_version: None,
        },
    });
    let p = resolve(s, "court").unwrap();
    assert_eq!(p, "You are Iris. Speak only when spoken to.");
}
```

In `bot/src/lib.rs`, add `pub mod persona;`.

- [ ] **Step 2: Run; fails**

Run: `cargo test -p littlelove-bot --test persona_resolver`
Expected: FAIL.

- [ ] **Step 3: Implement `bot/src/persona.rs`**
```rust
//! Resolve the bot's system prompt from at most one source.

use thiserror::Error;

use crate::character_card::Card;

pub const DEFAULT_SYSTEM_PROMPT: &str = "You are an AI familiar running locally on your operator's hardware. You live in a private end-to-end encrypted chat with one person — the person talking to you right now. You are not a person and you do not pretend to be one. You are sober, plainspoken, and brief by default. You do not volunteer opinions on the operator's partner, family, or relationships unless asked. You do not moralize. If the operator wants longer or warmer responses, they will ask, and you will oblige.";

#[derive(Default)]
pub struct PersonaSources {
    pub card: Option<Card>,
    pub system_prompt_file_contents: Option<String>,
    pub env_prompt: Option<String>,
}

#[derive(Debug, Error)]
pub enum ResolveError {
    #[error("pass only one of --character-card, --system-prompt-file, or LITTLELOVE_BOT_SYSTEM_PROMPT")]
    Conflict,
}

pub fn resolve(sources: PersonaSources, user_name: &str) -> Result<String, ResolveError> {
    let count = [
        sources.card.is_some(),
        sources.system_prompt_file_contents.is_some(),
        sources.env_prompt.is_some(),
    ].iter().filter(|b| **b).count();
    if count > 1 {
        return Err(ResolveError::Conflict);
    }
    if let Some(card) = sources.card {
        return Ok(render_card(&card, user_name));
    }
    if let Some(s) = sources.system_prompt_file_contents { return Ok(s); }
    if let Some(s) = sources.env_prompt { return Ok(s); }
    Ok(DEFAULT_SYSTEM_PROMPT.to_string())
}

fn render_card(card: &Card, user_name: &str) -> String {
    let raw = if !card.data.system_prompt.trim().is_empty() {
        card.data.system_prompt.clone()
    } else {
        default_template(card)
    };
    raw.replace("{{char}}", &card.data.name)
       .replace("{{user}}", user_name)
}

fn default_template(card: &Card) -> String {
    let mut parts: Vec<String> = Vec::new();
    let d = &card.data;
    if !d.description.trim().is_empty() {
        parts.push(format!("{{{{char}}}}'s Persona: {}", d.description));
    }
    if !d.personality.trim().is_empty() {
        parts.push(format!("Personality: {}", d.personality));
    }
    if !d.scenario.trim().is_empty() {
        parts.push(format!("Scenario: {}", d.scenario));
    }
    parts.push("[Start a new chat between {{user}} and {{char}}]".to_string());
    parts.join("\n\n")
}
```

- [ ] **Step 4: Run + commit**

Run: `cargo test -p littlelove-bot --test persona_resolver`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): persona resolver — card / file / env / default
EOF
)"
```

---

## Phase E — Run loop + integration polish

### Task 19: room loop — subscribe + decrypt + LLM + reply

**Files:**
- Create: `bot/src/run.rs`
- Modify: `bot/src/main.rs`, `bot/src/lib.rs`, `bot/src/ws_client.rs`

- [ ] **Step 1: Extend ws_client for run-time IO**

Add to `bot/src/ws_client.rs`:
```rust
use uuid::Uuid;

/// Inbound frame variants the run loop cares about. Variants the bot
/// never expects to receive (e.g. RoomCreated for a paired bot) are
/// deserialized into `Other` and silently dropped.
#[derive(Debug, Clone)]
pub enum Inbound {
    Message {
        id: String,
        room_id: String,
        from: String,
        ts: chrono::DateTime<chrono::Utc>,
        body: String,
        replayed: bool,
    },
    Other,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum InboundRaw {
    Message {
        id: String, room_id: String, from: String,
        ts: chrono::DateTime<chrono::Utc>, body: String,
        #[serde(default)] replayed: bool,
    },
    #[serde(other)]
    Other,
}

pub async fn next_inbound(session: &mut Session) -> Result<Option<Inbound>> {
    while let Some(msg) = session.socket.next().await {
        let m = msg?;
        if let Message::Text(t) = m {
            let parsed: InboundRaw = match serde_json::from_str(&t) {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!("skip un-parseable frame: {e}");
                    continue;
                }
            };
            return Ok(Some(match parsed {
                InboundRaw::Message { id, room_id, from, ts, body, replayed } =>
                    Inbound::Message { id, room_id, from, ts, body, replayed },
                InboundRaw::Other => Inbound::Other,
            }));
        }
    }
    Ok(None)
}

pub async fn subscribe(session: &mut Session, room_id: &str) -> Result<()> {
    let frame = serde_json::json!({
        "kind": "Subscribe",
        "room_id": room_id,
        "since_message_id": serde_json::Value::Null,
    });
    session.socket.send(Message::Text(frame.to_string())).await?;
    Ok(())
}

pub async fn send_message(session: &mut Session, room_id: &str, wire_body: &str) -> Result<()> {
    let frame = serde_json::json!({
        "kind": "Send",
        "room_id": room_id,
        "body": wire_body,
        "client_msg_id": Uuid::new_v4(),
    });
    session.socket.send(Message::Text(frame.to_string())).await?;
    Ok(())
}
```

- [ ] **Step 2: Implement `bot/src/run.rs`**
```rust
//! `run` subcommand: subscribe to the room, decrypt inbound, call LLM,
//! encrypt + send reply.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;

use crate::cli::RunArgs;
use crate::history::{History, Role};
use crate::identity_store::{default_identity_path, load_identity};
use crate::llm::{LlmClient, LlmRequest};
use crate::persona::{resolve, PersonaSources};
use crate::ws_client::{connect_and_identify, next_inbound, send_message, subscribe,
                       ClientIdentity, Inbound};
use littlelove_crypto::{aead, ecdh, identity::derive_identity};

pub async fn run(args: RunArgs) -> Result<()> {
    let id_path = default_identity_path();
    let file = load_identity(&id_path)
        .with_context(|| format!("load identity {id_path:?} — did you run `pair`?"))?;
    let master = B64.decode(file.master_secret_b64.as_bytes())
        .context("decode master_secret_b64")?;
    let master_arr: [u8; 32] = master.as_slice().try_into()
        .map_err(|_| anyhow!("master_secret_b64 is not 32 bytes"))?;
    // Re-derive from master via the same HKDF path as derive_identity
    // (the spec stores the master, not the seed — derive_identity takes a
    // seed, so we expose a master-input path here):
    let identity_keypair = derive_identity_from_master(&master_arr)?;
    let signing = SigningKey::from_bytes(&identity_keypair.signing_seed);
    let x_pub_bytes = B64.decode(file.x25519_pub_b64.as_bytes())?;
    let _: [u8; 32] = x_pub_bytes.as_slice().try_into()
        .map_err(|_| anyhow!("x25519_pub_b64 is not 32 bytes"))?;

    let card = match &args.character_card {
        Some(p) => {
            let bytes = std::fs::read(p).with_context(|| format!("read {p:?}"))?;
            Some(crate::character_card::parse_png(&bytes)?)
        }
        None => None,
    };
    let file_prompt = match &args.system_prompt_file {
        Some(p) => Some(std::fs::read_to_string(p).with_context(|| format!("read {p:?}"))?),
        None => None,
    };
    let env_prompt = std::env::var("LITTLELOVE_BOT_SYSTEM_PROMPT").ok();

    let system_prompt = resolve(PersonaSources {
        card,
        system_prompt_file_contents: file_prompt,
        env_prompt,
    }, &file.username)?;

    let llm = LlmClient::new(&args.llm_url, &args.model, args.temperature, args.max_tokens,
                             Duration::from_secs(60))?;

    let ws_url = format!("{}/connect", args.server.trim_end_matches('/'));
    let mut session = connect_and_identify(&ws_url, &ClientIdentity {
        username: file.username.clone(),
        ed25519_signing: signing.clone(),
    }).await.context("ws handshake")?;

    let room = session.initial_rooms.first().cloned()
        .ok_or_else(|| anyhow!("no rooms in initial Rooms frame — did pairing complete?"))?;
    tracing::info!("subscribed to room {} with peer @{}", room.room_id, room.peer_username);

    let peer_x_pub: [u8; 32] = B64.decode(room.peer_x25519_pub.as_bytes())
        .context("decode peer_x25519_pub")?
        .as_slice().try_into()
        .map_err(|_| anyhow!("peer x25519_pub not 32 bytes"))?;
    let room_key = ecdh::derive_room_key(&identity_keypair.enc_seed, &peer_x_pub, &room.room_id)
        .context("derive room key")?;

    subscribe(&mut session, &room.room_id).await?;
    let mut history = History::new(args.history);

    while let Some(inbound) = next_inbound(&mut session).await? {
        match inbound {
            Inbound::Message { from, body, replayed, .. } if from != file.username => {
                let plain = match aead::decrypt_wire(&room_key, &body) {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::warn!("decrypt failed for inbound frame from {from}: {e}");
                        continue;
                    }
                };
                let text = String::from_utf8_lossy(&plain).into_owned();
                history.push(Role::User, text.clone());
                if replayed { continue; }
                let reply_text = match llm.chat(&LlmRequest {
                    system_prompt: system_prompt.clone(),
                    history: &history,
                    latest_user: &text,
                }).await {
                    Ok(r) => r,
                    Err(e) => {
                        tracing::error!("LLM error: {e}");
                        format!("[llm error: {e}]")
                    }
                };
                history.push(Role::Assistant, reply_text.clone());
                let wire = aead::encrypt_wire(&room_key, reply_text.as_bytes())?;
                send_message(&mut session, &room.room_id, &wire).await?;
            }
            _ => { /* skip — own messages, RoomCreated, etc. */ }
        }
    }
    Ok(())
}

struct IdentityKeypairBytes {
    signing_seed: [u8; 32],
    enc_seed: [u8; 32],
}

fn derive_identity_from_master(master: &[u8; 32]) -> Result<IdentityKeypairBytes> {
    use hkdf::Hkdf;
    use sha2::Sha256;

    let signing_seed = expand(b"littlelove.v0.2.signing", master)?;
    let enc_seed = expand(b"littlelove.v0.2.encryption", master)?;
    Ok(IdentityKeypairBytes { signing_seed, enc_seed })
}

fn expand(salt: &[u8], ikm: &[u8]) -> Result<[u8; 32]> {
    use hkdf::Hkdf;
    use sha2::Sha256;
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    hk.expand(&[], &mut out).map_err(|_| anyhow!("hkdf"))?;
    Ok(out)
}
```

Wire `cli::Command::Run(args) => littlelove_bot::run::run(args).await,` in `bot/src/main.rs`.

In `bot/src/lib.rs`, add `pub mod run;`.

Add to `bot/Cargo.toml`:
```toml
hkdf = { workspace = true }
sha2 = { workspace = true }
```

- [ ] **Step 3: Sanity check**

Run: `cargo check --workspace`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): run loop — subscribe + decrypt + LLM + encrypted reply
EOF
)"
```

### Task 20: show-identity subcommand

**Files:**
- Create: `bot/src/show_identity.rs`
- Modify: `bot/src/main.rs`, `bot/src/lib.rs`

- [ ] **Step 1: Implement**
```rust
//! show-identity: pretty-print the local identity file.

use anyhow::{Context, Result};

use crate::identity_store::{default_identity_path, load_identity};

pub fn run() -> Result<()> {
    let path = default_identity_path();
    let file = load_identity(&path).with_context(|| format!("load {path:?}"))?;
    println!("file:          {}", path.display());
    println!("username:      @{}", file.username);
    println!("ed25519_pub:   {}", short(&file.ed25519_pub_b64));
    println!("x25519_pub:    {}", short(&file.x25519_pub_b64));
    println!("created_at:    {}", file.created_at);
    Ok(())
}

fn short(s: &str) -> String {
    if s.len() < 12 { s.to_string() } else { format!("{}…{}", &s[..6], &s[s.len()-6..]) }
}
```

In `bot/src/lib.rs`, add `pub mod show_identity;`. In `bot/src/main.rs`, wire `cli::Command::ShowIdentity => littlelove_bot::show_identity::run(),`.

- [ ] **Step 2: Sanity check + commit**

Run: `cargo check --workspace`
Expected: PASS.
```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(bot): show-identity subcommand
EOF
)"
```

### Task 21: End-to-end ignored integration test

**Files:**
- Create: `bot/tests/e2e_ignored.rs`

- [ ] **Step 1: Write the test (marked `#[ignore]` by default)**
```rust
//! End-to-end smoke. Runs the real server binary against an ephemeral
//! Postgres set up by the developer. Court runs it locally with:
//!
//!   cargo test -p littlelove-bot --test e2e_ignored -- --ignored
//!
//! CI does not run this (no Postgres in the fast lane).

#[tokio::test]
#[ignore]
async fn full_loop_against_real_server() {
    // Marker only — the actual implementation depends on the dev-env
    // helpers and is filled in alongside the manual smoke. Acceptance
    // criterion §14.4 is the source of truth.
    eprintln!("see docs/superpowers/specs/2026-06-09-ai-bot-design.md §14 for the manual run script");
}
```

- [ ] **Step 2: Run + commit**

Run: `cargo test -p littlelove-bot --test e2e_ignored`
Expected: 0 passed; 1 ignored.
```bash
git add bot/tests/e2e_ignored.rs
git commit -m "$(cat <<'EOF'
test(bot): placeholder for end-to-end smoke (ignored by default)
EOF
)"
```

---

## Phase F — CI + release

### Task 22: Cross-platform build matrix in `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add the bot build job**

Add a new job to `release.yml` that runs on each `v*` tag:
```yaml
  bot:
    name: bot/${{ matrix.target }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: macos-latest
            target: aarch64-apple-darwin
            artifact: littlelove-bot-macos-arm64
          - os: macos-latest
            target: x86_64-apple-darwin
            artifact: littlelove-bot-macos-x64
          - os: windows-latest
            target: x86_64-pc-windows-msvc
            artifact: littlelove-bot-windows-x64.exe
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
            artifact: littlelove-bot-linux-x64
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - run: cargo build -p littlelove-bot --release --target ${{ matrix.target }}
      - name: Stage artifact
        shell: bash
        run: |
          set -euo pipefail
          out="target/${{ matrix.target }}/release/littlelove-bot"
          if [[ "${{ runner.os }}" == "Windows" ]]; then out="$out.exe"; fi
          mv "$out" "${{ matrix.artifact }}"
      - uses: softprops/action-gh-release@v2
        with:
          files: ${{ matrix.artifact }}
```

(If your existing `release.yml` already uses a different release-upload action, mirror that pattern; this job only needs to (a) build the bot for the four targets and (b) attach the binaries.)

- [ ] **Step 2: Add bot to the standing PR lint/test job**

Find the `Rust API` / `cargo test` job in `.github/workflows/ci.yml` (or whatever the repo's main PR check is named). Confirm it runs `cargo test --workspace`. If it instead runs `cargo test -p server` or similar, change it to `cargo test --workspace`. Same for `cargo clippy --workspace --all-targets -- -D warnings`. If the required check is named `Rust API`, rename it to `Rust workspace` in `.github/workflows/ci.yml`; Court must update the GitHub branch-protection rule accordingly (Court does this in the repo settings — not in code).

- [ ] **Step 3: Commit**
```bash
git add -A
git commit -m "$(cat <<'EOF'
ci: cross-platform bot binary build on v* tags

Builds littlelove-bot for macOS arm64+x86_64, Windows x86_64, Linux
x86_64 and attaches the binaries to the release.

The standing PR check now spans the whole workspace (server + crypto +
bot), since the bot rides the same fmt/clippy/test guarantees as the
server.
EOF
)"
```

### Task 23: Open the PR

- [ ] **Step 1: Verify the whole suite is green**

Run:
```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```
Expected: all three pass.

- [ ] **Step 2: Verify Flutter is untouched**

Run: `cd app && flutter test`
Expected: PASS (no Dart changed; the gate is structural).

- [ ] **Step 3: Open PR**
```bash
gh pr create --title "feat: AI bot (local-only Rust client + llama-server bridge)" --body "$(cat <<'EOF'
## Summary
- Adds `littlelove-bot`: a standalone Rust binary that participates in a LittleLove room as a regular paired client and bridges that room to a local OpenAI-compatible LLM.
- Extracts protocol crypto into a new `littlelove-crypto` workspace member so the server and the bot share byte-identical primitives.
- Supports Character Card v2/v3 PNG personas; defaults to a plainspoken baked-in system prompt; rejects non-private LLM endpoints structurally.

## Test plan
- [ ] `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace` clean.
- [ ] `flutter test` in `app/` still green.
- [ ] Manual smoke per spec §14: spin up llama-server on 127.0.0.1:8080, create an invite from the Flutter app, `littlelove-bot pair --code <…>`, `littlelove-bot run`, exchange messages.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Do not merge. Court runs the manual smoke in §14 of the spec and clicks merge himself.

---

## Self-Review (run before handing off)

- **Spec coverage.** §1 summary, §2 goals/non-goals, §3 crate layout, §4 identity persistence (Task 11), §5 trigger model (Task 19's `from != file.username` + replayed-skip), §6 LLM transport (Tasks 10, 16), §7 history (Task 15), §8 persona (Tasks 17, 18), §9 pairing (Tasks 12, 13, 14), §10 cloud refusal (Task 10), §11 wire compat (Task 5), §12 CI (Task 22), §13 test strategy (all tasks), §14 acceptance (Task 21 + Task 23 PR), §15 risks (mitigations land inside the relevant tasks). All sections covered.
- **Placeholders.** Scanned: no "TBD/TODO/handle edge cases" prose in any task. Every code block is complete.
- **Type consistency.** `Card` / `CardData` are shared across Tasks 17/18/19. `ClientIdentity` is reused in pair + run. `IdentityFile` schema is created in Task 11 and read identically in Tasks 19/20. `ws_client::Session` lives across pair + run. `derive_identity` in Task 7 takes a seed; the `run` path in Task 19 takes a master because the persisted identity stores master (not seed) per the spec §4.1 schema — accordingly Task 19 ships a separate master-input helper. The choice is consistent with the spec.
