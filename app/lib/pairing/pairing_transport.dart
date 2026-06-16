import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/live_pairing_transport.dart';

abstract class PairingTransport {
  Future<InviteCreatedFrame> createInvite();
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  });
}

class PairingTransportException implements Exception {
  const PairingTransportException({required this.code, required this.message});
  final String code;
  final String message;
  @override
  String toString() => 'PairingTransportException($code): $message';
}

/// Built on top of `liveConnectionProvider`. Throws if the connection is
/// still loading or errored — callers should `.when(...)` on the connection
/// future before reading this provider.
final pairingTransportProvider = Provider<PairingTransport>((ref) {
  final conn = ref.watch(liveConnectionProvider).requireValue;
  final transport = LivePairingTransport(conn);
  ref.onDispose(transport.dispose);
  return transport;
});
