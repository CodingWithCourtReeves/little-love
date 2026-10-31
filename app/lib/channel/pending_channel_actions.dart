import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'channel_picture.dart';

/// Channel changes I asked for that are waiting on the server's confirmation.
///
/// A rename line or a new channel's picture is only sent once the server says
/// the rename / room exists, and only for a change I asked for (the partner's
/// rename broadcasts the same frame). In memory only: a restart before the
/// server answers drops the line, which is acceptable.
///
/// Names are keyed exactly as sent to the server. Each `take*` consumes its
/// entry.
class PendingChannelActions {
  final Map<String, ChannelPictureChoice> _created = {};
  final Set<(String, String)> _renames = {};

  void expectCreated(String name, ChannelPictureChoice choice) {
    _created[name] = choice;
  }

  ChannelPictureChoice? takeCreated(String name) => _created.remove(name);

  void expectRename(String roomId, String name) {
    _renames.add((roomId, name));
  }

  bool takeRename(String roomId, String name) =>
      _renames.remove((roomId, name));
}

final pendingChannelActionsProvider = Provider<PendingChannelActions>(
  (ref) => PendingChannelActions(),
);
