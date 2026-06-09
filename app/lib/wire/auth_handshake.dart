import 'dart:async';
import 'dart:convert';

import '../identity/keypair.dart';
import 'frames.dart';

sealed class AuthHandshakeResult {
  const AuthHandshakeResult();
}

class AuthHandshakeSuccess extends AuthHandshakeResult {
  const AuthHandshakeSuccess();
}

class AuthHandshakeFailure extends AuthHandshakeResult {
  const AuthHandshakeFailure({required this.code, this.message = ''});
  final String code;
  final String message;
}

/// Drive the Challenge → Identify → Authenticated handshake against an
/// already-open WSS stream/sink. Does not own the socket lifecycle.
///
/// [simulateAuthenticatedAfterIdentify] is for tests: it lets a unit test
/// emit the next server frame after the Identify is written. Production
/// callers should leave it null.
Future<AuthHandshakeResult> performAuthHandshake({
  required Stream<dynamic> stream,
  required StreamSink<dynamic> sink,
  required String username,
  required DerivedIdentity identity,
  Duration timeout = const Duration(seconds: 10),
  void Function()? simulateAuthenticatedAfterIdentify,
}) async {
  final completer = Completer<AuthHandshakeResult>();
  late StreamSubscription<dynamic> sub;
  Timer? timer;

  void finish(AuthHandshakeResult r) {
    if (completer.isCompleted) return;
    timer?.cancel();
    sub.cancel();
    completer.complete(r);
  }

  timer = Timer(timeout, () {
    finish(
      const AuthHandshakeFailure(
        code: 'Timeout',
        message: 'server did not respond in time',
      ),
    );
  });

  var sentIdentify = false;

  sub = stream.listen(
    (raw) async {
      if (raw is! String) return;
      final Map<String, Object?> json;
      try {
        json = jsonDecode(raw) as Map<String, Object?>;
      } catch (_) {
        return;
      }
      final ServerFrame frame;
      try {
        frame = ServerFrame.fromJson(json);
      } on FormatException {
        return;
      }
      switch (frame) {
        case ChallengeFrame():
          final nonce = base64.decode(frame.nonceBase64);
          final sig = await identity.sign(nonce);
          final ident = IdentifyFrame(
            username: username,
            signatureBase64: base64.encode(sig),
          );
          sink.add(jsonEncode(ident.toJson()));
          sentIdentify = true;
          simulateAuthenticatedAfterIdentify?.call();
        case AuthenticatedFrame():
          if (sentIdentify) finish(const AuthHandshakeSuccess());
        case ErrorFrame():
          finish(
            AuthHandshakeFailure(code: frame.code, message: frame.message),
          );
      }
    },
    onError: (Object e, StackTrace _) =>
        finish(AuthHandshakeFailure(code: 'StreamError', message: '$e')),
    onDone: () => finish(
      const AuthHandshakeFailure(
        code: 'StreamClosed',
        message: 'server closed the connection',
      ),
    ),
  );

  return completer.future;
}
