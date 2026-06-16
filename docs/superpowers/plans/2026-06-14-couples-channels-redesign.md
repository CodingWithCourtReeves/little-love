> **HISTORICAL — superseded (annotated 2026-06-16).** This document predates the
> removal of the AI "familiar" / bring-your-own-model feature. LittleLove is now a
> couples-first, channels-based, fully end-to-end-encrypted messenger with **no AI
> and no familiars**. Any mention below of bots, familiars, character cards, LLMs,
> or cloud/local AI describes a **retired** design and does NOT reflect the current
> product. For current framing see `README.md` and `docs/positioning.md`.

# Couples-Channels Redesign (v0.4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reframe the Flutter client around channels — partner DM as home, a header channel switcher for navigation, familiars tinted as in-channel participants, in-app unread indicators, a focused create-channel bottom sheet, and a required-pairing onboarding step — without changing message-bubble rendering or the server schema.

**Architecture:** This is an IA/navigation + unread layer over the *existing* room model. The server already supports everything needed: `CreateRoomFrame {name, botAccountIds, inviteHumanPartner}` and a WS handler that auto-adds the paired partner with no pending invite when `invite_human_partner` is true and the requester is already paired (`server/src/ws.rs:686-743`). No server changes. On the client, rooms↔channels is already modeled (`Room`, `RoomShape`, `displayName`); we add a read-state store + provider for unread, a header switcher widget, partner-as-home default selection, a familiar bubble tint, a create-channel bottom sheet, and an onboarding pairing step.

**Tech Stack:** Flutter (Dart), flutter_riverpod (`Notifier`/`NotifierProvider`/`FamilyNotifier`), Material widgets, Twilight design system (`app/lib/theme/twilight.dart`), file-based JSON persistence (mirrors `AccountLocalStore`), `flutter_test` (unit + widget tests, `ProviderContainer` for provider tests).

---

## Context the engineer needs (read before starting)

- **Working directory is a git worktree:** `/Users/courtreeves/projects/little-love/.claude/worktrees/v0.3-client`. All paths below are relative to it. Run Flutter commands from `app/` (`cd app`).
- **Run a single test:** `cd app && flutter test test/path/to/file_test.dart`
- **Static analysis (must stay clean):** `cd app && flutter analyze`
- **Key existing types:**
  - `Room` (`app/lib/inbox/room.dart`): `{String roomId, String name, List<Member> members, DateTime createdAt}`. Methods: `displayName(self)`, `shape(self) → RoomShape {partner, familiar, chat}`, `memberByUsername`.
  - `Member` (`app/lib/wire/frames.dart:55`): `{int? accountId, String username, String ed25519PubBase64, String x25519PubBase64, bool isBot, String? ownerUsername}`.
  - `InboxState` (`app/lib/inbox/inbox_state.dart`): `{List<Room> rooms, String? selectedRoomId}`; `InboxNotifier` has `setRooms`, `select`, `deselect`, `renameRoom`, `removeMember`. Provider: `inboxStateProvider`.
  - `Msg` (`app/lib/wire/message.dart`): `{String id, from, to, body, DateTime ts, bool replayed}`.
  - `messageStoreProvider` (`app/lib/conversation/message_store.dart`): `NotifierProvider.family<MessageStore, List<Msg>, String>` keyed by roomId.
  - `ConversationPage` (`app/lib/conversation/conversation_page.dart:45`): takes a `Room room`, `String selfUsername`, callbacks `onSend/onRename/onLeave`; builds its own `AppBar` (title at lines 237-?).
  - `RoomMessageRouter` (`app/lib/conversation/room_message_router.dart`): dispatches WS frames; `RoomCreatedFrame` handler at line 49 calls `inboxStateProvider.notifier.select(roomId)`; messages ingested via `_ingestMessage` (line 105).
  - `pendingInvitesProvider` (`app/lib/inbox/pending_invites_provider.dart`): `Map<String, PendingInvite>` keyed by roomId.
  - `ownedBotsProvider` (`app/lib/inbox/owned_bots_provider.dart`): list of owned familiar `Member`s.
  - `LayoutScaffold` (`app/lib/inbox/layout_scaffold.dart`): ≥800 sidebar, ≥600 rail, <600 Drawer+AppBar. The header switcher targets the **<600 mobile** case primarily.
- **Persistence pattern (mirror this):** `AccountLocalStore` (`app/lib/identity/account_local.dart`) writes JSON to `<home>/.littlelove/account.json`, with a mobile-safe `_defaultHome()`. No `shared_preferences` dependency exists; do not add one.
- **Twilight bubble colors today:** `bubbleUserBg`, `bubbleUserText`, `bubblePartnerBg`. Bot bubbles currently reuse `bubblePartnerBg` — Task 1 adds a sage familiar tint.

---

## File Structure

**Create:**
- `app/lib/inbox/read_state_store.dart` — file-based JSON persistence of per-room last-read timestamps (mirrors `AccountLocalStore`).
- `app/lib/inbox/read_state_provider.dart` — `readStateProvider` (Map<roomId, DateTime>) + `markRead`, and `roomUnreadProvider`/`anyUnreadProvider` derived providers.
- `app/lib/inbox/channel_switcher.dart` — the header pill + dropdown overlay widget.
- `app/lib/screens/create_chat/create_channel_sheet.dart` — the create-channel bottom sheet.
- `app/test/inbox/read_state_store_test.dart`
- `app/test/inbox/read_state_provider_test.dart`
- `app/test/inbox/channel_switcher_test.dart`
- `app/test/screens/create_channel_sheet_test.dart`

**Modify:**
- `app/lib/theme/twilight.dart` — add `bubbleFamiliarBg`, `bubbleFamiliarBorder`.
- `app/lib/conversation/conversation_page.dart` — bot bubbles use familiar tint; mount `ChannelSwitcher` in the AppBar title (mobile).
- `app/lib/screens/inbox/inbox_shell.dart` — default-select the partner room as home; pass switcher into the conversation header context.
- `app/lib/conversation/room_message_router.dart` — mark-read on `select`, leave unread for non-selected incoming messages (derived provider handles the rest).
- `app/lib/identity/providers.dart` — add `readStateStoreProvider` (DI for the store), following `accountLocalStoreProvider` shape.

---

## Task 1: Familiar bubble tint

**Files:**
- Modify: `app/lib/theme/twilight.dart`
- Modify: `app/lib/conversation/conversation_page.dart`
- Test: `app/test/theme/twilight_colors_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `app/test/theme/twilight_colors_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/twilight.dart';

void main() {
  test('familiar bubble tint constants exist (sage family)', () {
    expect(TwilightColors.bubbleFamiliarBg, const Color(0xFFEFEDDF));
    expect(TwilightColors.bubbleFamiliarBorder, const Color(0xFFDFDCC4));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/theme/twilight_colors_test.dart`
Expected: FAIL — `bubbleFamiliarBg` / `bubbleFamiliarBorder` not defined on `TwilightColors`.

- [ ] **Step 3: Add the constants**

In `app/lib/theme/twilight.dart`, inside `class TwilightColors`, after `bubblePartnerBg`:

```dart
  /// Sage tint for familiar (bot) message bubbles — distinguishes AI
  /// participants from the partner's white bubbles. Values mirror the v0.4
  /// mock (mocks/v0.4/channel-with-familiar.html).
  static const Color bubbleFamiliarBg = Color(0xFFEFEDDF);
  static const Color bubbleFamiliarBorder = Color(0xFFDFDCC4);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/theme/twilight_colors_test.dart`
Expected: PASS

- [ ] **Step 5: Apply the tint to bot bubbles**

In `app/lib/conversation/conversation_page.dart`, find the bubble builder that chooses a background color for non-self bubbles (the `_bubble` widget / wherever `bubblePartnerBg` is used for incoming bubbles). For a sender that `isBot`, use the familiar tint. Locate the message row builder; where it currently selects the incoming background, change to branch on whether the sender is a bot in `widget.room`:

```dart
// Resolve whether this message's sender is a familiar (bot) in this room.
final senderIsBot = widget.room.memberByUsername(msg.from)?.isBot ?? false;
final bubbleColor = isMine
    ? TwilightColors.bubbleUserBg
    : (senderIsBot
        ? TwilightColors.bubbleFamiliarBg
        : TwilightColors.bubblePartnerBg);
final bubbleBorder = senderIsBot && !isMine
    ? TwilightColors.bubbleFamiliarBorder
    : TwilightColors.borderSoft;
```

Use `bubbleColor` for the bubble's `color`/decoration and `bubbleBorder` for its border. (Match the existing bubble decoration code exactly — only swap the color/border source. `isMine` is the existing variable the builder already uses for left/right alignment; if it has a different name in the file, reuse that name.)

- [ ] **Step 6: Run analyze + existing conversation tests**

Run: `cd app && flutter analyze && flutter test test/conversation/`
Expected: PASS, no analyzer warnings.

- [ ] **Step 7: Commit**

```bash
git add app/lib/theme/twilight.dart app/lib/conversation/conversation_page.dart app/test/theme/twilight_colors_test.dart
git commit -m "feat(theme): sage tint for familiar message bubbles"
```

---

## Task 2: Read-state store (persistence)

A file-based store mapping `roomId → last-read ISO timestamp`, mirroring `AccountLocalStore`. Persists across app restarts; per-device (local), per the spec.

**Files:**
- Create: `app/lib/inbox/read_state_store.dart`
- Test: `app/test/inbox/read_state_store_test.dart`

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/read_state_store_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/read_state_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('readstate_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('round-trips per-room last-read timestamps', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    expect(await store.load(), isEmpty);

    final t = DateTime.utc(2026, 6, 14, 10, 30);
    await store.save({'room-a': t});

    final loaded = await ReadStateStore(homeDirectory: tmp).load();
    expect(loaded['room-a'], t);
  });

  test('load returns empty map when file is absent', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    expect(await store.load(), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/read_state_store_test.dart`
Expected: FAIL — `read_state_store.dart` / `ReadStateStore` does not exist.

- [ ] **Step 3: Write the store**

Create `app/lib/inbox/read_state_store.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-device persistence of the last-read message timestamp per room.
/// Mirrors [AccountLocalStore]'s home-anchored JSON pattern so it works in
/// the iOS/Android sandbox (writes under Documents/) and on desktop (~).
///
/// Read state is intentionally local-only (spec: v0.4 does not sync read
/// markers across a user's devices).
class ReadStateStore {
  ReadStateStore({Directory? homeDirectory})
      : _home = homeDirectory ?? _defaultHome();

  final Directory _home;

  static Directory _defaultHome() {
    if (Platform.isIOS || Platform.isAndroid) {
      return Directory('${Directory.systemTemp.parent.path}/Documents');
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? ''
        : Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      throw StateError('cannot determine home directory');
    }
    return Directory(home);
  }

  File get _file => File(p.join(_home.path, '.littlelove', 'read_state.json'));

  Future<Map<String, DateTime>> load() async {
    final f = _file;
    if (!await f.exists()) return <String, DateTime>{};
    final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    return raw.map(
      (k, v) => MapEntry(k, DateTime.parse(v! as String).toUtc()),
    );
  }

  Future<void> save(Map<String, DateTime> state) async {
    final f = _file;
    await f.parent.create(recursive: true);
    final raw = state.map(
      (k, v) => MapEntry(k, v.toUtc().toIso8601String()),
    );
    await f.writeAsString(jsonEncode(raw));
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/read_state_store_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/lib/inbox/read_state_store.dart app/test/inbox/read_state_store_test.dart
git commit -m "feat(inbox): file-based per-room read-state store"
```

---

## Task 3: Read-state provider + unread computation

A `Notifier` holding `Map<roomId, DateTime>` of last-read markers (hydrated from the store, persisted on change), plus a derived family provider that reports whether a given room is unread by comparing its newest message timestamp against the marker.

**Files:**
- Modify: `app/lib/identity/providers.dart` (add `readStateStoreProvider`)
- Create: `app/lib/inbox/read_state_provider.dart`
- Test: `app/test/inbox/read_state_provider_test.dart`

- [ ] **Step 1: Add the store DI provider**

In `app/lib/identity/providers.dart`, near `accountLocalStoreProvider`, add:

```dart
final readStateStoreProvider = Provider<ReadStateStore>(
  (ref) => ReadStateStore(),
);
```

Add the import at the top of the file:

```dart
import '../inbox/read_state_store.dart';
```

- [ ] **Step 2: Write the failing test**

Create `app/test/inbox/read_state_provider_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/wire/message.dart';

Msg msg(String id, DateTime ts) =>
    Msg(id: id, from: 'kaitlyn', to: 'room-a', body: 'hi', ts: ts);

void main() {
  test('a room with no messages is not unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });

  test('newest message after last-read marks the room unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    // No marker yet → unread.
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });

  test('marking read clears unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    c.read(readStateProvider.notifier).markRead('room-a');
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });

  test('a newer message after marking read re-marks unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final store = c.read(messageStoreProvider('room-a').notifier);
    store.add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    c.read(readStateProvider.notifier).markRead('room-a');
    store.add(msg('m2', DateTime.utc(2026, 6, 14, 13)));
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/read_state_provider_test.dart`
Expected: FAIL — `read_state_provider.dart` does not exist.

- [ ] **Step 4: Write the provider**

Create `app/lib/inbox/read_state_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../identity/providers.dart';

/// In-memory + persisted map of roomId → last-read message timestamp.
/// Hydrated from [ReadStateStore] on first build; every [markRead] writes
/// through to disk so the marker survives app restarts.
class ReadStateNotifier extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() {
    // Hydrate asynchronously; until the file loads we treat everything as
    // unmarked (conservative: shows unread rather than hiding it).
    _hydrate();
    return const {};
  }

  Future<void> _hydrate() async {
    final store = ref.read(readStateStoreProvider);
    final loaded = await store.load();
    if (loaded.isNotEmpty) {
      state = Map.unmodifiable({...loaded, ...state});
    }
  }

  void markRead(String roomId, {DateTime? at}) {
    final ts = (at ?? DateTime.now().toUtc());
    final existing = state[roomId];
    if (existing != null && !ts.isAfter(existing)) return;
    final next = Map<String, DateTime>.from(state)..[roomId] = ts;
    state = Map.unmodifiable(next);
    // Write through; fire-and-forget is fine — the in-memory state is the
    // source of truth for this session.
    ref.read(readStateStoreProvider).save(state);
  }
}

final readStateProvider =
    NotifierProvider<ReadStateNotifier, Map<String, DateTime>>(
  ReadStateNotifier.new,
);

/// True iff [roomId] has a message newer than its last-read marker (or any
/// message at all when there is no marker yet).
final roomUnreadProvider = Provider.family<bool, String>((ref, roomId) {
  final messages = ref.watch(messageStoreProvider(roomId));
  if (messages.isEmpty) return false;
  final newest = messages
      .map((m) => m.ts)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final lastRead = ref.watch(readStateProvider)[roomId];
  if (lastRead == null) return true;
  return newest.isAfter(lastRead);
});

/// True iff any room the user is in is unread. Used for the header pill's
/// "unread elsewhere" dot.
final anyUnreadProvider = Provider.family<bool, List<String>>((ref, roomIds) {
  for (final id in roomIds) {
    if (ref.watch(roomUnreadProvider(id))) return true;
  }
  return false;
});
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/read_state_provider_test.dart`
Expected: PASS

- [ ] **Step 6: Run analyze**

Run: `cd app && flutter analyze`
Expected: no issues.

- [ ] **Step 7: Commit**

```bash
git add app/lib/inbox/read_state_provider.dart app/lib/identity/providers.dart app/test/inbox/read_state_provider_test.dart
git commit -m "feat(inbox): read-state provider + per-room unread derivation"
```

---

## Task 4: Mark rooms read when selected

When a room becomes the selected/active room, advance its read marker. The cleanest single choke point is the router's frame handling plus inbox selection. We mark-read in two places: when the user selects a room (sidebar/switcher tap) and when a room is auto-selected on creation.

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`
- Modify: `app/lib/screens/inbox/inbox_shell.dart`
- Test: `app/test/inbox/mark_read_on_select_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/mark_read_on_select_test.dart`. This verifies the helper that callers use to select + mark read together:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/inbox/select_room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Member m(String u) => Member(
      username: u,
      ed25519PubBase64: '',
      x25519PubBase64: '',
      isBot: false,
      ownerUsername: null,
    );

void main() {
  test('selectAndMarkRead selects the room and clears its unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final room = Room(
      roomId: 'room-a',
      name: '',
      members: [m('court'), m('kaitlyn')],
      createdAt: DateTime.utc(2026, 6, 14),
    );
    c.read(inboxStateProvider.notifier).setRooms([room]);
    c.read(messageStoreProvider('room-a').notifier).add(
          Msg(id: 'm1', from: 'kaitlyn', to: 'room-a', body: 'hi',
              ts: DateTime.utc(2026, 6, 14, 12)),
        );
    expect(c.read(roomUnreadProvider('room-a')), isTrue);

    selectAndMarkRead(c, 'room-a');

    expect(c.read(inboxStateProvider).selectedRoomId, 'room-a');
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/mark_read_on_select_test.dart`
Expected: FAIL — `select_room.dart` / `selectAndMarkRead` does not exist.

- [ ] **Step 3: Write the helper**

Create `app/lib/inbox/select_room.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'inbox_state.dart';
import 'read_state_provider.dart';

/// Select [roomId] as the active room and mark it read in one step. Use this
/// everywhere a room is opened (switcher tap, sidebar tap, auto-select on
/// create) so unread state stays consistent. Accepts any Riverpod reader
/// ([WidgetRef], [Ref], or [ProviderContainer]).
void selectAndMarkRead(dynamic reader, String roomId) {
  reader.read(inboxStateProvider.notifier).select(roomId);
  reader.read(readStateProvider.notifier).markRead(roomId);
}
```

Note: `dynamic` is used because `WidgetRef`, `Ref`, and `ProviderContainer` all expose `.read(...)` but share no common interface. This is a deliberate, contained use.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/mark_read_on_select_test.dart`
Expected: PASS

- [ ] **Step 5: Route the auto-select-on-create through the helper**

In `app/lib/conversation/room_message_router.dart`, in the `RoomCreatedFrame` case (currently line 63: `ref.read(inboxStateProvider.notifier).select(roomId);`), replace with:

```dart
        // The creator just made this room — drop them into it and mark read.
        selectAndMarkRead(ref, roomId);
```

Add the import at the top:

```dart
import '../inbox/select_room.dart';
```

- [ ] **Step 6: Route conversation viewing through mark-read**

In `app/lib/screens/inbox/inbox_shell.dart`, when a room is the selected detail (right before `return ConversationPage(...)` at line 153), mark it read so opening a conversation clears its dot. Add, inside `_detail` just after `final room = rooms.firstWhere(...)` and the solo-pending guard:

```dart
    // Viewing a room marks it read. Done post-frame to avoid mutating a
    // provider during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readStateProvider.notifier).markRead(room.roomId);
    });
```

Add the import:

```dart
import '../../inbox/read_state_provider.dart';
```

- [ ] **Step 7: Update sidebar/drawer taps to use the helper**

In `app/lib/inbox/sidebar.dart` (line 38) and `app/lib/inbox/drawer.dart` (the equivalent `onTap`), replace `ref.read(inboxStateProvider.notifier).select(r.roomId)` with `selectAndMarkRead(ref, r.roomId)` and add `import 'select_room.dart';` to each.

- [ ] **Step 8: Run analyze + tests**

Run: `cd app && flutter analyze && flutter test test/inbox/`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/lib/inbox/select_room.dart app/lib/conversation/room_message_router.dart app/lib/screens/inbox/inbox_shell.dart app/lib/inbox/sidebar.dart app/lib/inbox/drawer.dart app/test/inbox/mark_read_on_select_test.dart
git commit -m "feat(inbox): mark rooms read on open/select"
```

---

## Task 5: Channel switcher widget

The header pill + dropdown overlay. Pill shows the current context (partner name or `#channel`). Tapping opens an overlay: a "YOU & <partner>" group with the pinned partner thread, a "CHANNELS" group of named rooms (unread → bold + dot), and a "+ New channel" footer. Tapping a row calls `selectAndMarkRead` and closes; tapping the scrim closes.

**Files:**
- Create: `app/lib/inbox/channel_switcher.dart`
- Test: `app/test/inbox/channel_switcher_test.dart`

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/channel_switcher_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/inbox/channel_switcher.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u, {bool bot = false, String? owner}) => Member(
      username: u, ed25519PubBase64: '', x25519PubBase64: '',
      isBot: bot, ownerUsername: owner,
    );

Room room(String id, List<Member> members, {String name = ''}) => Room(
      roomId: id, name: name, members: members,
      createdAt: DateTime.utc(2026, 6, 14),
    );

Widget harness(WidgetRef Function() _, {required List<Room> rooms, String? selected}) {
  return ProviderScope(
    overrides: const [],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        ref.read(inboxStateProvider.notifier).setRooms(rooms);
        if (selected != null) ref.read(inboxStateProvider.notifier).select(selected);
        return Scaffold(body: ChannelSwitcher(selfUsername: 'court'));
      }),
    ),
  );
}

void main() {
  testWidgets('pill shows partner name when partner room selected', (t) async {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    await t.pumpWidget(harness(() => throw '', rooms: [partner], selected: 'p'));
    await t.pump();
    expect(find.text('Kaitlyn'), findsOneWidget);
  });

  testWidgets('tapping pill opens dropdown listing channels', (t) async {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    final chan = room('c', [m('court'), m('kaitlyn')], name: 'date-ideas');
    await t.pumpWidget(harness(() => throw '', rooms: [partner, chan], selected: 'p'));
    await t.pump();
    await t.tap(find.byKey(const Key('channel-switcher-pill')));
    await t.pumpAndSettle();
    expect(find.text('date-ideas'), findsOneWidget);
    expect(find.byKey(const Key('switcher-new-channel')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/channel_switcher_test.dart`
Expected: FAIL — `channel_switcher.dart` does not exist.

- [ ] **Step 3: Write the widget**

Create `app/lib/inbox/channel_switcher.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/twilight.dart';
import 'inbox_state.dart';
import 'read_state_provider.dart';
import 'room.dart';
import 'select_room.dart';

/// Header pill that shows the active room and opens a dropdown of all rooms.
/// Partner thread is pinned; named channels follow; unread rows are bold +
/// dotted. The "+ New channel" row's tap is delegated via [onNewChannel].
class ChannelSwitcher extends ConsumerWidget {
  const ChannelSwitcher({
    super.key,
    required this.selfUsername,
    this.onNewChannel,
  });

  final String selfUsername;
  final VoidCallback? onNewChannel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    final selected = inbox.selectedRoomId == null
        ? null
        : inbox.rooms
            .where((r) => r.roomId == inbox.selectedRoomId)
            .cast<Room?>()
            .firstWhere((_) => true, orElse: () => null);

    final isPartner =
        selected != null && selected.shape(selfUsername) == RoomShape.partner;
    final label = selected?.displayName(selfUsername) ?? 'LittleLove';
    final otherRoomIds = inbox.rooms
        .where((r) => r.roomId != inbox.selectedRoomId)
        .map((r) => r.roomId)
        .toList();
    final unreadElsewhere = ref.watch(anyUnreadProvider(otherRoomIds));

    return InkWell(
      key: const Key('channel-switcher-pill'),
      borderRadius: BorderRadius.circular(999),
      onTap: () => _openSheet(context, ref),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
        decoration: BoxDecoration(
          color: TwilightColors.bgSurfaceAlt,
          border: Border.all(color: TwilightColors.borderSoft),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isPartner)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text('#',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: TwilightColors.textMuted)),
              ),
            Text(label,
                style: const TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: TwilightColors.textPrimary)),
            const SizedBox(width: 4),
            if (unreadElsewhere)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 4),
                decoration: const BoxDecoration(
                    color: TwilightColors.accentUser, shape: BoxShape.circle),
              ),
            const Text('▾',
                style: TextStyle(color: TwilightColors.textMuted, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final selfUsername = this.selfUsername;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TwilightColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => Consumer(
        builder: (context, ref, _) {
          final inbox = ref.watch(inboxStateProvider);
          List<Room> bucket(RoomShape s) => inbox.rooms
              .where((r) => r.shape(selfUsername) == s)
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          final partners = bucket(RoomShape.partner);
          final channels = bucket(RoomShape.chat);

          Widget rowFor(Room r, {required bool partner}) {
            final unread = ref.watch(roomUnreadProvider(r.roomId));
            return ListTile(
              key: Key('switcher-row-${r.roomId}'),
              leading: Text(partner ? '' : '#',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: TwilightColors.textMuted)),
              title: Text(
                r.displayName(selfUsername),
                style: TextStyle(
                    fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                    color: TwilightColors.textPrimary),
              ),
              trailing: unread
                  ? Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                          color: TwilightColors.accentUser,
                          shape: BoxShape.circle))
                  : null,
              selected: inbox.selectedRoomId == r.roomId,
              onTap: () {
                selectAndMarkRead(ref, r.roomId);
                Navigator.of(sheetCtx).pop();
              },
            );
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (partners.isNotEmpty) ...[
                  const _SectionLabel('YOU & PARTNER'),
                  ...partners.map((r) => rowFor(r, partner: true)),
                ],
                if (channels.isNotEmpty) ...[
                  const _SectionLabel('CHANNELS'),
                  ...channels.map((r) => rowFor(r, partner: false)),
                ],
                const Divider(height: 1, color: TwilightColors.borderSoft),
                ListTile(
                  key: const Key('switcher-new-channel'),
                  leading: const Text('+',
                      style: TextStyle(
                          fontSize: 18, color: TwilightColors.accentUser)),
                  title: const Text('New channel',
                      style: TextStyle(
                          color: TwilightColors.accentUser,
                          fontWeight: FontWeight.w500)),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    onNewChannel?.call();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(text,
            style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                letterSpacing: 2.0,
                color: TwilightColors.accentFamiliar)),
      );
}
```

Note: the mock shows a custom dropdown panel under the header; this implementation uses `showModalBottomSheet` for a robust, testable overlay with the same grouping/labels. If a true anchored dropdown is desired later it can replace `_openSheet` without changing callers.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/channel_switcher_test.dart`
Expected: PASS

- [ ] **Step 5: Run analyze**

Run: `cd app && flutter analyze`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
git add app/lib/inbox/channel_switcher.dart app/test/inbox/channel_switcher_test.dart
git commit -m "feat(inbox): channel switcher pill + dropdown with unread"
```

---

## Task 6: Partner DM as home (default selection)

Opening the app should land in the partner thread, not a "Select a conversation" screen. When there are rooms but no selection, auto-select the partner room (or the most recent room if no partner room exists).

**Files:**
- Modify: `app/lib/inbox/inbox_state.dart` (add a pure helper)
- Modify: `app/lib/screens/inbox/inbox_shell.dart`
- Test: `app/test/inbox/default_home_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/default_home_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u, {bool bot = false, String? owner}) => Member(
      username: u, ed25519PubBase64: '', x25519PubBase64: '',
      isBot: bot, ownerUsername: owner);

Room room(String id, List<Member> members, {String name = '', int day = 14}) =>
    Room(roomId: id, name: name, members: members,
        createdAt: DateTime.utc(2026, 6, day));

void main() {
  test('defaultHomeRoomId prefers the partner room', () {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    final channel = room('c', [m('court'), m('kaitlyn')], name: 'logistics');
    expect(defaultHomeRoomId([channel, partner], 'court'), 'p');
  });

  test('defaultHomeRoomId falls back to most recent when no partner room', () {
    final older = room('a', [m('court'), m('kaitlyn')], name: 'x', day: 10);
    final newer = room('b', [m('court'), m('kaitlyn')], name: 'y', day: 14);
    expect(defaultHomeRoomId([older, newer], 'court'), 'b');
  });

  test('defaultHomeRoomId returns null for empty', () {
    expect(defaultHomeRoomId(const [], 'court'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/default_home_test.dart`
Expected: FAIL — `defaultHomeRoomId` not defined.

- [ ] **Step 3: Write the helper**

At the bottom of `app/lib/inbox/inbox_state.dart` (top-level function, after the provider), add:

```dart
/// The room to open by default ("home"): the partner DM if one exists,
/// otherwise the most recently created room. Returns null for an empty inbox.
String? defaultHomeRoomId(List<Room> rooms, String selfUsername) {
  if (rooms.isEmpty) return null;
  for (final r in rooms) {
    if (r.shape(selfUsername) == RoomShape.partner) return r.roomId;
  }
  final sorted = [...rooms]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return sorted.first.roomId;
}
```

Ensure `inbox_state.dart` imports `room.dart` (it already does at line 4).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/default_home_test.dart`
Expected: PASS

- [ ] **Step 5: Wire default selection in the shell**

In `app/lib/screens/inbox/inbox_shell.dart`, in `_detail`, replace the `if (selectedId == null) { ... "Select a conversation" ... }` block (lines 114-141) with an auto-select that lands on the home room. Change the block to:

```dart
    if (selectedId == null) {
      final home = defaultHomeRoomId(rooms, account.username);
      if (home != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(inboxStateProvider.notifier).select(home);
          ref.read(readStateProvider.notifier).markRead(home);
        });
        // One frame of empty canvas before selection lands.
        return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
      }
      // No rooms case is handled above; this is unreachable when rooms exist.
      return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
    }
```

Add the import for `read_state_provider.dart` if not already added in Task 4 (it was). `WidgetsBinding` comes from `package:flutter/material.dart` (already imported).

- [ ] **Step 6: Run analyze + the inbox shell widget tests**

Run: `cd app && flutter analyze && flutter test test/`
Expected: PASS. Note: if an existing widget test asserted the literal "Select a conversation" string for the rooms-present-no-selection case, update it to assert the conversation now auto-opens (search `grep -rn "Select a conversation" app/test`). Fix any such test to reflect auto-home.

- [ ] **Step 7: Commit**

```bash
git add app/lib/inbox/inbox_state.dart app/lib/screens/inbox/inbox_shell.dart app/test/inbox/default_home_test.dart
git commit -m "feat(inbox): land in partner DM as home by default"
```

---

## Task 7: Mount the switcher in the conversation header

Put `ChannelSwitcher` in the `ConversationPage` AppBar so it's the primary nav on mobile. Wire "+ New channel" to open the create-channel sheet (Task 8 builds the sheet; here we wire a callback hook).

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`
- Modify: `app/lib/screens/inbox/inbox_shell.dart`
- Test: `app/test/conversation/header_switcher_test.dart` (create)

- [ ] **Step 1: Add an `onNewChannel`/header hook to ConversationPage**

In `app/lib/conversation/conversation_page.dart`, add an optional field to the widget:

```dart
  final VoidCallback? onNewChannel;
```

Add it to the constructor parameter list (as `this.onNewChannel`).

- [ ] **Step 2: Replace the AppBar title with the switcher**

In the `build` method's `AppBar`, replace the existing `title: Row(children: [_PeerAvatar(...), ... Text(contactDisplayName) ...])` with the switcher while keeping the existing rename/leave actions:

```dart
        title: ChannelSwitcher(
          selfUsername: widget.selfUsername,
          onNewChannel: widget.onNewChannel,
        ),
```

Add the import:

```dart
import '../inbox/channel_switcher.dart';
```

Leave the AppBar `actions:` (rename/leave menu) intact. The `_PeerAvatar`/`_Dot` widgets may become unused — if `flutter analyze` flags them as unused, delete them.

- [ ] **Step 3: Write a widget test**

Create `app/test/conversation/header_switcher_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u) => Member(
    username: u, ed25519PubBase64: '', x25519PubBase64: '',
    isBot: false, ownerUsername: null);

void main() {
  testWidgets('conversation header renders the channel switcher pill',
      (t) async {
    final room = Room(
      roomId: 'p', name: '',
      members: [m('court'), m('kaitlyn')],
      createdAt: DateTime.utc(2026, 6, 14),
    );
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          ref.read(inboxStateProvider.notifier).setRooms([room]);
          ref.read(inboxStateProvider.notifier).select('p');
          return ConversationPage(
            room: room,
            selfUsername: 'court',
            onSend: (_) {},
          );
        }),
      ),
    ));
    await t.pump();
    expect(find.byKey(const Key('channel-switcher-pill')), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/conversation/header_switcher_test.dart`
Expected: PASS

- [ ] **Step 5: Pass `onNewChannel` from the shell**

In `app/lib/screens/inbox/inbox_shell.dart`, in the `ConversationPage(...)` construction (line 153), add:

```dart
      onNewChannel: () => showCreateChannelSheet(context, ref, account.username),
```

`showCreateChannelSheet` is created in Task 8. Until then, this will not compile — so **do Task 8 before running the full app**, but the per-file unit/widget tests in this task pass independently. Add a temporary import placeholder now and complete it in Task 8:

```dart
import '../create_chat/create_channel_sheet.dart';
```

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/lib/screens/inbox/inbox_shell.dart app/test/conversation/header_switcher_test.dart
git commit -m "feat(conversation): channel switcher in the header"
```

---

## Task 8: Create-channel bottom sheet

A focused bottom sheet: auto-focused name field that auto-formats to lowercase-with-dashes with a live `#preview`, an optional familiar checklist (partner is implied), and a "Create #name" button that sends `CreateRoomFrame(name, botAccountIds, inviteHumanPartner: true)`. The server auto-adds the paired partner with no pending invite.

**Files:**
- Create: `app/lib/screens/create_chat/create_channel_sheet.dart`
- Test: `app/test/screens/create_channel_sheet_test.dart`

- [ ] **Step 1: Write the failing test (auto-format pure function)**

Create `app/test/screens/create_channel_sheet_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/screens/create_chat/create_channel_sheet.dart';

void main() {
  group('formatChannelName', () {
    test('lowercases and dashes spaces', () {
      expect(formatChannelName('Date Ideas'), 'date-ideas');
    });
    test('collapses repeated spaces/dashes', () {
      expect(formatChannelName('weekly   check--in'), 'weekly-check-in');
    });
    test('strips invalid characters', () {
      expect(formatChannelName('trip!! 2026 ✨'), 'trip-2026');
    });
    test('trims leading/trailing dashes', () {
      expect(formatChannelName('  -hello-  '), 'hello');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/screens/create_channel_sheet_test.dart`
Expected: FAIL — `create_channel_sheet.dart` / `formatChannelName` does not exist.

- [ ] **Step 3: Write the sheet + formatter**

Create `app/lib/screens/create_chat/create_channel_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inbox/owned_bots_provider.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';

/// Normalize a free-text channel name to lowercase-with-dashes: lowercase,
/// non-alphanumeric runs become single dashes, leading/trailing dashes
/// trimmed. Pure + tested.
String formatChannelName(String input) {
  final lowered = input.toLowerCase();
  final dashed = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return dashed.replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Open the create-channel bottom sheet. Partner membership is implied
/// (`inviteHumanPartner: true`); the server adds the already-paired partner
/// directly with no pending invite.
Future<void> showCreateChannelSheet(
    BuildContext context, WidgetRef ref, String selfUsername) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TwilightColors.bgCanvas,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: const _CreateChannelSheet(),
    ),
  );
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet();
  @override
  ConsumerState<_CreateChannelSheet> createState() => _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _selectedBots = <String>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Auto-focus so the user can type immediately (mock 05).
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _formatted => formatChannelName(_controller.text);

  Future<void> _create() async {
    if (_submitting) return;
    final name = _formatted;
    if (name.isEmpty) return;
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Not connected — try again in a moment.')));
      return;
    }
    final bots = ref.read(ownedBotsProvider);
    final botAccountIds = <int>[
      for (final b in bots)
        if (_selectedBots.contains(b.username) && b.accountId != null)
          b.accountId!,
    ];
    setState(() => _submitting = true);
    conn.send(CreateRoomFrame(
      name: name,
      botAccountIds: botAccountIds,
      inviteHumanPartner: true,
    ).toJson());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(ownedBotsProvider);
    final preview = _formatted.isEmpty ? 'channel' : _formatted;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42, height: 5,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                    color: TwilightColors.borderSoft,
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const Text('New channel',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w600,
                    fontSize: 23,
                    color: TwilightColors.textPrimary)),
            const SizedBox(height: 6),
            const Text(
                'A topic room just for the two of you. Add a familiar to listen in.',
                style: TextStyle(fontSize: 13, color: TwilightColors.textMuted)),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text('#',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: TwilightColors.textMuted)),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const Key('channel-name-field'),
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    inputFormatters: [LengthLimitingTextInputFormatter(64)],
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _create(),
                    decoration: const InputDecoration(
                        hintText: 'date-ideas', border: InputBorder.none),
                    style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.textPrimary),
                  ),
                ),
              ],
            ),
            const Divider(color: TwilightColors.borderSoft),
            Text('Preview:  #$preview',
                key: const Key('channel-preview'),
                style: const TextStyle(
                    fontSize: 12, color: TwilightColors.textMuted)),
            const SizedBox(height: 16),
            if (bots.isNotEmpty) ...[
              const Text('ADD A FAMILIAR · OPTIONAL',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      letterSpacing: 1.8,
                      color: TwilightColors.accentFamiliar)),
              const SizedBox(height: 8),
              for (final b in bots)
                CheckboxListTile(
                  key: Key('channel-familiar-${b.username}'),
                  value: _selectedBots.contains(b.username),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedBots.add(b.username);
                    } else {
                      _selectedBots.remove(b.username);
                    }
                  }),
                  title: Text(b.username),
                  controlAffinity: ListTileControlAffinity.trailing,
                  activeColor: TwilightColors.accentUser,
                ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              key: const Key('create-channel-button'),
              onPressed:
                  (_formatted.isEmpty || _submitting) ? null : _create,
              style: FilledButton.styleFrom(
                backgroundColor: TwilightColors.accentUser,
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text('Create #$preview'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the formatter test to verify it passes**

Run: `cd app && flutter test test/screens/create_channel_sheet_test.dart`
Expected: PASS

- [ ] **Step 5: Add a widget test for live preview + auto-focus**

Append to `app/test/screens/create_channel_sheet_test.dart`:

```dart
// (Add these imports at the top of the file)
// import 'package:flutter/material.dart';
// import 'package:flutter_riverpod/flutter_riverpod.dart';

  testWidgets('typing updates the live #preview', (t) async {
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Consumer(builder: (context, ref, _) {
              return TextButton(
                onPressed: () =>
                    showCreateChannelSheet(context, ref, 'court'),
                child: const Text('open'),
              );
            }),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('channel-name-field')), 'Date Ideas');
    await t.pump();
    expect(find.text('Preview:  #date-ideas'), findsOneWidget);
    expect(find.text('Create #date-ideas'), findsOneWidget);
  });
```

Move the `import 'package:flutter/material.dart';`, `import 'package:flutter_test/flutter_test.dart';`, and `import 'package:flutter_riverpod/flutter_riverpod.dart';` to the top of the test file (dedupe with the existing `flutter_test` import).

- [ ] **Step 6: Run the widget test**

Run: `cd app && flutter test test/screens/create_channel_sheet_test.dart`
Expected: PASS (both groups).

- [ ] **Step 7: Run analyze (whole app now compiles — Task 7's hook resolves)**

Run: `cd app && flutter analyze`
Expected: no issues. The `showCreateChannelSheet` reference added in Task 7 now resolves.

- [ ] **Step 8: Commit**

```bash
git add app/lib/screens/create_chat/create_channel_sheet.dart app/test/screens/create_channel_sheet_test.dart
git commit -m "feat(create-chat): focused create-channel bottom sheet"
```

---

## Task 9: Required-pairing onboarding surface

The empty inbox already forces pairing (it only offers pair affordances), satisfying "can't reach home solo." This task makes that surface read as an explicit onboarding step ("Invite your partner") rather than a generic empty state, matching mock 04's intent, and confirms there is no path to a solo home.

**Files:**
- Modify: `app/lib/screens/inbox/inbox_shell.dart` (the `rooms.isEmpty` branch, lines 61-113)
- Test: `app/test/inbox/onboarding_pairing_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `app/test/inbox/onboarding_pairing_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/screens/inbox/inbox_shell.dart';

void main() {
  testWidgets('unpaired user sees the pairing onboarding step', (t) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'x',
      x25519PubBase64: 'y',
      createdAt: DateTime.utc(2026, 6, 14),
    );
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(home: InboxShell(account: acc)),
    ));
    await t.pump();
    expect(find.text('Invite your partner'), findsOneWidget);
  });
}
```

(Note: `InboxShell` reads `liveConnectionProvider`; the empty-rooms branch renders before any connection data is needed because `inboxStateProvider` starts empty. If the test trips on an unmet `requireValue`, wrap the assertion in `t.pump()` only — the empty branch returns before the router activates. If a provider override is required to avoid a network call, override `liveConnectionProvider` with an `AsyncValue.loading()` via `ProviderScope(overrides: [...])`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/inbox/onboarding_pairing_test.dart`
Expected: FAIL — current copy says "Pair with your partner to begin." not "Invite your partner".

- [ ] **Step 3: Reword the empty-state heading to read as onboarding**

In `app/lib/screens/inbox/inbox_shell.dart`, in the `rooms.isEmpty` branch, change the eyebrow + heading. Replace the existing `'No conversations yet'` eyebrow text and the `'Pair with your partner to begin.'` headline with:

```dart
                    const Text(
                      'STEP 4 OF 4 · PAIR',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.accentFamiliar,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Invite your partner',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        height: 1.14,
                        letterSpacing: -0.6,
                        color: TwilightColors.textPrimary,
                      ),
                    ),
```

Keep the existing descriptive paragraph and `PairCard` below it. (If a widget test elsewhere asserts the old `'No conversations yet'` string, update it — `grep -rn "No conversations yet" app/test`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/inbox/onboarding_pairing_test.dart`
Expected: PASS

- [ ] **Step 5: Run analyze + full suite**

Run: `cd app && flutter analyze && flutter test`
Expected: PASS across the suite. Fix any string-literal assertions broken by the reword.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/inbox/inbox_shell.dart app/test/inbox/onboarding_pairing_test.dart
git commit -m "feat(onboarding): frame unpaired state as the pairing step"
```

---

## Task 10: Manual verification pass (UI in a browser/simulator)

Static + widget tests verify code correctness, not feature correctness. Run the app and exercise the golden paths.

- [ ] **Step 1: Run the app against the dev server**

Run (from repo root): `./scripts/ios-deploy.sh --server wss://acre-vocally-oxidant.ngrok-free.dev` (or the project's standard run command / `cd app && flutter run`). Confirm the server is up first.

- [ ] **Step 2: Exercise golden paths and confirm each**

- [ ] Fresh account → lands on "Invite your partner" pairing step; no way to reach a solo home.
- [ ] After pairing → app opens directly in the partner DM (switcher pill shows partner name).
- [ ] Tap switcher → dropdown shows the partner thread pinned + "New channel"; no seeded channels.
- [ ] Create a channel via the sheet → name auto-formats to lowercase-dashes, live `#preview` updates, "Create #name" creates it and drops you into it (partner already a member, no invite code shown).
- [ ] Add a familiar in the sheet → familiar appears as a participant; its bubbles render with the sage tint.
- [ ] Send a message in a non-active channel from the other device (or bot) → that channel shows bold + dot in the switcher and the pill shows the "unread elsewhere" dot; opening it clears both.
- [ ] Restart the app → read state persists (previously-read channels are not falsely unread).

- [ ] **Step 3: Note any gaps**

If the UI can't be exercised (no second device / server down), say so explicitly rather than marking verified. Record any deviations from the mocks for follow-up.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Partner DM as home → Task 6. ✅
- Chat bubbles unchanged → preserved; only bot tint added (Task 1). ✅
- Header channel switcher → Tasks 5, 7. ✅
- Familiars as participants (tint, in-channel) → Tasks 1, 8 (familiar picker, no solo-bot channel). ✅
- Required pairing onboarding → Task 9. ✅
- Clean first run (no seeded channels) → no seeding added anywhere; verified in Task 10. ✅
- Data-model mapping (rooms↔channels, CreateRoom auto-adds partner) → Task 8 uses `inviteHumanPartner: true`; server confirmed (`ws.rs:686-743`). ✅
- Unread state (local per-device, switcher bold+dot, header pill dot, mark-read on open) → Tasks 2, 3, 4, 5. ✅
- Push notifications → explicitly out of scope (deferred spec); no task. ✅ (intentional)
- Responsive: mobile primary (switcher); desktop sidebar keeps grouping → sidebar already buckets by `RoomShape`; switcher targets mobile header. Tasks 4/6 keep sidebar consistent (mark-read on tap). ✅

**Placeholder scan:** No TBD/TODO; every code step has full code. The only cross-task dependency (Task 7 references `showCreateChannelSheet` from Task 8) is called out explicitly with build ordering.

**Type consistency:** `selectAndMarkRead(reader, roomId)`, `markRead(roomId)`, `roomUnreadProvider(roomId)`, `anyUnreadProvider(List<String>)`, `defaultHomeRoomId(rooms, self)`, `formatChannelName(String)`, `showCreateChannelSheet(context, ref, self)`, `ChannelSwitcher(selfUsername, onNewChannel)` are used consistently across tasks. `Member` fields (`accountId`, `username`, `isBot`, `ownerUsername`) match `frames.dart`. `CreateRoomFrame(name, botAccountIds, inviteHumanPartner)` matches the existing frame.

**Scope:** Single coherent client-side redesign; no server changes; no data migrations (CLAUDE.md respected). Sized for one implementation pass.
