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
