import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_link.dart';

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

/// Subscribes to `app_links` for the lifetime of the signed-in session: the
/// cold-start initial link and every warm link while running. Activated by
/// HomeScreen via `ref.watch`. Tolerant of platform errors (e.g. tests /
/// unsupported platforms) — it simply never fires there.
final deepLinkBootstrapProvider = Provider<void>((ref) {
  void setCode(String code) =>
      ref.read(pendingPairCodeProvider.notifier).state = code;

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
