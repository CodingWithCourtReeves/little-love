# Navigation Refactor (Part A of Pairing+Nav Redesign) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the responsive drawer/shell signed-in chrome with an iOS-native list-as-home + push-to-chat model, and migrate the read-receipt "chat is on screen" signal from the persistent `selectedRoomId` to a route-lifecycle `activeRoomProvider`.

**Architecture:** Home becomes the conversation list (`HomeScreen`, replacing `InboxShell`). Tapping a room pushes a `ConversationPage` route; back pops to Home. "The chat is on screen" becomes a widget lifecycle event: `ConversationPage` sets `activeRoomProvider` on mount and clears it on dispose. The inbound mark-read gate keys off `activeRoomProvider` instead of `selectedRoomId`. All `<600px`-only desktop chrome (`LayoutScaffold`, `Sidebar`, `NavigationRail`, `Drawer`, `ChannelSwitcher`) is deleted.

**Tech Stack:** Flutter, Riverpod (`Notifier`/`StateProvider`), raw `Navigator.push`/`pop` (no router package). Tests: `flutter_test` widget + `ProviderContainer` unit tests.

**Scope note:** This is **Part A** of the combined branch. It lands the navigation structure. **Part B** (pairing redesign #26: roomless invites, single symmetric screen, universal links) gets its own plan written after Part A lands, when `HomeScreen`'s interface is concrete. Part A's empty/pairing state reuses the *existing* `PairCard` as an interim surface; Part B replaces it.

## Global Constraints

- **Platform:** iOS-only MVP. Remove breakpoint machinery, do not rework it for tablet/desktop.
- **No protocol changes:** no change to wire frames, encryption, message store, or the read-receipt *protocol* (`MarkRead`/`Read` frames, double-heart rendering). Only *when* the client decides a chat is on screen changes.
- **Read-receipt honesty:** inbound mark-read fires only when the chat is genuinely on screen (`activeRoomProvider == roomId`), never while merely glancing at the list.
- **TDD throughout; frequent commits; small focused files.**
- **Run the full CI lint locally before any push:** `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test` (all from `app/`). Per-file checks miss CI failures.
- All `app/` paths below are relative to `/Users/courtreeves/projects/little-love/.claude/worktrees/pairing-nav-redesign/app`.

---

## File Structure

**Created:**
- `app/lib/inbox/active_room_provider.dart` — `activeRoomProvider`, the route-lifecycle "chat on screen" signal.
- `app/lib/screens/inbox/home_screen.dart` — signed-in root: conversation list + empty/pairing state + router/drain activation + send/retry/media wiring + tap-to-push + single-room auto-open.
- `app/lib/screens/inbox/pair_card.dart` — `PairCard` + `_PairOption` extracted out of `inbox_shell.dart` so it survives that file's deletion (interim pre-pairing surface; Part B replaces it).
- `app/test/inbox/active_room_provider_test.dart`
- `app/test/screens/inbox/home_screen_test.dart`

**Modified:**
- `app/lib/inbox/select_room.dart` — add `markRoomRead`; later remove `selectAndMarkRead`.
- `app/lib/conversation/room_message_router.dart` — gate inbound mark-read on `activeRoomProvider`; drop `RoomCreated` auto-select.
- `app/lib/conversation/conversation_page.dart` — pushed route: back AppBar + room-name title; set/clear `activeRoomProvider` + `markRoomRead` on mount; remove `ChannelSwitcher` + `onNewChannel`.
- `app/lib/inbox/inbox_state.dart` — remove `selectedRoomId`/`select`/`deselect`; simplify `setRooms`/`removeMember`.
- `app/lib/screens/auth/auth_gate.dart` — `InboxShell` → `HomeScreen`.
- `app/lib/screens/inbox/new_chat_screen.dart` — import `PairCard` from its new file.
- `app/test/conversation/room_message_router_test.dart` — port the three selection-based tests to `activeRoomProvider`.

**Deleted:**
- `app/lib/screens/inbox/inbox_shell.dart`
- `app/lib/inbox/layout_scaffold.dart`
- `app/lib/inbox/sidebar.dart`
- `app/lib/inbox/navigation_rail.dart`
- `app/lib/inbox/drawer.dart`
- `app/lib/inbox/channel_switcher.dart`
- Their dead tests (enumerated in Task 3 / Task 4).

---

## Task 1: `activeRoomProvider` + `markRoomRead` + ConversationPage lifecycle

Add the route-lifecycle signal and a `select()`-free mark-read helper, and wire `ConversationPage` to set the signal on mount and clear it on dispose. Purely additive — nothing is removed yet, so the tree still compiles with the old shell.

**Files:**
- Create: `app/lib/inbox/active_room_provider.dart`
- Create: `app/test/inbox/active_room_provider_test.dart`
- Modify: `app/lib/inbox/select_room.dart` (add `markRoomRead`)
- Modify: `app/lib/conversation/conversation_page.dart` (`initState`/`dispose`)

**Interfaces:**
- Produces: `activeRoomProvider` — `StateProvider<String?>` holding the roomId currently on screen, or `null`.
- Produces: `void markRoomRead(dynamic reader, String roomId)` — marks the room read locally (`readStateProvider`) and sends a `MarkRead` frame (`sendMarkRead`). No `select()`.

- [ ] **Step 1: Write the failing test for the provider + lifecycle**

Create `app/test/inbox/active_room_provider_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Room _room(String id) => Room(
  roomId: id,
  name: 'Test',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  testWidgets('ConversationPage sets activeRoom on mount, clears on dispose', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(activeRoomProvider), isNull);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ConversationPage(
            room: _room('room1'),
            selfUsername: 'court',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(); // let the post-frame callback run

    expect(container.read(activeRoomProvider), 'room1');

    // Replace the page so ConversationPage disposes.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold()),
      ),
    );
    await tester.pump();

    expect(container.read(activeRoomProvider), isNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/inbox/active_room_provider_test.dart`
Expected: FAIL — `active_room_provider.dart` doesn't exist (import error / `activeRoomProvider` undefined).

- [ ] **Step 3: Create the provider**

Create `app/lib/inbox/active_room_provider.dart`:

```dart
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
```

- [ ] **Step 4: Add `markRoomRead` to `select_room.dart`**

In `app/lib/inbox/select_room.dart`, add this function above `sendMarkRead` (leave `selectAndMarkRead` and `sendMarkRead` untouched for now — they're removed in Task 4):

```dart
/// Mark [roomId] read locally and tell the server, without changing any
/// selection. Called from [ConversationPage] on mount: opening a chat clears
/// its unread badge and flips the partner's bubbles to a double heart.
/// Accepts any Riverpod reader ([WidgetRef], [Ref], or [ProviderContainer]).
void markRoomRead(dynamic reader, String roomId) {
  reader.read(readStateProvider.notifier).markRead(roomId);
  sendMarkRead(reader, roomId);
}
```

- [ ] **Step 5: Wire `ConversationPage` lifecycle**

In `app/lib/conversation/conversation_page.dart`:

Add the imports near the existing `import '../inbox/channel_switcher.dart';` line:

```dart
import '../inbox/active_room_provider.dart';
import '../inbox/select_room.dart';
```

Replace the existing `initState` (currently lines 185-191):

```dart
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }
```

with:

```dart
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
      // This chat is now on screen: it owns the read-receipt signal, and
      // opening it marks everything read. Done post-frame to avoid mutating a
      // provider during the first build.
      if (!mounted) return;
      ref.read(activeRoomProvider.notifier).state = widget.roomId;
      markRoomRead(ref, widget.roomId);
    });
  }
```

In `dispose` (currently lines 239-251), add the clear as the first line of the method body (before `_dismissReactionBar()`):

```dart
  @override
  void dispose() {
    // Leaving the chat: drop the read-receipt signal, but only if it still
    // points at us — a faster push of another room may have already claimed it.
    if (ref.read(activeRoomProvider) == widget.roomId) {
      ref.read(activeRoomProvider.notifier).state = null;
    }
    _dismissReactionBar();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _typingStop?.cancel();
    _typingHeartbeat?.cancel();
    // Leaving the room while composing: tell the partner we stopped.
    if (_typingActive) widget.onTyping?.call(false);
    super.dispose();
  }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd app && flutter test test/inbox/active_room_provider_test.dart`
Expected: PASS.

- [ ] **Step 7: Run format + analyze + full suite**

Run: `cd app && dart format . && flutter analyze && flutter test`
Expected: format clean, analyze 0 issues, all tests pass (the old shell still uses `selectedRoomId`; nothing removed yet).

- [ ] **Step 8: Commit**

```bash
git add app/lib/inbox/active_room_provider.dart app/lib/inbox/select_room.dart app/lib/conversation/conversation_page.dart app/test/inbox/active_room_provider_test.dart
git commit -m "feat(nav): add activeRoomProvider + markRoomRead; wire ConversationPage lifecycle

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Migrate router inbound mark-read to `activeRoomProvider`; drop RoomCreated auto-select

The router currently marks an inbound live message read when `inboxStateProvider.selectedRoomId == f.roomId` (`room_message_router.dart:219`) and auto-selects a room on `RoomCreated` (`:65`). Switch the gate to `activeRoomProvider` and remove the auto-select (navigation is `HomeScreen`'s job after Task 3).

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`
- Modify: `app/test/conversation/room_message_router_test.dart`

**Interfaces:**
- Consumes: `activeRoomProvider` (Task 1).

- [ ] **Step 1: Port the three selection-based router tests to `activeRoomProvider`**

In `app/test/conversation/room_message_router_test.dart`:

Add the import after the existing `package:littlelove/inbox/inbox_state.dart` import:

```dart
import 'package:littlelove/inbox/active_room_provider.dart';
```

In the test **'live partner message into the selected room sends a MarkRead'**, replace the line `container.read(inboxStateProvider.notifier).select('room1');` with:

```dart
      container.read(activeRoomProvider.notifier).state = 'room1';
```

In the test **'live partner message into a non-selected room sends no MarkRead'**, the comment `// No room selected.` already reflects `activeRoomProvider` defaulting to `null`; no `select` call exists there — leave it (it now exercises the new gate). 

In the test **'a replayed partner message sends no MarkRead'**, replace `container.read(inboxStateProvider.notifier).select('room1');` with:

```dart
      container.read(activeRoomProvider.notifier).state = 'room1';
```

- [ ] **Step 2: Run the router tests to verify the two `activeRoom`-set tests fail**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: FAIL — 'live partner message into the selected room sends a MarkRead' now expects a MarkRead but the router still reads `selectedRoomId` (which is null since we stopped calling `select`), so no MarkRead is sent.

- [ ] **Step 3: Switch the router gate and drop the auto-select**

In `app/lib/conversation/room_message_router.dart`:

Add the import after `import '../inbox/inbox_state.dart';`:

```dart
import '../inbox/active_room_provider.dart';
```

In the `RoomCreatedFrame` case, delete the auto-select call and its comment (currently lines 62-65):

```dart
        // The creator just made this room — drop them into it and mark read.
        // For a pending-invite room this routes to the invite-code screen via
        // inbox_shell; otherwise straight into the conversation.
        selectAndMarkRead(ref, roomId);
```

so the case ends after the `pendingInvite` block:

```dart
      case RoomCreatedFrame(
        :final roomId,
        :final name,
        :final members,
        :final pendingInvite,
      ):
        _upsertRoom(roomId, name, members);
        _subscribe(roomId);
        if (pendingInvite != null) {
          ref.read(pendingInvitesProvider.notifier).set(roomId, pendingInvite);
        }
```

In `_ingestMessage`, change the live-message mark-read gate (currently lines 218-221):

```dart
      if (!f.replayed &&
          ref.read(inboxStateProvider).selectedRoomId == f.roomId) {
        sendMarkRead(ref, f.roomId);
      }
```

to:

```dart
      if (!f.replayed && ref.read(activeRoomProvider) == f.roomId) {
        sendMarkRead(ref, f.roomId);
      }
```

Remove the now-unused `select_room.dart` import **only if** `sendMarkRead` is no longer referenced — it still is (the line above), so **keep** `import '../inbox/select_room.dart';`.

- [ ] **Step 4: Run the router tests to verify they pass**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: PASS — including 'RoomCreated appends, surfaces pendingInvite, and subscribes' (still asserts upsert + pending + subscribe; the dropped `select` wasn't asserted there).

- [ ] **Step 5: Run format + analyze + full suite**

Run: `cd app && dart format . && flutter analyze && flutter test`
Expected: all green. (The old `InboxShell` still auto-selects via its own `defaultHomeRoomId` post-frame path, unaffected.)

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/room_message_router.dart app/test/conversation/room_message_router_test.dart
git commit -m "feat(nav): gate inbound mark-read on activeRoomProvider; drop RoomCreated auto-select

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `HomeScreen` + `ConversationPage`-as-route + AuthGate switch + delete chrome

The structural swap. This is one task because the chrome files (`InboxShell`, `LayoutScaffold`, `Sidebar`, `NavigationRail`, `Drawer`, `ChannelSwitcher`) are mutually entangled through `selectedRoomId` and the single-detail-pane model; `AuthGate` must switch to the new root atomically, so they can't compile half-migrated.

**Files:**
- Create: `app/lib/screens/inbox/pair_card.dart`
- Create: `app/lib/screens/inbox/home_screen.dart`
- Create: `app/test/screens/inbox/home_screen_test.dart`
- Modify: `app/lib/conversation/conversation_page.dart` (AppBar: back + room name; remove `ChannelSwitcher`/`onNewChannel`)
- Modify: `app/lib/screens/auth/auth_gate.dart`
- Modify: `app/lib/screens/inbox/new_chat_screen.dart` (import `PairCard` from its new file)
- Delete: `app/lib/screens/inbox/inbox_shell.dart`, `app/lib/inbox/layout_scaffold.dart`, `app/lib/inbox/sidebar.dart`, `app/lib/inbox/navigation_rail.dart`, `app/lib/inbox/drawer.dart`, `app/lib/inbox/channel_switcher.dart`
- Delete tests: `app/test/inbox/layout_scaffold_test.dart`, `app/test/inbox/drawer_test.dart`, `app/test/inbox/mobile_tap_targets_test.dart`, and any `sidebar`/`navigation_rail`/`channel_switcher` tests (enumerate with the grep in Step 1).

**Interfaces:**
- Consumes: `activeRoomProvider`, `markRoomRead` (Task 1); `inboxStateProvider`, `defaultHomeRoomId` (`inbox_state.dart`); `Room.shape`/`displayName` (`room.dart`); `ConversationListItem`; `PairCard`.
- Produces: `HomeScreen({required LocalAccount account})` — the signed-in root widget.

- [ ] **Step 1: Inventory the chrome tests to delete**

Run: `cd app && grep -rl "LayoutScaffold\|Sidebar\|NavigationRailChrome\|DrawerContent\|ChannelSwitcher\|selectedRoomId\|selectAndMarkRead\|\.select(\|\.deselect(" test/`
Record the matching test files. Any test whose *subject* is a deleted widget (layout_scaffold, sidebar, navigation_rail, drawer, channel_switcher) is deleted in this task. Tests that merely *call* `select()`/`selectedRoomId` to set up other behavior are re-homed onto `HomeScreen` or migrated in Task 4 — note them but don't delete.

- [ ] **Step 2: Extract `PairCard` into its own file**

Create `app/lib/screens/inbox/pair_card.dart` by moving the `PairCard` and `_PairOption` classes verbatim from `inbox_shell.dart` (currently lines 600-735), with their imports:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/account_local.dart';
import '../../theme/twilight.dart';
import '../create_chat/create_chat_pick_screen.dart';
import '../pair/enter_code.dart';
import '../pair/show_invite.dart';

class PairCard extends ConsumerWidget {
  const PairCard({super.key, required this.account});
  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ... body verbatim from inbox_shell.dart lines 605-657 ...
  }

  Future<void> _openEnterCode(BuildContext context, WidgetRef ref) =>
      openEnterCodeScreen(context, ref, account.username);
}

class _PairOption extends StatelessWidget {
  // ... verbatim from inbox_shell.dart lines 663-735 ...
}
```

(Copy the exact class bodies from `inbox_shell.dart`; they reference `Navigator`, `ShowInviteScreen`, `CreateChatPickScreen`, `openEnterCodeScreen`, `TwilightColors`, `TwilightType`.)

- [ ] **Step 3: Update `new_chat_screen.dart`'s import**

In `app/lib/screens/inbox/new_chat_screen.dart`, replace:

```dart
import 'inbox_shell.dart' show PairCard;
```

with:

```dart
import 'pair_card.dart' show PairCard;
```

- [ ] **Step 4: Write the failing `HomeScreen` widget test**

Create `app/test/screens/inbox/home_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/screens/inbox/home_screen.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

LocalAccount _acct() => LocalAccount(
  username: 'court',
  ed25519PubBase64: 'e',
  x25519PubBase64: 'x',
  createdAt: DateTime.utc(2026, 6, 10),
);

Room _partnerRoom(String id) => Room(
  roomId: id,
  name: '',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'e2', x25519PubBase64: 'x2'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

Widget _app(ProviderContainer c, LocalAccount acct) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: HomeScreen(account: acct)),
    );

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      // The router/drain watch the live connection; keep it perpetually
      // pending so HomeScreen mounts without a real socket.
      liveConnectionProvider.overrideWith((_) => Completer<LiveConnection>().future),
      accountProvider.overrideWith((_) async => _acct()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('empty inbox shows the pairing affordance', (tester) async {
    final c = _container();
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    expect(find.text('Invite your partner'), findsOneWidget);
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets('two rooms: list renders, tapping a row pushes ConversationPage, back pops', (
    tester,
  ) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([
      _partnerRoom('room1'),
      Room(
        roomId: 'room2',
        name: 'Travel',
        members: _partnerRoom('room2').members,
        createdAt: DateTime.utc(2026, 6, 11),
      ),
    ]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();

    // List home, no chat pushed yet (2 rooms => no auto-open).
    expect(find.byType(ConversationPage), findsNothing);
    expect(find.text('Travel'), findsOneWidget);

    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);

    // Back pops to the list.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
    expect(find.text('Travel'), findsOneWidget);
  });

  testWidgets('single room auto-opens into the conversation', (tester) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([_partnerRoom('room1')]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);

    // Back lands on Home (the list), not a dead end.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
  });
}
```

Add `import 'dart:async';` at the top of the test for `Completer`.

- [ ] **Step 5: Run the test to verify it fails**

Run: `cd app && flutter test test/screens/inbox/home_screen_test.dart`
Expected: FAIL — `home_screen.dart` doesn't exist.

- [ ] **Step 6: Create `HomeScreen`**

Create `app/lib/screens/inbox/home_screen.dart`. It folds in: the router/drain/push/badge activation from `InboxShell.build` (lines 56-76), the empty-state surface (lines 93-143), the list content from `DrawerContent` (drawer.dart lines 22-99, minus the `Drawer`/`pop` semantics and the "Inviting partner…" pending label — interim: render `displayName`), tap-to-push, single-room auto-open, the `[+]` new-chat entry, and the send/retry/media wiring (`_sendEncrypted`, `_sendAttachment`, `_pickMedia`, `_sendStaged`, `_mimeFor`, `_openAttachment`, `_sendReaction`, `_sendDelete`, `_cancelSend`, `_sendTyping`, `_retry` — moved verbatim from `inbox_shell.dart` lines 213-597).

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../conversation/conversation_page.dart';
import '../../conversation/room_message_router.dart';
import '../../identity/account_local.dart';
import '../../inbox/conversation_list_item.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/room.dart';
import '../../outbox/outbox_drain.dart';
import '../../push/push_bootstrap.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';
import '../create_chat/create_channel_sheet.dart';
import 'new_chat_screen.dart';
import 'pair_card.dart';

/// Signed-in root: the conversation list is home. Tapping a room pushes a
/// [ConversationPage]; back pops here. When there are no rooms, the body is the
/// pairing affordance. Keeps the room message router + outbox drain alive while
/// mounted (was InboxShell's job).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.account});

  final LocalAccount account;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Guards single-room auto-open so it fires at most once per mount.
  bool _autoOpened = false;
  /// True while a ConversationPage route is on top of Home, so the auto-open
  /// listener never double-pushes.
  bool _chatOnStack = false;

  String get _me => widget.account.username;

  @override
  Widget build(BuildContext context) {
    // Activate router + outbox drain for this session (was InboxShell.build).
    ref.watch(liveConnectionProvider).whenData((_) {
      ref.watch(roomMessageRouterProvider);
      ref.watch(outboxDrainProvider);
    });

    final inbox = ref.watch(inboxStateProvider);
    if (inbox.rooms.isNotEmpty) {
      ref.watch(pushBootstrapProvider);
    }
    ref.watch(badgeSyncProvider(_me));

    // Single-room auto-open: exactly one room → push straight into it, so the
    // couples-app "into the chat" feel survives without abandoning the list.
    if (!_autoOpened && !_chatOnStack && inbox.rooms.length == 1) {
      _autoOpened = true;
      final only = inbox.rooms.single;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openRoom(only));
    }

    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        elevation: 0,
        title: Text('@$_me'),
        actions: [
          if (inbox.rooms.isNotEmpty)
            IconButton(
              key: const Key('home-new-chat'),
              icon: const Icon(Icons.add),
              tooltip: 'New chat',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NewChatScreen(account: widget.account),
                ),
              ),
            ),
        ],
      ),
      body: inbox.rooms.isEmpty ? _emptyState() : _roomList(inbox.rooms),
    );
  }

  Widget _emptyState() {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('STEP 4 OF 4 · PAIR', style: TextStyle(
                  fontFamily: 'Inter', fontSize: 11, letterSpacing: 2.4,
                  fontWeight: FontWeight.w500, color: TwilightColors.accentSage,
                )),
                const SizedBox(height: 14),
                const Text('Invite your partner', style: TextStyle(
                  fontFamily: 'Inter', fontSize: 28, fontWeight: FontWeight.w500,
                  height: 1.14, letterSpacing: -0.6,
                  color: TwilightColors.textPrimary,
                )),
                const SizedBox(height: 12),
                const Text(
                  'A pairing handshake exchanges public keys directly between '
                  'your two devices. Until that happens, there is nothing for '
                  'the server to deliver.',
                  style: TwilightType.lede,
                ),
                const SizedBox(height: 28),
                PairCard(account: widget.account),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roomList(List<Room> rooms) {
    List<Room> bucket(RoomShape shape) =>
        rooms.where((r) => r.shape(_me) == shape).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final partners = bucket(RoomShape.partner);
    final chats = bucket(RoomShape.chat);

    Widget header(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: TwilightColors.textMuted, letterSpacing: 1.2,
      )),
    );

    Widget item(Room r) => ConversationListItem(
      key: Key('home-room-${r.roomId}'),
      label: r.displayName(_me),
      selected: false,
      onTap: () => _openRoom(r),
    );

    return ListView(
      children: [
        if (partners.isNotEmpty) header('PARTNER'),
        ...partners.map(item),
        if (chats.isNotEmpty) ...[const SizedBox(height: 16), header('CHATS')],
        ...chats.map(item),
      ],
    );
  }

  Future<void> _openRoom(Room room) async {
    _chatOnStack = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          key: ValueKey(room.roomId),
          room: room,
          selfUsername: _me,
          onSend: (text) => _sendEncrypted(ref, room, text),
          onRetry: (clientMsgId) => _retry(ref, clientMsgId),
          onPickMedia: () => _pickMedia(context),
          onSendMedia: (items, caption) =>
              _sendStaged(ref, room, context, items, caption),
          onReact: (targetId, emoji) => _sendReaction(ref, room, targetId, emoji),
          onDelete: (targetId) => _sendDelete(ref, room, targetId),
          onCancelSend: (clientMsgId) => _cancelSend(ref, room, clientMsgId),
          onTyping: (typing) => _sendTyping(ref, room, typing),
          onOpenAttachment: (descriptor) =>
              _openAttachment(ref, room, context, descriptor),
          onRename: (newName) {
            final conn = ref.read(liveConnectionProvider).asData?.value;
            conn?.send(RenameRoomFrame(roomId: room.roomId, name: newName).toJson());
          },
        ),
      ),
    );
    _chatOnStack = false;
  }

  // ---- send/retry/media wiring moved verbatim from inbox_shell.dart ----
  // _sendEncrypted, _sendAttachment, _pickMedia, _sendStaged, _mimeFor,
  // _openAttachment, _sendReaction, _sendDelete, _cancelSend, _sendTyping,
  // _retry — copy lines 213-597 of inbox_shell.dart, changing each method's
  // `account.username` to `_me` and keeping `WidgetRef ref` params as-is
  // (this State is a ConsumerState, so `ref` is available; the moved methods
  // take `ref` explicitly, which still works).
}
```

When moving the send methods, also copy the imports they need into `home_screen.dart` (from `inbox_shell.dart` lines 1-45): `dart:convert`, `dart:io`, `dart:typed_data`, `file_picker`, `image_picker`, the `attachment/*` imports, `conversation/link_preview.dart`, `conversation/message_content.dart`, `conversation/message_store.dart`, `conversation/room_key_cache.dart`, `conversation/send_fanout.dart`, `outbox/outbox_store.dart`, `wire/message.dart`, `identity/current_identity.dart`. Replace every `account.username` with `_me` and `account` with `widget.account`.

- [ ] **Step 7: Convert `ConversationPage`'s AppBar to back + room name; remove `ChannelSwitcher`/`onNewChannel`**

In `app/lib/conversation/conversation_page.dart`:

Remove the import `import '../inbox/channel_switcher.dart';`.

Remove the `onNewChannel` field (line 108) and its constructor entry (line 93 `this.onNewChannel,`):

Delete:
```dart
  final VoidCallback? onNewChannel;
```
and the `this.onNewChannel,` line in the constructor.

Replace the AppBar `title:` (currently lines 540-544):

```dart
        titleSpacing: 8,
        title: ChannelSwitcher(
          selfUsername: widget.selfUsername,
          onNewChannel: widget.onNewChannel,
        ),
```

with the room name (the back button is automatic — `ConversationPage` is now a pushed route with a parent):

```dart
        title: Text(
          widget.room.displayName(widget.selfUsername),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: TwilightColors.textPrimary,
          ),
        ),
```

(`AppBar` shows the implicit back arrow automatically when the route can pop; no `leading:` needed.)

- [ ] **Step 8: Switch `AuthGate` to `HomeScreen`**

In `app/lib/screens/auth/auth_gate.dart`:

Replace `import '../inbox/inbox_shell.dart';` with `import '../inbox/home_screen.dart';`.

Replace (line 37):

```dart
      data: (acc) => acc == null
          ? const _ChoiceScreen()
          : OutboxRehydrateGate(child: InboxShell(account: acc)),
```

with:

```dart
      data: (acc) => acc == null
          ? const _ChoiceScreen()
          : OutboxRehydrateGate(child: HomeScreen(account: acc)),
```

- [ ] **Step 9: Delete the dead chrme files**

```bash
git rm app/lib/screens/inbox/inbox_shell.dart \
       app/lib/inbox/layout_scaffold.dart \
       app/lib/inbox/sidebar.dart \
       app/lib/inbox/navigation_rail.dart \
       app/lib/inbox/drawer.dart \
       app/lib/inbox/channel_switcher.dart
```

Then delete the chrome-subject tests inventoried in Step 1, e.g.:

```bash
git rm app/test/inbox/layout_scaffold_test.dart \
       app/test/inbox/drawer_test.dart \
       app/test/inbox/mobile_tap_targets_test.dart
# plus any sidebar/navigation_rail/channel_switcher test files the grep found
```

- [ ] **Step 10: Run analyze and fix fallout**

Run: `cd app && flutter analyze`
Expected initially: errors for any remaining references to the deleted files (e.g. a test importing `channel_switcher.dart`, or `switch_conversation_test.dart` using `select()`). Fix by deleting dead tests or re-homing assertions onto `HomeScreen`. Note: `switch_conversation_test.dart`, if selection-based, is handled in Task 4 — if it blocks analysis now, delete it here and re-add equivalent `HomeScreen` coverage in Step 4's test if not already covered.
Iterate until analyze is 0 issues.

- [ ] **Step 11: Run the HomeScreen test + full suite + format**

Run: `cd app && flutter test test/screens/inbox/home_screen_test.dart`
Expected: PASS (empty state, list/tap/back, single-room auto-open).

Run: `cd app && dart format . && flutter analyze && flutter test`
Expected: all green.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "feat(nav): list-as-home + push-to-chat; delete responsive shell chrome

Replace InboxShell/LayoutScaffold/Sidebar/NavigationRail/Drawer/ChannelSwitcher
with HomeScreen (conversation list home) + ConversationPage as a pushed route.
Single-room auto-open preserves the into-the-chat feel. Extract PairCard.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Strip `selectedRoomId`/`select`/`deselect`; simplify `setRooms` and `select_room.dart`

Now that no widget or the router reads `selectedRoomId`, remove it and its methods from `InboxState`, and drop the now-orphaned `selectAndMarkRead` (replaced by `markRoomRead` in Task 1).

**Files:**
- Modify: `app/lib/inbox/inbox_state.dart`
- Modify: `app/lib/inbox/select_room.dart`
- Modify: `app/test/inbox/inbox_state_test.dart` (if present — update for the new shape)
- Delete: `app/test/inbox/switch_conversation_test.dart` (if selection-based and not already deleted in Task 3)

**Interfaces:**
- Produces: `InboxState({required List<Room> rooms})`; `InboxNotifier.setRooms(List<Room>)`, `.renameRoom(...)`, `.removeMember(...)` (no selection methods).

- [ ] **Step 1: Write/adjust the failing `InboxState` test**

In `app/test/inbox/inbox_state_test.dart` (create if absent), assert the simplified shape:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Room _r(String id, {String name = ''}) => Room(
  roomId: id,
  name: name,
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  test('setRooms replaces the room list', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([_r('a'), _r('b')]);
    expect(c.read(inboxStateProvider).rooms.map((r) => r.roomId), ['a', 'b']);
    c.read(inboxStateProvider.notifier).setRooms([_r('a')]);
    expect(c.read(inboxStateProvider).rooms.single.roomId, 'a');
  });

  test('renameRoom updates the name in place', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([_r('a')]);
    c.read(inboxStateProvider.notifier).renameRoom('a', 'Daily');
    expect(c.read(inboxStateProvider).rooms.single.name, 'Daily');
  });
}
```

If the existing test references `selectedRoomId`/`select`/`deselect`, remove those cases.

- [ ] **Step 2: Run it to verify it fails (or fails to compile against the old shape if you changed an existing test)**

Run: `cd app && flutter test test/inbox/inbox_state_test.dart`
Expected: FAIL/compile-error only if you changed an existing assertion; a fresh file will currently pass against the old `InboxState`. Either way, proceed — the real check is analyze after Step 3.

- [ ] **Step 3: Simplify `InboxState`**

Replace the body of `app/lib/inbox/inbox_state.dart` above `inboxStateProvider` with the selection-free version:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'room.dart';

@immutable
class InboxState {
  const InboxState({required this.rooms});

  final List<Room> rooms;

  InboxState copyWith({List<Room>? rooms}) =>
      InboxState(rooms: rooms ?? this.rooms);

  static const InboxState empty = InboxState(rooms: []);
}

class InboxNotifier extends Notifier<InboxState> {
  @override
  InboxState build() => InboxState.empty;

  void setRooms(List<Room> rooms) {
    state = state.copyWith(rooms: List.unmodifiable(rooms));
  }

  /// Rename a room in place, preserving members + createdAt. No-op if the
  /// room isn't in the inbox yet.
  void renameRoom(String roomId, String name) {
    var changed = false;
    final next = <Room>[];
    for (final r in state.rooms) {
      if (r.roomId == roomId) {
        changed = true;
        next.add(Room(
          roomId: r.roomId, name: name, members: r.members,
          createdAt: r.createdAt,
        ));
      } else {
        next.add(r);
      }
    }
    if (!changed) return;
    state = state.copyWith(rooms: List.unmodifiable(next));
  }

  /// Drop `username` from `roomId`. If no members remain, the room is removed.
  void removeMember(String roomId, String username) {
    final updated = <Room>[];
    for (final r in state.rooms) {
      if (r.roomId != roomId) {
        updated.add(r);
        continue;
      }
      final newMembers =
          r.members.where((m) => m.username != username).toList(growable: false);
      if (newMembers.isNotEmpty) {
        updated.add(Room(
          roomId: r.roomId, name: r.name, members: newMembers,
          createdAt: r.createdAt,
        ));
      }
    }
    state = state.copyWith(rooms: List.unmodifiable(updated));
  }
}
```

Keep the `inboxStateProvider` declaration and the `defaultHomeRoomId(...)` helper at the bottom unchanged (the helper still serves single-room auto-open's mental model; `HomeScreen` uses `rooms.length == 1` directly, but other call sites may use it — leave it).

- [ ] **Step 4: Drop `selectAndMarkRead` from `select_room.dart`**

In `app/lib/inbox/select_room.dart`, delete the `selectAndMarkRead` function (it called `inboxStateProvider.notifier.select`, which no longer exists). Keep `markRoomRead` and `sendMarkRead`. Remove the now-unused `import 'inbox_state.dart';` if nothing else in the file references it.

- [ ] **Step 5: Fix analyze fallout**

Run: `cd app && flutter analyze`
Expected: errors at any remaining `selectedRoomId`/`select`/`deselect`/`selectAndMarkRead` references. Resolve each (they should only be in already-deleted files or stale tests). Delete `app/test/inbox/switch_conversation_test.dart` if it's selection-based and still present.
Iterate to 0 issues.

- [ ] **Step 6: Run format + full suite**

Run: `cd app && dart format . && flutter analyze && flutter test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(nav): remove selectedRoomId/select/deselect; active room is route state

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Part A scope of the design doc):**
- iOS-native list-as-home + push-to-chat → Task 3 (`HomeScreen` + `ConversationPage` route).
- `activeRoomProvider` mount/dispose lifecycle → Task 1.
- Router inbound mark-read regated + drop RoomCreated auto-select + port #20's three tests → Task 2.
- Strip `selectedRoomId`/`select`/`deselect`; simplify `setRooms` → Task 4.
- `select_room.dart` → `markRoomRead` (drop `select()`) → Task 1 (add) + Task 4 (remove old).
- `ConversationPage` pushed route: back AppBar + room name, remove `ChannelSwitcher`/`onNewChannel` → Task 3.
- `HomeScreen`: list + empty/pairing state + router/drain + send/retry + tap-to-push → Task 3.
- Single-room auto-open + new-room push → Task 3.
- `AuthGate` → `HomeScreen`; delete chrome + dead tests → Task 3 (+ Task 4 stragglers).
- Read-receipt lifecycle table behavior → exercised by Task 1 + Task 2 tests.

**Deferred to Part B (not gaps):** roomless `CreateInvite`, single symmetric pairing screen, universal links (AASA/entitlement/web fallback/deep-link), removal of `PendingInvitesNotifier` + "Inviting partner…", `show_invite.dart`/`enter_code.dart` collapse. Part A keeps `PairCard` as the interim empty-state surface.

**Type consistency:** `activeRoomProvider` (`StateProvider<String?>`), `markRoomRead(dynamic, String)`, `HomeScreen({required LocalAccount account})`, `InboxState({required List<Room> rooms})` are used consistently across tasks. `ConversationPage` loses `onNewChannel` in Task 3; no task references it afterward.

**Placeholder scan:** Task 3 Step 6 intentionally references "copy lines 213-597 of inbox_shell.dart" for the send/media methods — this is a verbatim move of existing, already-tested code, not a placeholder; the exact source lines and the `account.username`→`_me` transform are specified.
