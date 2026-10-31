import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/square_image.dart';
import '../conversation/message_content.dart';
import '../conversation/message_store.dart';
import '../conversation/room_key_cache.dart';
import '../conversation/send_fanout.dart';
import '../diagnostics/crash_reporting.dart';
import '../identity/current_identity.dart';
import '../inbox/room.dart';
import '../outbox/outbox_drain.dart';
import '../outbox/outbox_store.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'channel_picture.dart';

/// Uploads a squared JPEG to [roomId] and returns its descriptor. Injectable
/// so tests need not touch the network.
typedef SquareUploader =
    Future<AttachmentDescriptor> Function({
      required LiveConnection conn,
      required String roomId,
      required Uint8List jpeg,
      required String filename,
    });

/// Outcome of [ChannelUpdateSender.applyChoice].
enum ChannelUpdateResult {
  /// Enqueued.
  sent,

  /// A photo needs a connection to upload and there was none. Expected, so
  /// not reported as a fault; the caller can tell the user to retry.
  offline,

  /// Nothing was enqueued; the fault has already been reported.
  failed,
}

/// Sends channel picture / name changes as ordinary E2EE messages through the
/// persistent outbox, with an optimistic row. No send chime.
class ChannelUpdateSender {
  ChannelUpdateSender(this._ref, [this._upload = uploadSquareImage]);

  final Ref _ref;
  final SquareUploader _upload;

  /// Apply a picture [choice]. Anything but [ChannelUpdateResult.sent] means
  /// nothing was enqueued.
  Future<ChannelUpdateResult> applyChoice({
    required Room room,
    required String selfUsername,
    required ChannelPictureChoice choice,
  }) async {
    final ChannelPicture picture;
    switch (choice) {
      case ChoosePhoto(:final squaredJpeg):
        // A photo can't be uploaded without a connection and the outbox can't
        // retry an upload later. That is expected, not a fault.
        final conn = _ref.read(liveConnectionProvider).asData?.value;
        if (conn == null) return ChannelUpdateResult.offline;
        try {
          final descriptor = await _upload(
            conn: conn,
            roomId: room.roomId,
            jpeg: squaredJpeg,
            filename: 'channel.jpg',
          );
          picture = PhotoPicture(descriptor);
        } catch (e, st) {
          reportFault(e, st, context: 'channel_picture_upload');
          return ChannelUpdateResult.failed;
        }
      case ChooseSymbol(:final symbol, :final color):
        picture = SymbolPicture(symbol, color);
      case ChooseNone():
        picture = const NoPicture();
    }
    final ok = await _send(
      room,
      selfUsername,
      ChannelUpdateContent(picture: picture),
    );
    return ok ? ChannelUpdateResult.sent : ChannelUpdateResult.failed;
  }

  /// Send a name-only channel line for a rename.
  Future<bool> sendRenameLine({
    required Room room,
    required String selfUsername,
    required String name,
  }) => _send(room, selfUsername, ChannelUpdateContent(name: name));

  Future<bool> _send(
    Room room,
    String selfUsername,
    ChannelUpdateContent content,
  ) async {
    final clientMsgId = _ref.read(outboxIdGenProvider)();
    final msgs = _ref.read(messageStoreProvider(room.roomId).notifier);
    msgs.add(
      Msg(
        id: clientMsgId,
        from: selfUsername,
        to: room.roomId,
        body: '',
        ts: DateTime.now().toUtc(),
        clientMsgId: clientMsgId,
        sendStatus: SendStatus.sending,
        channelUpdate: content,
      ),
    );
    try {
      final me = await _ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: selfUsername,
        plaintext: content.encode(),
        cache: _ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await _ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
    } catch (e, st) {
      msgs.remove(clientMsgId);
      reportFault(e, st, context: 'channel_update_send');
      return false;
    }
    try {
      await _ref.read(outboxDrainProvider).kick();
    } catch (_) {
      msgs.updateStatus(clientMsgId, SendStatus.failed);
    }
    return true;
  }
}

final channelUpdateSenderProvider = Provider<ChannelUpdateSender>(
  ChannelUpdateSender.new,
);
