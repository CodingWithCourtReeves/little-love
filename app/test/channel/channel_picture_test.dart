import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/channel/channel_line.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/conversation/message_content.dart';

void main() {
  test('channelColorFor is stable for a seed and spreads across all six '
      'colours', () {
    expect(channelColorFor('room-1'), channelColorFor('room-1'));
    final hit = {for (var i = 1; i <= 60; i++) channelColorFor('r$i')};
    expect(hit, ChannelColor.values.toSet());
  });

  test('channelLineText words each change', () {
    expect(
      channelLineText(
        const ChannelUpdateContent(
          picture: SymbolPicture(ChannelSymbol.heart, ChannelColor.rose),
        ),
        who: 'Kaitlyn',
      ),
      'Kaitlyn changed the channel picture',
    );
    expect(
      channelLineText(
        const ChannelUpdateContent(picture: NoPicture()),
        who: 'You',
      ),
      'You removed the channel picture',
    );
    expect(
      channelLineText(
        const ChannelUpdateContent(name: 'Trips'),
        who: 'Kaitlyn',
      ),
      'Kaitlyn renamed the channel to Trips',
    );
  });
}
