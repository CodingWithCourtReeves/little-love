import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../pairing/pairing_transport.dart';
import 'frames.dart';
import 'live_connection.dart';

/// Multiplexed `PairingTransport` over a `LiveConnection`. FIFO queue per
/// frame kind: the next `InviteCreated` resolves the head of the createInvite
/// queue; the next `InviteConsumed` resolves the head of the consumeInvite
/// queue. A `RoomError` resolves the oldest pending call (createInvite first
/// then consumeInvite) — the server only emits one Error per unanswered
/// request and replies arrive in order on the single socket.
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
      case RoomsFrame() || RoomCreatedFrame() || MessageFrame():
        break;
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
  }
}
