import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_link.dart';

/// Native channel (shared with push) used here only to pull a universal link
/// that cold-launched the app — app_links misses those under this app's
/// implicit-engine AppDelegate. See `ios/Runner/AppDelegate.swift`.
const _nativeChannel = MethodChannel('little_love/push');

/// One-shot "a pair link arrived" command. [PairingScreen] listens, prefills
/// the enter-code field, consumes, and resets this to null. Mirrors
/// `requestedRoomProvider`: a value here is a command, not retained state.
final pendingPairCodeProvider = StateProvider<String?>((ref) => null);

/// Pure handler: if [uri] is a `/pair/<code>` link, hand the code to [onCode].
/// Decoupled from Riverpod (takes a setter, not a ref/container) so it's
/// trivially unit-testable and reusable from the platform stream below.
void handlePairUri(Uri uri, void Function(String code) onCode) {
  final code = extractPairCode(uri);
  if (code != null) onCode(code);
}

/// Subscribes to `app_links` for the whole app lifetime (activated by
/// `AuthGate` via `ref.watch`, so it runs even while signed out): the
/// cold-start initial link and every warm link while running. Tolerant of
/// platform errors (e.g. tests / unsupported platforms) — it simply never
/// fires there.
final deepLinkBootstrapProvider = Provider<void>((ref) {
  void setCode(String code) =>
      ref.read(pendingPairCodeProvider.notifier).state = code;

  // Cold start: pull the launch link buffered natively (app_links misses it
  // under the implicit-engine AppDelegate — see AppDelegate.swift).
  unawaited(
    _nativeChannel
        .invokeMethod<String>('takePendingLaunchLink')
        .then((link) {
          if (link != null) handlePairUri(Uri.parse(link), setCode);
        })
        .catchError((_) {}),
  );

  // Warm links (app already running) flow through app_links.
  final appLinks = AppLinks();
  unawaited(
    appLinks
        .getInitialLink()
        .then((uri) {
          if (uri != null) handlePairUri(uri, setCode);
        })
        .catchError((_) {}),
  );
  final sub = appLinks.uriLinkStream.listen(
    (uri) => handlePairUri(uri, setCode),
    onError: (_) {},
  );
  ref.onDispose(sub.cancel);
});
