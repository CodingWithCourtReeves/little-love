import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'playback_controller.dart';

/// App-wide single voice-memo player. Shared by the conversation bubbles and
/// the chat-info Voice tab so only one memo plays at a time.
final voicePlaybackControllerProvider = Provider<VoicePlaybackController>((
  ref,
) {
  final c = VoicePlaybackController();
  ref.onDispose(c.dispose);
  return c;
});
