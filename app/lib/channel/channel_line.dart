import '../conversation/message_content.dart';
import 'channel_picture.dart';

/// The timeline line for a channel change. [who] is `'You'` or the partner's
/// name, supplied by the caller.
String channelLineText(ChannelUpdateContent c, {required String who}) {
  if (c.name != null) return '$who renamed the channel to ${c.name}';
  if (c.picture is NoPicture) return '$who removed the channel picture';
  return '$who changed the channel picture';
}
