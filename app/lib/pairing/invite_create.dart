import '../wire/frames.dart';
import 'pairing_transport.dart';

/// Drive the `CreateInvite` request through the transport. Returns the raw
/// frame so callers render whichever fields they need (code / QR / expiry).
Future<InviteCreatedFrame> createInvite(PairingTransport transport) =>
    transport.createInvite();
