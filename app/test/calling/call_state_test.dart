import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_state.dart';

void main() {
  const idle = CallState.idle();

  group('outgoing flow', () {
    test('idle.placeCall → dialing (outgoing)', () {
      final s = idle.placeCall('c1');
      expect(s.phase, CallPhase.dialing);
      expect(s.direction, CallDirection.outgoing);
      expect(s.callId, 'c1');
    });

    test('dialing.remoteAnswered → connecting → active', () {
      final s = idle.placeCall('c1').remoteAnswered();
      expect(s.phase, CallPhase.connecting);
      final a = s.iceConnected();
      expect(a.phase, CallPhase.active);
      expect(a.isActive, isTrue);
    });

    test('active.hangup → ended(completed)', () {
      final s = idle.placeCall('c1').remoteAnswered().iceConnected().hangup('hangup');
      expect(s.phase, CallPhase.ended);
      expect(s.outcome, CallOutcome.completed);
    });

    test('dialing.timeout → ended(missed)', () {
      final s = idle.placeCall('c1').timeout();
      expect(s.outcome, CallOutcome.missed);
    });

    test('dialing.hangup(cancel) → ended(cancelled)', () {
      final s = idle.placeCall('c1').hangup('cancel');
      expect(s.outcome, CallOutcome.cancelled);
    });
  });

  group('incoming flow', () {
    test('idle.incoming → ringing (incoming)', () {
      final s = idle.incoming('c1');
      expect(s.phase, CallPhase.ringing);
      expect(s.direction, CallDirection.incoming);
    });

    test('ringing.accept → connecting', () {
      expect(idle.incoming('c1').accept().phase, CallPhase.connecting);
    });

    test('ringing.hangup(decline) → ended(declined)', () {
      expect(idle.incoming('c1').hangup('decline').outcome, CallOutcome.declined);
    });

    test('ringing.timeout → ended(missed)', () {
      expect(idle.incoming('c1').timeout().outcome, CallOutcome.missed);
    });
  });

  group('media failure', () {
    test('connecting.iceFailed → ended(failed)', () {
      final s = idle.placeCall('c1').remoteAnswered().iceFailed();
      expect(s.outcome, CallOutcome.failed);
    });
  });

  group('illegal transitions throw', () {
    test('idle.accept throws', () {
      expect(() => idle.accept(), throwsStateError);
    });
    test('idle.hangup throws', () {
      expect(() => idle.hangup('hangup'), throwsStateError);
    });
    test('active.accept throws', () {
      final active = idle.incoming('c1').accept().iceConnected();
      expect(() => active.accept(), throwsStateError);
    });
    test('ended.hangup throws', () {
      final ended = idle.placeCall('c1').hangup('cancel');
      expect(() => ended.hangup('hangup'), throwsStateError);
    });
    test('idle.timeout throws', () {
      expect(() => idle.timeout(), throwsStateError);
    });
  });
}
