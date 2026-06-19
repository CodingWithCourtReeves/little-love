import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The roomId of the conversation currently on screen (a pushed
/// [ConversationPage]), or null when no chat is open.
///
/// This is the read-receipt "the chat is on screen" signal. It replaces
/// `InboxState.selectedRoomId`: a route mounts the conversation (set here) and
/// pops it (cleared here), so glancing at the home list — where no
/// ConversationPage is mounted — correctly reads as "no room open" and never
/// over-reports a read.
final activeRoomProvider = StateProvider<String?>((ref) => null);

/// A one-shot "please open this room" command, set by out-of-tree callers that
/// can't push a route themselves — notably a push-notification tap
/// ([pushBootstrapProvider]). [HomeScreen] listens, pushes the matching
/// [ConversationPage], and resets this to null so the command isn't re-fired on
/// the next rebuild. Replaces the old `selectAndMarkRead` deep-link path:
/// navigation, not selection, is how a room opens now.
final requestedRoomProvider = StateProvider<String?>((ref) => null);
