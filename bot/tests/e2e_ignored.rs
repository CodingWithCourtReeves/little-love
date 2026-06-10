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
    eprintln!(
        "see docs/superpowers/specs/2026-06-09-ai-bot-design.md §14 for the manual run script"
    );
}
