import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/diagnostics/crash_reporting.dart';
import 'package:sentry/sentry.dart';

// The opt-in invariant: nothing reaches Bugsink unless the user has turned
// crash reporting on. The gate is the chokepoint `beforeSend`/`beforeBreadcrumb`
// route through, kept pure so the invariant is testable without booting the SDK.
void main() {
  group('gateEvent', () {
    test('drops the event entirely when reporting is disabled', () {
      final event = SentryEvent(message: SentryMessage('boom'));
      expect(gateEvent(event, enabled: false), isNull);
    });

    test('scrubs and forwards the event when reporting is enabled', () {
      final event = SentryEvent(
        message: SentryMessage('login for alice@example.com'),
      );
      final out = gateEvent(event, enabled: true);
      expect(out, isNotNull);
      expect(out!.message!.formatted, 'login for [email]');
    });
  });

  group('isExpectedTransientError', () {
    test('treats offline / timeout errors as transient (not reported)', () {
      expect(isExpectedTransientError(TimeoutException('slow')), isTrue);
      expect(
        isExpectedTransientError(const SocketException('no route')),
        isTrue,
      );
    });

    test('treats genuine faults as reportable', () {
      // Crypto/state faults, malformed frames, and HTTP-level failures (e.g. a
      // non-2xx from R2) are real and must be reported, not filtered as noise.
      expect(isExpectedTransientError(StateError('bad')), isFalse);
      expect(
        isExpectedTransientError(const FormatException('bad json')),
        isFalse,
      );
      expect(
        isExpectedTransientError(http.ClientException('R2 PUT failed: 500')),
        isFalse,
      );
    });
  });

  group('gateBreadcrumb', () {
    test('drops the breadcrumb when reporting is disabled', () {
      final crumb = Breadcrumb(message: 'navigated home');
      expect(gateBreadcrumb(crumb, enabled: false), isNull);
    });

    test('scrubs and keeps the breadcrumb when reporting is enabled', () {
      final crumb = Breadcrumb(
        message: 'sent to alice@example.com',
        data: {'token': 'a' * 64},
      );
      final out = gateBreadcrumb(crumb, enabled: true);
      expect(out, isNotNull);
      expect(out!.message, 'sent to [email]');
      expect(out.data!['token'], '[redacted]');
    });
  });
}
