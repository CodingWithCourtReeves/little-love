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
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &[],
            },
        )
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
    let ct = B64
        .decode(env.ciphertext.as_bytes())
        .map_err(|_| AeadError::Base64)?;
    let nonce = B64
        .decode(env.nonce.as_bytes())
        .map_err(|_| AeadError::Base64)?;
    if nonce.len() != NONCE_LEN {
        return Err(AeadError::NonceLen(nonce.len()));
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(XNonce::from_slice(&nonce), Payload { msg: &ct, aad: &[] })
        .map_err(|_| AeadError::Decrypt)
}
