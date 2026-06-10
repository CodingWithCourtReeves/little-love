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
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../server/tests/data/invite_vectors.json"
    );
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
