import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/frames.dart';

/// Port the pairing UI calls into. The integration session provides a real
/// implementation backed by the live WSS connection. Until then, the default
/// Riverpod binding throws on read, and widget tests pass an explicit override.
abstract class PairingTransport {
  Future<InviteCreatedFrame> createInvite();
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  });
}

final pairingTransportProvider = Provider<PairingTransport>(
  (_) => throw UnimplementedError(
    'pairing transport not wired — integration session must override',
  ),
);
