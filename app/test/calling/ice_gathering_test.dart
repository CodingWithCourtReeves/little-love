import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:littlelove/calling/call_session.dart';

void main() {
  test('returns once gathering completes', () async {
    final states = StreamController<RTCIceGatheringState>.broadcast();
    addTearDown(states.close);
    var done = false;
    final wait = waitForIceGathering(
      states.stream,
      current: RTCIceGatheringState.RTCIceGatheringStateGathering,
      cap: const Duration(seconds: 30),
    ).then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    states.add(RTCIceGatheringState.RTCIceGatheringStateComplete);
    await wait;
    expect(done, isTrue);
  });

  test('returns at once when already complete', () async {
    final states = StreamController<RTCIceGatheringState>.broadcast();
    addTearDown(states.close);
    await waitForIceGathering(
      states.stream,
      current: RTCIceGatheringState.RTCIceGatheringStateComplete,
      cap: const Duration(seconds: 30),
    );
  });

  test('gives up at the cap instead of hanging', () async {
    final states = StreamController<RTCIceGatheringState>.broadcast();
    addTearDown(states.close);
    await waitForIceGathering(
      states.stream,
      current: RTCIceGatheringState.RTCIceGatheringStateGathering,
      cap: const Duration(milliseconds: 20),
    );
  });
}
