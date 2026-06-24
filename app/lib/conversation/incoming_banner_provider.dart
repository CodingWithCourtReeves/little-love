import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A "your partner messaged in another room" event, surfaced as a transient
/// in-app banner. Published by the room message router when a *live* message
/// lands in a room that isn't on screen; consumed by the app-shell banner host.
@immutable
class IncomingBanner {
  const IncomingBanner({
    required this.roomId,
    required this.roomName,
    required this.preview,
    required this.msgId,
  });

  /// The room the message arrived in (where a tap should navigate).
  final String roomId;

  /// Human-readable room name shown in the banner.
  final String roomName;

  /// Short decrypted snippet of the message body (client-side; the server push
  /// stays content-free because the server can't read E2EE bodies).
  final String preview;

  /// The message id — used to clear only this banner when its timer fires, so a
  /// stale timer can't wipe a newer banner.
  final String msgId;
}

/// Holds the latest banner to show, or null when nothing is pending. A newer
/// event replaces any still-showing one (the host resets its dismiss timer).
class IncomingBannerNotifier extends Notifier<IncomingBanner?> {
  @override
  IncomingBanner? build() => null;

  void show(IncomingBanner banner) => state = banner;

  /// Clear the banner. With no [msgId] this always clears (manual/tap dismiss);
  /// with one it clears only if that banner is still current, so a late
  /// auto-dismiss timer can't wipe a banner that already advanced to a newer
  /// message.
  void clear({String? msgId}) {
    if (msgId == null || state?.msgId == msgId) state = null;
  }
}

final incomingBannerProvider =
    NotifierProvider<IncomingBannerNotifier, IncomingBanner?>(
      IncomingBannerNotifier.new,
    );
