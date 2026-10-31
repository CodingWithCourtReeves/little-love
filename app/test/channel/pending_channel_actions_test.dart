import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/pending_channel_actions.dart';

void main() {
  test('take returns a pending entry once and then null', () {
    final a = PendingChannelActions();
    const choice = ChooseNone();
    a.expectCreated('trips', choice);
    expect(a.takeCreated('other'), isNull);
    expect(a.takeCreated('trips'), same(choice));
    expect(a.takeCreated('trips'), isNull);

    a.expectRename('r1', 'Trips');
    expect(a.takeRename('r2', 'Trips'), isFalse);
    expect(a.takeRename('r1', 'Other'), isFalse);
    expect(a.takeRename('r1', 'Trips'), isTrue);
    expect(a.takeRename('r1', 'Trips'), isFalse);
  });
}
