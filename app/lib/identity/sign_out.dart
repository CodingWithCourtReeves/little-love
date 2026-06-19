import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inbox/active_room_provider.dart';
import '../inbox/inbox_state.dart';
import '../inbox/read_state_provider.dart';
import '../outbox/outbox_store.dart';
import 'providers.dart';

/// Sign the current account out of this device: wipe the local identity and all
/// per-account local data, then reset the session so [AuthGate] returns to the
/// signup/sign-in choice screen.
///
/// This is destructive and irreversible without the recovery phrase. It removes
/// the master seed from the keychain, the local account record, the read-state
/// file, and the outbox queue, then invalidates [accountProvider] — which
/// cascades to tear down the live socket and identity (both watch it).
Future<void> signOut(WidgetRef ref) async {
  final username = ref.read(accountProvider).valueOrNull?.username;

  // Best-effort outbox wipe so a new account never re-sends the old user's
  // queued messages. Capture the store future while `ref` is still valid, but
  // don't block sign-out on it (and don't touch `ref` in the callback — the
  // accountProvider invalidation below disposes this widget).
  final outboxFuture = ref.read(outboxStoreProvider.future);
  unawaited(outboxFuture.then((s) => s.clear()).catchError((_) {}));

  // 1. Persisted identity + per-account data.
  if (username != null) {
    await ref.read(keystoreProvider).delete('llove.master.$username');
  }
  await ref.read(accountLocalStoreProvider).delete();
  await ref.read(readStateStoreProvider).clear();

  // 2. In-memory session state that doesn't watch accountProvider.
  ref.invalidate(inboxStateProvider);
  ref.invalidate(inboxSyncedProvider);
  ref.invalidate(readStateProvider);
  ref.invalidate(activeRoomProvider);
  ref.invalidate(requestedRoomProvider);

  // 3. Drop back to the choice screen; this also disposes the live socket and
  // identity, which both watch accountProvider.
  ref.invalidate(accountProvider);
}
