//! Redaction for everything we send to our self-hosted error monitor.
//!
//! Both `before_send` (events / `error!`) and `before_breadcrumb` (breadcrumbs
//! / `warn!`/`info!`) route through here, so every payload that reaches Bugsink
//! is scrubbed at one chokepoint. This keeps diagnostics content-free and
//! identifier-free, in line with our privacy policy: the server only ever holds
//! ciphertext for message *content*, but log lines can still carry user
//! identifiers (handles, account ids) and opaque secrets (push tokens, the DSN,
//! DB error detail), and none of those should leave our boundary.
//!
//! `redact` catches *structured* leak vectors (emails, account UUIDs/ULIDs,
//! hex/base64 tokens, Postgres `Key (col)=(val)` detail, credentialed URIs,
//! prefixed API keys). Free-form handles like `alice` can't be pattern-matched,
//! so call sites we control must not interpolate raw usernames in the first
//! place — `redact` is defense-in-depth, not the only line of defense.

use std::sync::OnceLock;

use regex::Regex;
use sentry::protocol::{Breadcrumb, Event};
use serde_json::Value;

/// Ordered redaction passes. Order matters: more specific patterns (URIs with
/// credentials, emails, Postgres detail) run before the broad hex/base64
/// catch-alls so the broad ones don't shadow a nicer replacement label.
fn passes() -> &'static [(Regex, &'static str)] {
    static PASSES: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    PASSES.get_or_init(|| {
        vec![
            // scheme://user:pass@host/... or scheme://key@host/... (DSN, DB URL)
            (
                Regex::new(r"(?i)\b[a-z][a-z0-9+.\-]*://[^\s/@]+@\S+").unwrap(),
                "[uri]",
            ),
            // email addresses
            (
                Regex::new(r"(?i)\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b").unwrap(),
                "[email]",
            ),
            // Postgres constraint detail: `(col)=(value)` -> redact the value side
            (
                Regex::new(r"\([^()]*\)=\([^()]*\)").unwrap(),
                "([redacted])=([redacted])",
            ),
            // UUID (account ids, etc.)
            (
                Regex::new(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
                    .unwrap(),
                "[id]",
            ),
            // ULID (Crockford base32, 26 chars) — ids, invite codes
            (Regex::new(r"\b[0-9A-HJKMNP-TV-Z]{26}\b").unwrap(), "[id]"),
            // prefixed API keys: sk_, rk_, pk_, key-, tok_, bearer_ ...
            (
                Regex::new(r"(?i)\b(?:sk|rk|pk|key|tok|bearer)[-_][a-z0-9]{12,}\b").unwrap(),
                "[redacted]",
            ),
            // long hex blobs: APNs device tokens (64), sha256, raw keys
            (Regex::new(r"(?i)\b[0-9a-f]{32,}\b").unwrap(), "[redacted]"),
            // base64 / base64url token blobs (kept tight to avoid eating
            // snake_case symbols: no `_`, requires length >= 32 or `=` padding)
            (
                Regex::new(r"\b[A-Za-z0-9+/]{32,}={0,2}\b").unwrap(),
                "[redacted]",
            ),
        ]
    })
}

/// Redact identifiers and secret-like tokens from a free-text string. Idempotent
/// enough that re-running it on already-redacted text is harmless.
pub fn redact(input: &str) -> String {
    let mut out = input.to_string();
    for (re, repl) in passes() {
        out = re.replace_all(&out, *repl).into_owned();
    }
    out
}

/// Field names whose *value* is an identifier or secret and must be dropped
/// wholesale, regardless of shape. `sentry-tracing` turns a structured log field
/// like `warn!(username = %me.username, "...")` into a `data`/`extra` entry
/// keyed by the field name, so keying off the name catches free-form handles
/// (`alice`) that `redact`'s patterns can't. Match is case-insensitive and exact
/// on the key.
const SENSITIVE_KEYS: &[&str] = &[
    "username",
    "user",
    "handle",
    "sender",
    "recipient",
    "partner",
    "account",
    "account_id",
    "accountid",
    "email",
    "token",
    "dsn",
    "auth",
    "authorization",
    "password",
    "secret",
    "apikey",
    "api_key",
];

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    SENSITIVE_KEYS.iter().any(|s| key == *s)
}

/// Scrub one key/value pair: drop the value entirely for a sensitive key,
/// otherwise recurse and pattern-redact its strings.
fn scrub_kv(key: &str, v: &mut Value) {
    if is_sensitive_key(key) {
        *v = Value::String("[redacted]".into());
    } else {
        scrub_value(v);
    }
}

/// Recursively redact every string inside a JSON value (used for the `extra` /
/// breadcrumb `data` bags that `sentry-tracing` fills from event fields).
fn scrub_value(v: &mut Value) {
    match v {
        Value::String(s) => *s = redact(s),
        Value::Array(a) => a.iter_mut().for_each(scrub_value),
        Value::Object(o) => o.iter_mut().for_each(|(k, val)| scrub_kv(k, val)),
        _ => {}
    }
}

/// Scrub a breadcrumb in place. Wired into `before_breadcrumb`, so it runs for
/// every `warn!`/`info!` the `sentry-tracing` layer records.
pub fn scrub_breadcrumb(b: &mut Breadcrumb) {
    if let Some(m) = b.message.as_mut() {
        *m = redact(m);
    }
    b.data.iter_mut().for_each(|(k, v)| scrub_kv(k, v));
}

/// Scrub an event in place across every field that can carry free text. Wired
/// into `before_send`, so it runs for every captured event (`error!` + panics),
/// including any breadcrumbs already attached to it.
pub fn scrub_event(e: &mut Event) {
    if let Some(m) = e.message.as_mut() {
        *m = redact(m);
    }
    if let Some(le) = e.logentry.as_mut() {
        le.message = redact(&le.message);
    }
    if let Some(t) = e.transaction.as_mut() {
        *t = redact(t);
    }
    for ex in e.exception.values.iter_mut() {
        if let Some(v) = ex.value.as_mut() {
            *v = redact(v);
        }
    }
    for b in e.breadcrumbs.values.iter_mut() {
        scrub_breadcrumb(b);
    }
    e.extra.iter_mut().for_each(|(k, v)| scrub_kv(k, v));
    // `tags` are flat strings (sentry-tracing can populate them from span
    // fields); apply the same key-based + pattern redaction.
    e.tags.iter_mut().for_each(|(k, v)| {
        *v = if is_sensitive_key(k) {
            "[redacted]".to_string()
        } else {
            redact(v)
        };
    });
    // The container hostname (set by the contexts integration even with
    // send_default_pii=false) is not user data, but it's needless to exfiltrate.
    e.server_name = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_email() {
        assert_eq!(
            redact("contact alice@example.com please"),
            "contact [email] please"
        );
    }

    #[test]
    fn redacts_credentialed_uri() {
        // A Sentry DSN or DB URL must never survive.
        assert_eq!(
            redact("dsn=https://abc123@bugsink-production.up.railway.app/1 ok"),
            "dsn=[uri] ok"
        );
    }

    #[test]
    fn redacts_postgres_unique_violation_value() {
        let msg = "duplicate key value violates unique constraint: Key (username)=(alice) already exists.";
        let out = redact(msg);
        assert!(!out.contains("alice"), "username value leaked: {out}");
        assert!(out.contains("([redacted])=([redacted])"), "got: {out}");
    }

    #[test]
    fn redacts_uuid_and_ulid() {
        assert_eq!(
            redact("acct 550e8400-e29b-41d4-a716-446655440000 done"),
            "acct [id] done"
        );
        assert_eq!(
            redact("invite 01ARZ3NDEKTSV4RRFFQ69G5FAV here"),
            "invite [id] here"
        );
    }

    #[test]
    fn redacts_apns_hex_token_and_base64_blob() {
        let hex = "a".repeat(64);
        assert_eq!(
            redact(&format!("token {hex} sent")),
            "token [redacted] sent"
        );
        let b64 = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5";
        assert_eq!(redact(&format!("blob {b64} end")), "blob [redacted] end");
    }

    #[test]
    fn redacts_prefixed_api_key() {
        assert_eq!(
            redact("RESEND_API_KEY=rk_AbCd1234EfGh5678 set"),
            "RESEND_API_KEY=[redacted] set"
        );
    }

    #[test]
    fn scrub_event_redacts_message_and_exception_and_breadcrumbs() {
        let mut e = Event {
            message: Some("login for alice@example.com failed".into()),
            ..Default::default()
        };
        e.exception.values.push(sentry::protocol::Exception {
            value: Some("Key (username)=(alice) already exists.".into()),
            ..Default::default()
        });
        let mut bc = Breadcrumb {
            message: Some("acct 550e8400-e29b-41d4-a716-446655440000 dropped".into()),
            ..Default::default()
        };
        bc.data
            .insert("token".into(), Value::String("a".repeat(64)));
        e.breadcrumbs.values.push(bc);

        scrub_event(&mut e);

        assert_eq!(e.message.as_deref(), Some("login for [email] failed"));
        let ex = e.exception.values[0].value.as_deref().unwrap();
        assert!(!ex.contains("alice"), "exception leaked value: {ex}");
        let b = &e.breadcrumbs.values[0];
        assert_eq!(b.message.as_deref(), Some("acct [id] dropped"));
        assert_eq!(
            b.data.get("token"),
            Some(&Value::String("[redacted]".into()))
        );
    }

    #[test]
    fn scrub_event_redacts_tags_and_clears_server_name() {
        let mut e = Event {
            server_name: Some("railway-container-abc123".into()),
            ..Default::default()
        };
        e.tags.insert("username".into(), "alice".into()); // sensitive key
        e.tags.insert(
            "note".into(),
            "acct 550e8400-e29b-41d4-a716-446655440000".into(),
        ); // pattern
        scrub_event(&mut e);
        assert_eq!(
            e.tags.get("username").map(String::as_str),
            Some("[redacted]")
        );
        assert_eq!(e.tags.get("note").map(String::as_str), Some("acct [id]"));
        assert!(e.server_name.is_none());
    }

    #[test]
    fn scrub_breadcrumb_redacts_sensitive_keys_even_when_value_is_a_plain_handle() {
        // The whole point of key-based redaction: a free-form handle like
        // "alice" that no pattern would catch must still be dropped because it
        // arrived under a `username` field.
        let mut b = Breadcrumb {
            message: Some("typing rate limit hit".into()),
            ..Default::default()
        };
        b.data
            .insert("username".into(), Value::String("alice".into()));
        b.data
            .insert("room".into(), Value::String("kitchen".into())); // non-sensitive: kept
        scrub_breadcrumb(&mut b);
        assert_eq!(
            b.data.get("username"),
            Some(&Value::String("[redacted]".into()))
        );
        assert_eq!(b.data.get("room"), Some(&Value::String("kitchen".into())));
    }

    #[test]
    fn scrub_breadcrumb_redacts_message() {
        let mut b = Breadcrumb {
            message: Some("RegisterPush failed for 01ARZ3NDEKTSV4RRFFQ69G5FAV".into()),
            ..Default::default()
        };
        scrub_breadcrumb(&mut b);
        assert_eq!(b.message.as_deref(), Some("RegisterPush failed for [id]"));
    }

    #[test]
    fn preserves_ordinary_error_text_and_symbols() {
        // Snake_case symbols and short words must survive so stack traces and
        // module paths stay useful.
        let msg =
            "store.insert_many failed: connection reset by peer in littlelove_api::ws::handle_send";
        assert_eq!(redact(msg), msg);
    }
}
