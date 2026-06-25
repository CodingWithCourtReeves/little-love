/// Redaction for everything we send to our self-hosted error monitor.
///
/// This is the app-side mirror of `server/src/scrub.rs`. Both the `beforeSend`
/// (events / captured errors) and `beforeBreadcrumb` (logs) hooks route through
/// here, so every payload that reaches Bugsink is scrubbed at one chokepoint.
///
/// The app is the only place plaintext exists (message text, contact names,
/// attachment paths, room keys), so this is stricter in spirit than the
/// server's copy: treat every outbound field as a potential leak and default
/// to redaction. [redact] catches *structured* leak vectors (emails, account
/// UUIDs/ULIDs, hex/base64 tokens, credentialed URIs, prefixed API keys);
/// [isSensitiveKey] drops a value wholesale when its field name names an
/// identifier or secret. Free-form handles like `alice` can't be
/// pattern-matched, so call sites must never interpolate them into a message
/// in the first place: [redact] is defense-in-depth, not the only line.
library;

import 'package:sentry/sentry.dart';

class _Pass {
  const _Pass(this.re, this.repl);
  final RegExp re;
  final String repl;
}

/// Ordered redaction passes. Order matters: more specific patterns (credentialed
/// URIs, emails, Postgres detail) run before the broad hex/base64 catch-alls so
/// the broad ones don't shadow a nicer replacement label. Dart's [RegExp] has no
/// inline `(?i)` flag, so case-insensitivity rides on `caseSensitive: false`;
/// the ULID (Crockford uppercase) and base64 passes stay case-sensitive to match
/// the server.
final List<_Pass> _passes = [
  // scheme://user:pass@host/... or scheme://key@host/... (DSN, DB URL)
  _Pass(
    RegExp(r'\b[a-z][a-z0-9+.\-]*://[^\s/@]+@\S+', caseSensitive: false),
    '[uri]',
  ),
  // email addresses
  _Pass(
    RegExp(
      r'\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b',
      caseSensitive: false,
    ),
    '[email]',
  ),
  // Postgres constraint detail: `(col)=(value)` -> redact the value side
  _Pass(RegExp(r'\([^()]*\)=\([^()]*\)'), '([redacted])=([redacted])'),
  // UUID (account ids, etc.)
  _Pass(
    RegExp(
      r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
      caseSensitive: false,
    ),
    '[id]',
  ),
  // ULID (Crockford base32, 26 chars) — ids, invite codes
  _Pass(RegExp(r'\b[0-9A-HJKMNP-TV-Z]{26}\b'), '[id]'),
  // prefixed API keys: sk_, rk_, pk_, key-, tok_, bearer_ ...
  _Pass(
    RegExp(
      r'\b(?:sk|rk|pk|key|tok|bearer)[-_][a-z0-9]{12,}\b',
      caseSensitive: false,
    ),
    '[redacted]',
  ),
  // long hex blobs: APNs device tokens (64), sha256, raw keys
  _Pass(RegExp(r'\b[0-9a-f]{32,}\b', caseSensitive: false), '[redacted]'),
  // base64 / base64url token blobs (no `_`, length >= 32 or `=` padding)
  _Pass(RegExp(r'\b[A-Za-z0-9+/]{32,}={0,2}\b'), '[redacted]'),
];

/// Redact identifiers and secret-like tokens from a free-text string. Idempotent
/// enough that re-running it on already-redacted text is harmless.
String redact(String input) {
  var out = input;
  for (final p in _passes) {
    // replaceAll with a String replacement is literal (no `$` group expansion),
    // so the Postgres replacement's parens pass through verbatim.
    out = out.replaceAll(p.re, p.repl);
  }
  return out;
}

/// Field names whose *value* is an identifier or secret and must be dropped
/// wholesale, regardless of shape. Mirrors the server's list; match is
/// case-insensitive and exact on the key.
const Set<String> _sensitiveKeys = {
  'username',
  'user',
  'handle',
  'sender',
  'recipient',
  'partner',
  'account',
  'account_id',
  'accountid',
  'email',
  'token',
  'dsn',
  'auth',
  'authorization',
  'password',
  'secret',
  'apikey',
  'api_key',
};

bool isSensitiveKey(String key) => _sensitiveKeys.contains(key.toLowerCase());

/// Recursively redact every string inside an arbitrary value (the `extra` /
/// breadcrumb `data` bags). A sensitive *key* drops its value entirely;
/// otherwise strings are pattern-redacted and containers recursed.
Object? scrubValue(Object? v) {
  if (v is String) return redact(v);
  if (v is List) return v.map(scrubValue).toList();
  if (v is Map) {
    return v.map(
      (k, val) => MapEntry(
        k,
        isSensitiveKey(k.toString()) ? '[redacted]' : scrubValue(val),
      ),
    );
  }
  return v;
}

Map<String, dynamic>? _scrubData(Map<String, dynamic>? data) {
  if (data == null) return null;
  return data.map(
    (k, v) => MapEntry(k, isSensitiveKey(k) ? '[redacted]' : scrubValue(v)),
  );
}

/// Scrub a breadcrumb. Wired into `beforeBreadcrumb`, so it runs for every
/// log/navigation/network crumb the SDK records. Returns null only when handed
/// null (so it composes with the hook signature).
Breadcrumb? scrubBreadcrumb(Breadcrumb? b) {
  if (b == null) return null;
  return b.copyWith(
    message: b.message == null ? null : redact(b.message!),
    data: _scrubData(b.data),
  );
}

/// Scrub an event across every field that can carry free text. Wired into
/// `beforeSend`, so it runs for every captured event, including any breadcrumbs
/// already attached to it.
///
/// `serverName` is left to the SDK: we never set `options.serverName`, and on
/// iOS the SDK doesn't auto-populate it, so it stays null. That (not a per-event
/// clear) is the control point for the device-name leak the server scrubs.
SentryEvent? scrubEvent(SentryEvent? e) {
  if (e == null) return null;
  return e.copyWith(
    message: _scrubMessage(e.message),
    transaction: e.transaction == null ? null : redact(e.transaction!),
    exceptions: e.exceptions
        ?.map(
          (ex) => ex.value == null ? ex : ex.copyWith(value: redact(ex.value!)),
        )
        .toList(),
    breadcrumbs: e.breadcrumbs?.map((b) => scrubBreadcrumb(b)!).toList(),
    // `extra` is deprecated in the SDK but still carries free text if anything
    // populates it, so we scrub it defensively.
    // ignore: deprecated_member_use
    extra: _scrubData(e.extra),
    tags: e.tags?.map(
      (k, v) => MapEntry(k, isSensitiveKey(k) ? '[redacted]' : redact(v)),
    ),
  );
}

SentryMessage? _scrubMessage(SentryMessage? m) {
  if (m == null) return null;
  return m.copyWith(formatted: redact(m.formatted));
}
