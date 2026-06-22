/// The universal-link form of an invite. One token, three forms (link, QR =
/// link, 4-word code).
///
/// The link's host is the **backend the app is built against** (`LLOVE_SERVER`,
/// the same value `serverBaseProvider` uses): prod builds emit
/// `https://littlelove.dev/pair/CODE`, on-device dev builds (`ios-deploy.sh
/// --server NGROK`) emit the ngrok tunnel host. So a code minted on a dev build
/// pairs against the dev server and a prod code against prod. The AASA is
/// host-independent and served by that same backend (see `well_known.rs`), and
/// the iOS entitlement lists both hosts, so iOS routes either into the app.
const _serverEnv = String.fromEnvironment(
  'LLOVE_SERVER',
  defaultValue: 'https://littlelove.dev',
);

/// Build the shareable universal link for a 4-word invite [code], rooted at the
/// configured backend host.
String pairLink(String code) =>
    Uri.parse(_serverEnv).replace(path: '/pair/$code').toString();

/// Extract the 4-word code from an incoming `/pair/CODE` URI, or null if the
/// URI is not a pair link. Host-agnostic — accepts both the prod domain and the
/// dev ngrok host. Does not validate the code is a real BIP39 code — the
/// consume path does that.
String? extractPairCode(Uri uri) {
  final segs = uri.pathSegments;
  if (segs.length == 2 && segs[0] == 'pair' && segs[1].isNotEmpty) {
    return segs[1];
  }
  return null;
}
