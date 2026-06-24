import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_controller.dart';

void main() {
  // Regression: starting a call while the composer keyboard is up left the
  // keyboard focused, so the OS keyboard stayed visible over the call screen
  // (the CallOverlay layers above the still-mounted, still-focused chat). A
  // call start must drop focus. No account is wired, so placeCall bails right
  // after the unfocus, exercising exactly that line without any network/WebRTC.
  testWidgets('placeCall dismisses the keyboard', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Material(
            child: TextField(focusNode: focusNode, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, focusNode);

    await container.read(callControllerProvider).placeCall('room-x');
    await tester.pump();

    expect(focusNode.hasPrimaryFocus, isFalse);
  });
}
