import 'dart:convert';
import 'dart:typed_data';

import '../identity/keypair.dart';
import '../wire/frames.dart';
import 'bip39_invite.dart';
import 'pairing_transport.dart';

/// Spec §8.5.1 domain tag for `ConsumeInvite`. Kept inline (vs. lifting to a
/// shared helper in `identity/`) because (a) only two call sites use this
/// pattern, (b) the brief scopes WT-D out of `identity/`, (c) the construction
/// is 4 lines.
const _inviteConsumeTag = 'littlelove.v0.2.invite-consume';

/// Decode the BIP39 code → canonical 32-byte token → sign §8.5.1 input →
/// send `ConsumeInvite` → return the `InviteConsumed` frame.
Future<InviteConsumedFrame> consumeInvite({
  required PairingTransport transport,
  required DerivedIdentity identity,
  required String code,
}) async {
  final canonical = decodeInviteCode(code); // throws InviteCodeException
  final signingInput = <int>[
    ...utf8.encode(_inviteConsumeTag),
    0x00,
    ...canonical,
  ];
  final sig = await identity.sign(signingInput);
  return transport.consumeInvite(
    code: code,
    signature: Uint8List.fromList(sig),
  );
}
