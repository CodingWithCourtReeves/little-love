import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_privacy.dart';

void main() {
  test('screenshot event round-trips (no active field)', () {
    final wire = const PrivacyEvent(PrivacyKind.screenshot).encode();
    final ev = PrivacyEvent.decode(wire)!;
    expect(ev.kind, PrivacyKind.screenshot);
    expect(ev.active, isFalse);
  });

  test('recording event carries the active flag', () {
    final on = PrivacyEvent.decode(
      const PrivacyEvent(PrivacyKind.recording, active: true).encode(),
    )!;
    expect(on.kind, PrivacyKind.recording);
    expect(on.active, isTrue);

    final off = PrivacyEvent.decode(
      const PrivacyEvent(PrivacyKind.recording, active: false).encode(),
    )!;
    expect(off.active, isFalse);
  });

  test('camera event carries on/off state', () {
    final off = PrivacyEvent.decode(
      const PrivacyEvent(PrivacyKind.camera, active: false).encode(),
    )!;
    expect(off.kind, PrivacyKind.camera);
    expect(off.active, isFalse);
    expect(
      PrivacyEvent.decode(
        const PrivacyEvent(PrivacyKind.camera, active: true).encode(),
      )!.active,
      isTrue,
    );
  });

  test('malformed or unknown payloads decode to null, never throw', () {
    expect(PrivacyEvent.decode('not json'), isNull);
    expect(PrivacyEvent.decode('{}'), isNull);
    expect(PrivacyEvent.decode('{"t":"future_kind"}'), isNull);
  });
}
