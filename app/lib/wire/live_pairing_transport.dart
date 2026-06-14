import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../pairing/pairing_transport.dart';
import 'frames.dart';
import 'live_connection.dart';

/// Multiplexed `PairingTransport` over a `LiveConnection`.
///
/// In v0.3 the "Invite them with a code" path is no longer a standalone
/// `CreateInvite` frame; instead `createInvite()` issues `CreateRoom
/// { invite_human_partner: true }` and waits for the matching `RoomCreated`
/// (which carries an inline `pending_invite`). The transport adapts the
/// resulting `pending_invite` back into the `InviteCreatedFrame` shape its
/// callers already understand — keeping `show_invite.dart` working until
/// the v0.3 `CreateChatInviteScreen` replaces it (plan Task 11).
///
/// FIFO queue per kind: the next matching frame resolves the head of the
/// queue. A `RoomError` resolves the oldest pending call (createInvite
/// first, then consumeInvite).
class LivePairingTransport implements PairingTransport {
  LivePairingTransport(this._conn) {
    _sub = _conn.incoming.listen(_onFrame);
  }

  final LiveConnection _conn;
  late final StreamSubscription<RoomServerFrame> _sub;

  final _pendingCreate = <Completer<InviteCreatedFrame>>[];
  final _pendingConsume = <Completer<InviteConsumedFrame>>[];

  @override
  Future<InviteCreatedFrame> createInvite() {
    final c = Completer<InviteCreatedFrame>();
    _pendingCreate.add(c);
    _conn.send(
      const CreateRoomFrame(
        botAccountIds: [],
        inviteHumanPartner: true,
      ).toJson(),
    );
    return c.future;
  }

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) {
    final c = Completer<InviteConsumedFrame>();
    _pendingConsume.add(c);
    _conn.send(
      ConsumeInviteFrame(
        code: code,
        signatureBase64: base64.encode(signature),
      ).toJson(),
    );
    return c.future;
  }

  void _onFrame(RoomServerFrame frame) {
    switch (frame) {
      case RoomCreatedFrame(:final pendingInvite):
        if (pendingInvite == null) break;
        if (_pendingCreate.isNotEmpty) {
          _pendingCreate
              .removeAt(0)
              .complete(
                InviteCreatedFrame(
                  code: pendingInvite.code,
                  qrPngBase64: pendingInvite.qrPngBase64,
                  expiresAt: pendingInvite.expiresAt,
                ),
              );
        }
      case InviteCreatedFrame():
        // Server no longer emits standalone InviteCreated — the inline
        // pending_invite on RoomCreated supersedes it. If a future server
        // build sends one, fall through and resolve any pending caller.
        if (_pendingCreate.isNotEmpty) {
          _pendingCreate.removeAt(0).complete(frame);
        }
      case InviteConsumedFrame():
        if (_pendingConsume.isNotEmpty) {
          _pendingConsume.removeAt(0).complete(frame);
        }
      case RoomErrorFrame():
        final err = PairingTransportException(
          code: frame.code,
          message: frame.message,
        );
        if (_pendingCreate.isNotEmpty) {
          _pendingCreate.removeAt(0).completeError(err);
        } else if (_pendingConsume.isNotEmpty) {
          _pendingConsume.removeAt(0).completeError(err);
        }
      case RoomsFrame() ||
          RoomRenamedFrame() ||
          MemberLeftFrame() ||
          MessageFrame():
        break;
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
  }
}
