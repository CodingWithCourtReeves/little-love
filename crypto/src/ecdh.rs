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
    hk.expand(room_id.as_bytes(), &mut out)
        .map_err(|_| EcdhError::Hkdf)?;
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
