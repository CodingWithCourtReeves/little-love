import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_state.dart';
import 'package:littlelove/calling/glare.dart';

void main() {
  const idle = CallState.idle();

  test('idle rings for a new invite', () {
    expect(
      inviteActionFor(idle, inviteCallId: 'c1', self: 'court', from: 'kait'),
      InviteAction.ring,
    );
  });

  test('a repeat of the call already ringing is ignored, not busy', () {
    // The server re-sends a held invite when the callee's socket reconnects.
    final ringing = idle.incoming('c1');
    expect(
      inviteActionFor(ringing, inviteCallId: 'c1', self: 'court', from: 'kait'),
      InviteAction.ignore,
    );
    final connecting = ringing.accept();
    expect(
      inviteActionFor(
        connecting,
        inviteCallId: 'c1',
        self: 'court',
        from: 'kait',
      ),
      InviteAction.ignore,
    );
  });

  test('a different call while busy is refused', () {
    final ringing = idle.incoming('c1');
    expect(
      inviteActionFor(ringing, inviteCallId: 'c2', self: 'court', from: 'kait'),
      InviteAction.busy,
    );
  });

  test('glare: the winner keeps dialing, the loser yields', () {
    final dialing = idle.placeCall('mine');
    expect(
      inviteActionFor(dialing, inviteCallId: 'x', self: 'court', from: 'kait'),
      InviteAction.ignore,
    );
    expect(
      inviteActionFor(dialing, inviteCallId: 'x', self: 'kait', from: 'court'),
      InviteAction.yieldAndRing,
    );
  });
}
