import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/diagnostics/scrub.dart';
import 'package:sentry/sentry.dart';

// Mirrors server/src/scrub.rs tests. The app is the only place plaintext
// exists, so these are the contract that keeps diagnostics content-free and
// identifier-free before anything reaches Bugsink.
void main() {
  group('redact', () {
    test('redacts email', () {
      expect(
        redact('contact alice@example.com please'),
        'contact [email] please',
      );
    });

    test('redacts credentialed uri (DSN / DB URL)', () {
      expect(
        redact('dsn=https://abc123@bugsink-production.up.railway.app/1 ok'),
        'dsn=[uri] ok',
      );
    });

    test('redacts postgres unique-violation value', () {
      const msg =
          'duplicate key value violates unique constraint: Key (username)=(alice) already exists.';
      final out = redact(msg);
      expect(out.contains('alice'), isFalse, reason: 'username leaked: $out');
      expect(out.contains('([redacted])=([redacted])'), isTrue, reason: out);
    });

    test('redacts uuid and ulid', () {
      expect(
        redact('acct 550e8400-e29b-41d4-a716-446655440000 done'),
        'acct [id] done',
      );
      expect(
        redact('invite 01ARZ3NDEKTSV4RRFFQ69G5FAV here'),
        'invite [id] here',
      );
    });

    test('redacts apns hex token and base64 blob', () {
      final hex = 'a' * 64;
      expect(redact('token $hex sent'), 'token [redacted] sent');
      const b64 = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5';
      expect(redact('blob $b64 end'), 'blob [redacted] end');
    });

    test('redacts prefixed api key', () {
      expect(
        redact('RESEND_API_KEY=rk_AbCd1234EfGh5678 set'),
        'RESEND_API_KEY=[redacted] set',
      );
    });

    test('preserves ordinary error text and snake_case symbols', () {
      const msg =
          'store.insertMany failed: connection reset by peer in message_store.handleSend';
      expect(redact(msg), msg);
    });
  });

  group('scrubValue', () {
    test('recurses nested maps and lists, dropping sensitive keys', () {
      final scrubbed =
          scrubValue({
                'room': 'kitchen',
                'username': 'alice',
                'nested': [
                  {
                    'email': 'a@b.com',
                    'note': 'acct 550e8400-e29b-41d4-a716-446655440000',
                  },
                ],
              })
              as Map;
      expect(scrubbed['room'], 'kitchen');
      expect(scrubbed['username'], '[redacted]');
      final nested = (scrubbed['nested'] as List).first as Map;
      expect(nested['email'], '[redacted]');
      expect(nested['note'], 'acct [id]');
    });
  });

  group('scrubBreadcrumb', () {
    test('drops sensitive keys even when value is a plain handle', () {
      final b = Breadcrumb(
        message: 'typing rate limit hit',
        data: {'username': 'alice', 'room': 'kitchen'},
      );
      final out = scrubBreadcrumb(b)!;
      expect(out.data!['username'], '[redacted]');
      expect(out.data!['room'], 'kitchen');
    });

    test('redacts the message', () {
      final b = Breadcrumb(
        message: 'RegisterPush failed for 01ARZ3NDEKTSV4RRFFQ69G5FAV',
      );
      expect(scrubBreadcrumb(b)!.message, 'RegisterPush failed for [id]');
    });
  });

  group('scrubEvent', () {
    test('redacts message, exception value, and attached breadcrumbs', () {
      final event = SentryEvent(
        message: SentryMessage('login for alice@example.com failed'),
        exceptions: [
          const SentryException(
            type: 'StateError',
            value: 'Key (username)=(alice) already exists.',
          ),
        ],
        breadcrumbs: [
          Breadcrumb(
            message: 'acct 550e8400-e29b-41d4-a716-446655440000 dropped',
            data: {'token': 'a' * 64},
          ),
        ],
      );

      final out = scrubEvent(event)!;

      expect(out.message!.formatted, 'login for [email] failed');
      final ex = out.exceptions!.first.value!;
      expect(ex.contains('alice'), isFalse, reason: 'exception leaked: $ex');
      expect(out.breadcrumbs!.first.message, 'acct [id] dropped');
      expect(out.breadcrumbs!.first.data!['token'], '[redacted]');
    });

    test('redacts tags (key-based + pattern)', () {
      final event = SentryEvent(
        tags: {
          'username': 'alice',
          'note': 'acct 550e8400-e29b-41d4-a716-446655440000',
        },
      );
      final out = scrubEvent(event)!;
      expect(out.tags!['username'], '[redacted]');
      expect(out.tags!['note'], 'acct [id]');
    });

    test('redacts the transaction name', () {
      final event = SentryEvent(transaction: 'send to alice@example.com');
      expect(scrubEvent(event)!.transaction, 'send to [email]');
    });

    test('redacts a structured message template and params', () {
      // The chokepoint must cover the whole SentryMessage, not just `formatted`:
      // a captureMessage with a template + interpolated params could carry an
      // identifier in either field.
      final event = SentryEvent(
        message: SentryMessage(
          'login for alice@example.com',
          template: 'login for %s',
          params: ['alice@example.com', 7],
        ),
      );
      final out = scrubEvent(event)!.message!;
      expect(out.formatted, 'login for [email]');
      expect(out.template, 'login for %s');
      expect(out.params, ['[email]', 7]);
    });
  });
}
