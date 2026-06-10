//! Cross-language fixture test for the BIP39 invite-code encoding (spec §8.6).
//!
//! WT-B owns the canonical fixture file at `server/tests/data/invite_vectors.json`.
//! WT-D's Dart implementation must produce byte-for-byte identical 4-word codes
//! for the same 8 input tokens.
//!
//! Behavior:
//!   - If the fixture file does not exist, we generate it from the 8 deterministic
//!     `n44` values below and write it. The test then succeeds.
//!   - If the fixture exists, we read each entry and assert our current
//!     implementation produces the same `code` and `canonical_token_hex`.
//!
//! That makes the test:
//!   1. Self-bootstrapping (first run creates the file).
//!   2. A regression guard (subsequent runs fail loudly on any drift).
//!
//! The fixture is the source of truth that WT-D consumes — never edit it by hand.

use std::fs;
use std::path::PathBuf;

use littlelove_api::invites::{canonical_token_from_n44, encode_code, CANONICAL_TOKEN_LEN};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Vector {
    /// 11 hex digits = 44 bits.
    n44_hex: String,
    /// Lowercase hex of the canonical 32-byte token.
    canonical_token_hex: String,
    /// Expected 4-word code joined with `-`.
    code: String,
}

/// 8 deterministic test inputs exercising edge cases (44-bit values).
#[allow(clippy::unusual_byte_groupings)]
const N44_VECTORS: [u64; 8] = [
    0,
    (1u64 << 44) - 1,
    0x5_5555_55555, // alternating bit pattern starting with 0
    0xA_AAAA_AAAAA, // alternating bit pattern starting with 1
    0x1_2345_6789A, // arbitrary mid-range
    0xF_EDCB_A9876, // descending nibbles
    0x0_0000_00001, // smallest non-zero
    0x8_0000_00000, // high bit set, rest zero
];

fn hex32(b: &[u8; CANONICAL_TOKEN_LEN]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn fixture_path() -> PathBuf {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    PathBuf::from(manifest_dir).join("tests/data/invite_vectors.json")
}

fn build_vectors() -> Vec<Vector> {
    N44_VECTORS
        .iter()
        .map(|&n| {
            let canonical = canonical_token_from_n44(n);
            Vector {
                n44_hex: format!("{n:011x}"),
                canonical_token_hex: hex32(&canonical),
                code: encode_code(&canonical),
            }
        })
        .collect()
}

#[test]
fn fixture_round_trips_against_implementation() {
    let path = fixture_path();
    let generated = build_vectors();

    if !path.exists() {
        let dir = path.parent().expect("fixture parent dir");
        fs::create_dir_all(dir).expect("create fixture dir");
        let json = serde_json::to_string_pretty(&generated).expect("serialize");
        fs::write(&path, json + "\n").expect("write fixture");
        eprintln!("wrote fresh fixture at {}", path.display());
        return;
    }

    let on_disk: Vec<Vector> =
        serde_json::from_str(&fs::read_to_string(&path).expect("read fixture"))
            .expect("parse fixture");

    assert_eq!(
        on_disk.len(),
        generated.len(),
        "fixture size drift — regenerate by deleting {} and rerunning",
        path.display()
    );

    for (i, (disk, fresh)) in on_disk.iter().zip(generated.iter()).enumerate() {
        assert_eq!(
            disk, fresh,
            "vector {i} drifted: on-disk {disk:?} vs current impl {fresh:?}"
        );
    }
}
