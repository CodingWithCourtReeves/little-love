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
