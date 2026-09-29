---
paths:
  - "app/**/*.dart"
  - "app/pubspec.yaml"
  - "app/analysis_options.yaml"
---

# Dart / Flutter coding standards (`app/`)

These describe how the app is already written. Match them in new code. Where
the codebase is inconsistent, the rule below says which side to follow; do not
"fix" the other side in an unrelated change. Rules the existing code doesn't
fully follow yet are listed under "Known gaps" at the end: apply them to new
code, and don't flag the existing gaps in review. The E2EE rules in the root
`CLAUDE.md` ("E2EE message semantics") apply to all of this and are not
repeated here.

Scope reminder: iOS-only MVP, exactly two partners per room.

## Gate before you call it done

The CI `flutter` and `ios-build` jobs run these from `app/` (see
`.github/workflows/ci.yml`); info-level lints fail CI:

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
# ios-build job:
(cd ios && pod install)
flutter build ios --simulator --no-codesign
```

A green `flutter test` does not prove the iOS build works: the simulator build
is what catches federated-plugin breaks. Any change to `pubspec.yaml` plugins
also needs a device install via `scripts/ios-deploy.sh` (see `CLAUDE.md`,
"On-device testing").

## Layout and naming

- Feature folders under `lib/<feature>/` (`conversation/`, `inbox/`,
  `calling/`, `outbox/`, `identity/`, ...). A feature keeps its model, state,
  persistence and widgets together. Top-level route destinations go in
  `lib/screens/<area>/`. Protocol types go in `lib/wire/`, primitives in
  `lib/crypto/`.
- One concept per file, snake_case. Suffixes: `_provider.dart`, `_state.dart`
  (a Notifier), `_store.dart`, `_controller.dart`, `_page.dart` /
  `_screen.dart` (routes), `_sheet.dart`.
- Inside `lib/`, import with **relative** paths. Tests import app code as
  `package:littlelove/...`; test-only helpers (`test/support/`,
  `test/outbox/memory_outbox_store.dart`) are imported relatively. Order:
  `dart:`, `package:`, relative.
- Do not add to `lib/ws_client.dart` (legacy, test-only).

## State management: Riverpod 2, hand-written (no codegen)

- Declare providers as top-level `final xxxProvider = ...`, at the bottom of
  the file that defines the class. Use the `.new` tear-off.
- **New state uses Riverpod `Notifier` / `FamilyNotifier`** (per-room state is
  `NotifierProvider.family`, like `MessageStore`). Async singletons are
  `FutureProvider`; plain services are `Provider<Service>`. Family keys with
  several parts are records: `({String me, String roomId})`.
- Do not introduce new `ChangeNotifier`/`ChangeNotifierProvider` or
  `StateProvider` state. Existing ones (`ProfileStore`, audio controllers,
  `CallController`'s `ValueNotifier`s, `activeRoomProvider`) stay until
  deliberately migrated. `ValueNotifier` is fine for tight widget-local ticks.
- Class names: `XxxNotifier`, `XxxStore`, or `XxxController`.
- In widgets: `ref.watch` in `build`, `ref.read(x.notifier)` in handlers,
  `ref.listen` in `build` for one-shot commands. Never mutate a provider
  synchronously inside a listener during build; defer with
  `Future.microtask` and say why in a comment.
- Read live state with `ref.watch`, not a constructor argument or a
  one-time `_seeded` latch. Stale snapshots have caused real bugs.
- Long-lived listeners (anything that must hear events from app start) must be
  **eagerly** instantiated, e.g. watched in `HomeScreen.build`. A lazy
  provider that nobody reads never subscribes.
- Take a typed `Ref`/`WidgetRef`, never `dynamic`. (`inbox/select_room.dart`
  does this; don't copy it.)
- Pages are presentational: `ConversationPage` takes callbacks
  (`onSend`, `onDelete`, ...) and the send/encrypt/outbox wiring lives in
  `screens/inbox/home_screen.dart`. A null callback hides the affordance;
  document that on the field.

## Async, errors, logging

- After every `await` in a `State`: `if (!mounted) return;`. In a function
  given a `BuildContext`: `if (!context.mounted) return;`.
- `catch (e, st)` when you report; `catch (_)` only for best-effort paths.
  New `catch (_)` sites get a comment saying why swallowing is safe. Prefer
  typed `on FooException catch (e)`, and never catch only one exception type
  when others can reach the user (a signup path once swallowed every error
  this way).
- Fire-and-forget: `unawaited(...)` or `.catchError((_) {})`, never a bare
  un-awaited future. Anything on a sign-out or teardown path is awaited.
- Throw `StateError` for programmer/state errors, `ArgumentError` for bad
  input (`'must be 32 bytes, got $n'`), `FormatException` for parse errors.
  Custom exceptions `implements Exception`. No `!` on a value that can
  legitimately be null at runtime; throw a descriptive `StateError`.
- Guard flags (`_ending`, `_sending`) are reset in `finally`.
- Logging is `debugPrint` with a short lowercase prefix (`'call: ...'`). No
  `print`, no logger package.
- Faults go through `reportFault(e, st, context: 'constant_label')`
  (`diagnostics/crash_reporting.dart`). The context is a **constant**; never
  interpolate message content, usernames, room names, paths or raw frames.
  Report a malformed frame as a constant `FormatException`, not its payload.
- New identifying field names go into `_sensitiveKeys` in
  `diagnostics/scrub.dart` **and** `SENSITIVE_KEYS` in `server/src/scrub.rs`.
- User-facing failures: a short `SnackBar` sentence; positive confirmations use
  `showLoveToast`. Copy follows the no-em-dash rule. Feedback (chime, toast,
  "sent") fires only after the durable step (outbox enqueue), never before.
- Every error after an optimistic insert moves the row to
  `SendStatus.failed` (tap to retry) or removes it. Never leave "sending"
  stuck.

## Persistence

- Seams are `abstract class` + a production `Sqlite*`/`Secure*`
  implementation + a `.test(...)` factory or in-memory fake (`MessageDb`,
  `OutboxStore`, `Keystore`).
- `MessageDb` (SQLCipher) is a rebuildable cache, never the source of truth.
  Local `onUpgrade` backfills are allowed there (the schema-only rule is for
  server Postgres). Bump `schemaVersion` and add an `if (oldV < N)` block.
- Never write plaintext to the outbox (it stores ciphertext only, unencrypted
  sqflite).
- Secrets live in `flutter_secure_storage` with
  `KeychainAccessibility.first_unlock_this_device`. Non-sensitive flags go in
  `SharedPreferences` with dotted keys (`'diagnostics.crashReporting.enabled'`).
- **Every new persisted store, cache, pref, index or keychain item must be
  wiped (and awaited) in `identity/sign_out.dart`**, and its providers
  invalidated. Include side tables (FTS shadow tables were missed once).
- The router applies each frame to the in-memory `MessageStore` and to
  `MessageDb` with identical semantics. Hydrate from the DB **before** sending
  `SubscribeFrame`.

## E2EE and message flow (Dart specifics)

- Encrypt sends only in `conversation/send_fanout.dart` (`buildSendFrame`).
  Decrypt receives only in `RoomMessageRouter._ingestMessage`. Do not add a
  second path.
- `decryptIncoming` never throws; it returns `cannotDecryptSentinel`.
  `MessageContent.decode` falls back to text. Keep both total.
- HKDF salts (`'littlelove.v0.2.room'`, `'littlelove.v0.2.call-sig'`) are
  pinned. Changing one is a wire-incompatible protocol bump.
- Ids: `clientMsgId` and call ids are `Uuid().v4()` (CallKit crashes on a
  ULID). Never hand-roll id strings.
- Per-row UI state (keys, animations, pop-in seeds) is keyed by
  `clientMsgId ?? id` so it survives the optimistic-to-server-id swap.
- Mutators on `MessageStore` are idempotent on `Msg.id`; document it.
- Every enqueue into the outbox is followed by `drain.kick()`. Outbox rows are
  removed only on the echo, never after a send.
- **Adding a `MessageContent` kind or a frame type:** update every exhaustive
  `switch` on it (router, outbox rehydrate, `MessageDb`, FTS indexing,
  chat-info tabs, reply-quote preview) and decide explicitly whether it bumps
  unread, banner and chime. Non-timeline kinds (reaction, delete, edit,
  call-log) must not. Mirror the change in `server/src/wire.rs` with a
  round-trip test on both sides.

## Wire and data classes

- Inbound: `sealed class` + `factory fromJson` switching on `'kind'`, throwing
  `FormatException` on unknown kinds. Outbound: plain class with `toJson()`.
- Required JSON fields `json['x']! as String`; optional
  `(json['x'] as String?) ?? ''`. Timestamps: `DateTime.parse(s).toUtc()`;
  now is `DateTime.now().toUtc()`.
- Data classes are hand-written (`const` ctor, `final` fields, manual
  `fromJson`/`toJson`/`copyWith`). No freezed/json_serializable. `copyWith`
  with `??` cannot clear a field; add a named helper when you need to null one.
- State updates are immutable: `state = [...state, m]`.

## Language features

- Prefer `sealed` hierarchies with exhaustive `switch` and object patterns
  (`case RoomsFrame(:final rooms):`). Unhandled variants get explicit empty
  cases with a comment, not a `default`.
- Switch expressions for values; records for small multi-value returns.
- `late final` for fields initialized once; avoid plain `late`.
- Config comes from `const _x = String.fromEnvironment('KEY', defaultValue: ...)`
  at the top of the file that uses it; an empty default means "disabled".
  `Platform.environment` is empty on iOS, so never rely on it.

## Widgets and theming

- `const` constructors and `super.key` everywhere.
- Colors come from `context.palette` (`AppPalette` theme extension). Don't
  add new raw `Color(0x...)` literals outside `theme/` and `wallpaper/`; add
  a palette entry instead. Text geometry from
  `TwilightType`, color from the palette.
- Private widgets used by one screen live in that file as `_PrivateWidget`
  classes. Prefer a small private widget class over a new
  `Widget _buildX()` helper method. `conversation_page.dart` (~3.9k lines) is
  over-large: put new self-contained pieces (bubbles, sheets, overlays) in
  their own file in `conversation/`.
- Anything a test needs to find gets `const Key('kebab-case-id')`; dynamic
  keys interpolate an id (`Key('bubble-bg-${m.clientMsgId ?? m.id}')`).
  List rows use stable `ValueKey`s plus `findChildIndexCallback`.
- Dispose everything: `AnimationController`, `OverlayEntry`,
  `TapGestureRecognizer`, `StreamSubscription`, timers.
- Bound image decode (`cacheWidth`/`cacheHeight`) for picked or received media.
  Memoize `FutureBuilder` inputs with `late final Future<...> _x = ...`.
- Keep expensive work (sorts, decodes, blurs) out of `build` and hot rebuild
  paths. `RepaintBoundary` only with a measured reason.
- Widgets used under `MaterialApp.builder` or overlays need their own
  `Material` ancestor for ink, and `StackFit.expand` where they fill the screen.
- Content stays between the two partners. Saving received media to your own
  Photos library is allowed (`attachment/media_actions.dart`); share-sheet,
  forward-to-another-app, or export-to-a-third-party affordances are not. No
  new third-party network requests.

## Comments

- Dense `///` doc comments on public and important private members that
  explain **why**: races, invariants, iOS quirks. Use `[Symbol]` refs. Cite the
  spec section or mirrored server file when relevant (`// mirrors server/src/scrub.rs`).
- Library docs: a `///` block followed by `library;`.
- Emphasis: `**bold**` in docs, uppercase `MUST`/`NOT` in inline comments.
- No `TODO`/`FIXME` in `lib/` (open an issue instead). Every `// ignore:` has a
  justification on the line above.

## Tests

- Mirror `lib/` by feature: `test/<feature>/<file>_test.dart`. Split big
  surfaces by behaviour (`conversation_page_outbox_test.dart`, ...).
- No mockito/mocktail, no goldens. Hand-write private fakes that `implements`
  the abstract seam (`_FakeConn implements LiveConnection`). HTTP:
  `MockClient` from `package:http/testing.dart`. Platform channels:
  `setMockMethodCallHandler`. Prefs: `SharedPreferences.setMockInitialValues`.
  Timers: `fakeAsync`.
- Riverpod: `ProviderContainer(overrides: [...])` then
  `addTearDown(container.dispose)` in every test. Widget tests use
  `UncontrolledProviderScope` + `MaterialApp(theme: buildAppTheme(AppPalette.light))`.
- DBs: `sqfliteFfiInit()` with `databaseFactoryFfi`
  (`databaseFactoryFfiNoIsolate` inside `testWidgets`) and
  `inMemoryDatabasePath`, running the production `onCreate`/`onUpgrade`.
- Use real crypto (`deriveIdentity(seed)`), not stubs.
- Wait on conditions, never a fixed `Future.delayed`. The `pumpUntil`
  helper currently lives in `test/conversation/room_message_router_test.dart`;
  when a second file needs it, move it to `test/support/` instead of copying.
- Tests must be hermetic: override anything that touches the real home
  directory (`hermeticReadStateStore()`).
- Name tests as lowercase behaviour sentences that state the invariant:
  `'applyDelete from a non-author is ignored (no spoofed unsend)'`. Test the
  ordering hazards: "update arrives before its row", "late echo after cancel".
- Drive the production flow, not a screen mounted in isolation, when the bug
  lives in the navigation between screens.

## Dependencies

- iOS-only: prefer iOS-native packages; check a plugin's minimum iOS target
  (we ship 13) and that it doesn't pull GoogleMLKit (no arm64 simulator slice).
- Every `dependency_overrides` entry carries a comment explaining why.
- Test-only packages go in `dev_dependencies`.

## Known gaps

Existing code that doesn't meet the rules above yet. Apply the rules to new
and changed code; don't report these as findings on lines a change doesn't
touch.

- **Raw colors**: ~40 `Color(0x...)` literals outside `theme/`/`wallpaper/`,
  mostly in `conversation_page.dart`, `call_screen.dart` and `avatar.dart`.
- **Silent catches**: none of the 29 existing `catch (_)` sites in `lib/`
  has a comment explaining it.
- **State paradigms**: `ProfileStore` and the audio controllers are
  `ChangeNotifier`; `CallController` uses `ValueNotifier`s; several signals
  are `StateProvider`.
- **`dynamic` ref**: `inbox/select_room.dart` takes `dynamic reader`.
- **File size**: `conversation_page.dart` is ~3.9k lines with many
  `Widget _buildX()` helpers.
- **Fixed waits**: some older tests still use `Future.delayed` instead of
  `pumpUntil`.
- **Config defaults**: `LLOVE_SERVER` defaults differ between
  `identity/providers.dart` and `pairing/invite_link.dart`.
- **pubspec**: `toml` is unused; `sqflite_common_ffi` is in `dependencies`
  but only tests import it.
- **Reactions**: `applyReaction` is a no-op when the target isn't present
  yet, unlike edits and read receipts, which are deferred.
