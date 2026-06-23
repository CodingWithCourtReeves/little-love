import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../pairing/pairing_transport.dart';
import 'frames.dart';
import 'live_connection.dart';

/// Multiplexed `PairingTransport` over a `LiveConnection`.
///
/// `createInvite()` issues a roomless `CreateInvite` frame and resolves on the
/// matching `InviteCreated` (the server creates no room until the partner
/// consumes — see spec Part B). `consumeInvite()` issues `ConsumeInvite` and
/// resolves on `InviteConsumed`.
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
    _conn.send(const CreateInviteFrame().toJson());
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
      case InviteCreatedFrame():
        // The server's InviteCreated resolves the pending createInvite().
        if (_pendingCreate.isNotEmpty) {
          _pendingCreate.removeAt(0).complete(frame);
        }
      case InviteConsumedFrame():
        if (_pendingConsume.isNotEmpty) {
          _pendingConsume.removeAt(0).complete(frame);
        }
      case RoomErrorFrame():
        // Errors carry no request correlation id, so we dispatch by fixed queue
        // priority: createInvite first, then consumeInvite. PairingScreen can
        // have both kinds in flight at once (it mints its own invite in
        // initState while the deep-link auto-join consumes the partner's), so
        // this is only correct because the server answers in order on a single
        // connection — InviteCreated drains _pendingCreate before any consume
        // error arrives. If the server ever responds out of order or
        // multiplexes, add a request correlation id; this priority scheme would
        // otherwise mis-route the error onto the wrong pending call.
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
          RoomCreatedFrame() ||
          RoomRenamedFrame() ||
          MemberLeftFrame() ||
          MessageFrame() ||
          ReadFrame() ||
          TypingFrame() ||
          PresenceFrame() ||
          UploadGrantedFrame() ||
          DownloadGrantedFrame() ||
          CallTurnGrantFrame() ||
          CallInviteFrame() ||
          CallAnswerFrame() ||
          CallIceFrame() ||
          CallHangupFrame():
        break;
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
  }
}
