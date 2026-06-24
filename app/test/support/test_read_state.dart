import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/read_state_store.dart';

/// An empty temp-dir read-state store override. ConversationPage watches
/// unread-elsewhere (for the back-button badge), which hydrates the read-state
/// store; widget tests use this so they stay hermetic instead of reading the
/// dev machine's real `~/.littlelove/read_state.json`.
Override hermeticReadStateStore() => readStateStoreProvider.overrideWithValue(
  ReadStateStore(homeDirectory: Directory.systemTemp.createTempSync('rs_test')),
);
