import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the partner is currently typing in a room (transient presence; never
/// persisted). Driven by inbound `Typing` frames from the router. A safety
/// timeout auto-clears the indicator if the `typing:false` frame is lost, so a
/// dropped stop can't leave "typing…" stuck on screen.
class TypingNotifier extends FamilyNotifier<bool, String> {
  Timer? _expire;

  /// Slightly longer than the sender's stop debounce (~4s) so a normal pause
  /// between keystrokes refreshes the indicator before it expires.
  static const _timeout = Duration(seconds: 6);

  @override
  bool build(String roomId) {
    ref.onDispose(() => _expire?.cancel());
    return false;
  }

  void setTyping(bool typing) {
    _expire?.cancel();
    if (typing) {
      state = true;
      _expire = Timer(_timeout, () => state = false);
    } else {
      state = false;
    }
  }
}

final typingProvider = NotifierProvider.family<TypingNotifier, bool, String>(
  TypingNotifier.new,
);
