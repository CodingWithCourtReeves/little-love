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
