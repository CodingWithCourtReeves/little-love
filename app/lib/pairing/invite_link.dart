/// The universal-link form of an invite. One token, three forms (link, QR =
/// link, 4-word code); this module defines the link shape shared by QR
/// rendering and incoming deep-link parsing. Domain matches the iOS
/// `applinks:` entitlement and the Axum AASA `/pair/*` pattern.
const String pairLinkHost = 'littlelove.dev';

/// Build the shareable universal link for a 4-word invite [code].
String pairLink(String code) => 'https://$pairLinkHost/pair/$code';

/// Extract the 4-word code from an incoming `/pair/<code>` URI, or null if the
/// URI is not a pair link. Does not validate the code is a real BIP39 code —
/// the consume path does that.
String? extractPairCode(Uri uri) {
  final segs = uri.pathSegments;
  if (segs.length == 2 && segs[0] == 'pair' && segs[1].isNotEmpty) {
    return segs[1];
  }
  return null;
}
