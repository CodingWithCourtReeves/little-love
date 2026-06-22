# Pairing Redesign (Part B, #26 + #16) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the room-minting, three-door pairing flow with a single symmetric pairing screen backed by *roomless* invites and universal links, so the "room before a partner exists" dead-end and the stale "Inviting partner…" label become structurally impossible.

**Architecture:** The server already has everything Part B's backend needs — `RoomClientFrame::CreateInvite` (`server/src/ws.rs:206`) → `handle_create_invite` (`:310`) mints an invite with `room_id = NULL` and creates no room, and `handle_consume_invite` already takes the `room_id IS NULL` branch to create the couple room on consume. The real work is **client-side**: switch `LivePairingTransport.createInvite()` off the `CreateRoom{invite_human_partner:true}` path onto the roomless `CreateInvite` frame; build one symmetric `PairingScreen` (your code + enter-their-code) as `HomeScreen`'s empty state; delete the three-door `PairCard`, `PendingInvitesNotifier`, `show_invite.dart`, `enter_code.dart`, and the pre-pairing channel-creation screens. Then add universal-link transport: an Axum-served AASA + `/pair/:token` fallback, the iOS Associated Domains entitlement, and `app_links` deep-link handling that funnels an incoming link into the same consume path.

**Tech Stack:** Flutter (Riverpod 2.x, raw `Navigator`, `qr_flutter`, new `app_links`), Rust Axum 0.7 backend (single `littlelove-api` crate), Postgres (no migration — `invites.room_id` is already nullable).

## Global Constraints

- **Migrations are schema-only; none is needed here** — `invites.room_id` is already nullable (`server/migrations/0006_v0_3_partner_and_bot.sql:43-47`). Do **not** add a migration.
- **Never run `cargo test` against the dev `littlelove` DB** — it truncates every table (`fresh_store()`). Point `DATABASE_URL` at `littlelove_test`.
- **Run the full CI lint locally before any push:** from `server/`: `cargo fmt --all -- --check` + `cargo clippy --all-targets -- -D warnings`; from `app/`: `dart format --output=none --set-exit-if-changed .` + `flutter analyze` + `flutter test`.
- **On-device testing** uses `./scripts/ios-deploy.sh --server <url>` to **both** physical phones — Court's iPhone 17 Pro Max (`0DC6E4DC-B58D-509A-A5B8-FD316A255D89`) and the iPhone 13 Pro Max (`F031FD6D-9E3D-5005-918D-BB860CE37C26`) — **never** Kaitlyn's iPhone 16 Pro Max. Build **one at a time** (`ios-deploy.sh` rewrites the shared `Release.xcconfig`).
- **E2EE invariant:** consume still requires the app's Ed25519 signature over `"littlelove.v0.2.invite-consume" || 0x00 || canonical_token`. A bare GET of a `/pair/<token>` link cannot produce it, so a link preview is inert — no extra hardening.
- **iOS appID** is `9PVUX2535W.dev.littlelove.littlelove` (`DEVELOPMENT_TEAM = 9PVUX2535W`, `PRODUCT_BUNDLE_IDENTIFIER = dev.littlelove.littlelove`). **Prod universal-link domain** is `littlelove.dev`.

---

## File Structure

**Created:**
- `app/lib/pairing/invite_link.dart` — pure helpers: `pairLink(code)` builds `https://littlelove.dev/pair/<code>`; `extractPairCode(uri)` parses a `/pair/<code>` URI back to a 4-word code (or null). Used by both the QR (Task 2) and deep-link handling (Task 7).
- `app/lib/screens/pair/pairing_screen.dart` — the single symmetric `PairingScreen`: your code (link + QR + 4 words, with copy/share) **and** an enter-their-code field that consumes directly. Replaces `show_invite.dart` + `enter_code.dart` + the three-door card.
- `app/lib/pairing/deep_link.dart` — `pendingPairCodeProvider` (a one-shot command, mirroring `requestedRoomProvider`) + `deepLinkBootstrapProvider` that subscribes to `app_links` and sets the command.
- `server/src/well_known.rs` — `apple_app_site_association` (AASA JSON) + `pair_landing` (`/pair/:token` web fallback) handlers.

**Modified:**
- `app/lib/wire/frames.dart` — add `CreateInviteFrame` (`kind: "CreateInvite"`, no fields).
- `app/lib/wire/live_pairing_transport.dart` — `createInvite()` sends `CreateInviteFrame`, resolves on `InviteCreatedFrame`; drop the dead `RoomCreated`-pending branch.
- `app/lib/pairing/qr.dart` — `InviteQr` encodes the **link**, not the raw code.
- `app/lib/screens/inbox/home_screen.dart` — `_emptyState()` renders `PairingScreen`; `[+]` always opens the channel sheet; deep-link bootstrap activated.
- `app/lib/conversation/room_message_router.dart` — drop the `pendingInvitesProvider` import + `set()` call.
- `app/pubspec.yaml` — add `app_links`.
- `app/ios/Runner/Runner.entitlements` — add `applinks:littlelove.dev`.
- `server/src/main.rs` + `server/src/lib.rs` + `server/tests/common/mod.rs` — register the two new routes.

**Deleted** (Task 4):
- `app/lib/inbox/pending_invites_provider.dart` (`PendingInvitesNotifier` + `DismissedInvitesNotifier`)
- `app/lib/screens/pair/show_invite.dart`
- `app/lib/screens/pair/enter_code.dart`
- `app/lib/screens/create_chat/create_chat_invite_screen.dart`
- `app/lib/screens/create_chat/create_chat_pick_screen.dart`
- `app/lib/screens/inbox/pair_card.dart`
- `app/lib/screens/inbox/new_chat_screen.dart`
- Dead tests: `app/test/pairing/invite_show_test.dart`, `app/test/pairing/invite_consume_widget_test.dart`, `app/test/pairing/inbox_shell_pair_wiring_test.dart`, `app/test/screens/create_chat_invite_widget_test.dart`

---

## Task 1: Client roomless invite — switch `createInvite()` to the `CreateInvite` frame

This is the linchpin. Today `createInvite()` sends `CreateRoom{invite_human_partner:true}`, which makes the server **mint a solo room** and return `RoomCreated{pending_invite}`. That solo room is what used to dump the user into an empty chat. The roomless `CreateInvite` frame + handler already exist server-side and are exercised by `server/tests/invites_consume.rs::full_pairing_flow_succeeds`. We only need the client to send the right frame.

**Files:**
- Modify: `app/lib/wire/frames.dart` (add `CreateInviteFrame` near `CreateRoomFrame`, ~line 425)
- Modify: `app/lib/wire/live_pairing_transport.dart:32-70`
- Test: `app/test/pairing/live_pairing_transport_test.dart` (update first test)

**Interfaces:**
- Produces: `CreateInviteFrame` with `Map<String,Object?> toJson() => {'kind': 'CreateInvite'}`.
- Consumes: existing `InviteCreatedFrame{code, qrPngBase64, expiresAt}` (already parsed in `frames.dart` `RoomServerFrame.fromJson` `case 'InviteCreated'`).

- [ ] **Step 1: Update the transport test to expect the roomless frame**

In `app/test/pairing/live_pairing_transport_test.dart`, replace the first test (currently named `'createInvite writes CreateRoom, returns InviteCreated from RoomCreated.pending_invite'`) with:

```dart
  test(
    'createInvite writes CreateInvite and resolves on InviteCreated',
    () async {
      final h = await _harness();
      addTearDown(h.conn.close);
      final transport = LivePairingTransport(h.conn);

      final fut = transport.createInvite();

      // The wire frame must be the roomless CreateInvite — never CreateRoom.
      final sent = jsonDecode(h.sink.writes.last) as Map<String, Object?>;
      expect(sent['kind'], 'CreateInvite');

      h.server.add(
        jsonEncode({
          'kind': 'InviteCreated',
          'code': 'abandon-pilot-react-zoo',
          'qr_png_base64': '',
          'expires_at': '2026-06-20T00:00:00Z',
        }),
      );

      final invite = await fut;
      expect(invite.code, 'abandon-pilot-react-zoo');
    },
  );
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd app && flutter test test/pairing/live_pairing_transport_test.dart -p vm`
Expected: FAIL — `sent['kind']` is `'CreateRoom'`, not `'CreateInvite'`.

- [ ] **Step 3: Add `CreateInviteFrame` to `frames.dart`**

In `app/lib/wire/frames.dart`, immediately above `class CreateRoomFrame` (~line 425) add:

```dart
/// Roomless invite request (spec §5.2 / Part B). Mints an invite with
/// `room_id = NULL` and creates **no** room; the couple room is created on the
/// server only when the partner consumes. Server replies with `InviteCreated`.
class CreateInviteFrame {
  const CreateInviteFrame();

  Map<String, Object?> toJson() => <String, Object?>{'kind': 'CreateInvite'};
}
```

- [ ] **Step 4: Switch the transport onto the roomless frame**

In `app/lib/wire/live_pairing_transport.dart`, replace the class doc comment (lines 9-20) and `createInvite()` (lines 32-38) and prune the now-dead `RoomCreated`-pending branch in `_onFrame` (lines 58-70).

Replace the doc comment with:

```dart
/// Multiplexed `PairingTransport` over a `LiveConnection`.
///
/// `createInvite()` issues a roomless `CreateInvite` frame and resolves on the
/// matching `InviteCreated` (the server creates no room until the partner
/// consumes — see spec Part B). `consumeInvite()` issues `ConsumeInvite` and
/// resolves on `InviteConsumed`.
///
/// FIFO queue per kind: the next matching frame resolves the head of the
/// queue. A `RoomError` resolves the oldest pending call (createInvite first,
/// then consumeInvite).
```

Replace `createInvite()` with:

```dart
  @override
  Future<InviteCreatedFrame> createInvite() {
    final c = Completer<InviteCreatedFrame>();
    _pendingCreate.add(c);
    _conn.send(const CreateInviteFrame().toJson());
    return c.future;
  }
```

In `_onFrame`, delete the entire `case RoomCreatedFrame(:final pendingInvite):` arm (lines 58-70) — `createInvite` no longer produces a `RoomCreated`, so this arm is dead. Add `RoomCreatedFrame()` to the trailing no-op `case` list so the switch stays exhaustive:

```dart
      case RoomsFrame() ||
          RoomCreatedFrame() ||
          RoomRenamedFrame() ||
          MemberLeftFrame() ||
          MessageFrame() ||
          ReadFrame() ||
          TypingFrame() ||
          UploadGrantedFrame() ||
          DownloadGrantedFrame():
        break;
```

(The `InviteCreatedFrame()` arm at lines 71-76 already resolves `_pendingCreate` — keep it; it is now the *primary* path, not forward-compat. Update its comment to: `// The server's InviteCreated resolves the pending createInvite().`)

- [ ] **Step 5: Run the transport test — expect PASS**

Run: `cd app && flutter test test/pairing/live_pairing_transport_test.dart -p vm`
Expected: PASS.

- [ ] **Step 6: Confirm the server's roomless flow still passes (no server change)**

Run: `cd server && DATABASE_URL="postgres://localhost/littlelove_test" cargo test --test invites_consume full_pairing_flow_succeeds`
Expected: PASS — proves `CreateInvite` mints a roomless invite and consume creates the couple room. (If `littlelove_test` does not exist, create it: `createdb littlelove_test && DATABASE_URL=postgres://localhost/littlelove_test sqlx migrate run --source server/migrations`.)

- [ ] **Step 7: Commit**

```bash
git add app/lib/wire/frames.dart app/lib/wire/live_pairing_transport.dart app/test/pairing/live_pairing_transport_test.dart
git commit -m "feat(pairing): client sends roomless CreateInvite (no solo room minted)"
```

---

## Task 2: Invite link + QR-over-link

The QR must encode the full universal link so the system camera opens the app. Extract a pure helper module so both the QR (here) and deep-link parsing (Task 7) share one definition of the link shape.

**Files:**
- Create: `app/lib/pairing/invite_link.dart`
- Modify: `app/lib/pairing/qr.dart`
- Test: `app/test/pairing/invite_link_test.dart` (create)

**Interfaces:**
- Produces: `String pairLink(String code)` → `https://littlelove.dev/pair/<code>`; `String? extractPairCode(Uri uri)` → the `<code>` segment when `uri.path` is `/pair/<code>`, else `null`.

- [ ] **Step 1: Write the failing test**

Create `app/test/pairing/invite_link_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/invite_link.dart';

void main() {
  test('pairLink builds the https universal link', () {
    expect(
      pairLink('abandon-pilot-react-zoo'),
      'https://littlelove.dev/pair/abandon-pilot-react-zoo',
    );
  });

  test('extractPairCode round-trips a pair link', () {
    final code = extractPairCode(
      Uri.parse('https://littlelove.dev/pair/abandon-pilot-react-zoo'),
    );
    expect(code, 'abandon-pilot-react-zoo');
  });

  test('extractPairCode returns null for a non-pair path', () {
    expect(extractPairCode(Uri.parse('https://littlelove.dev/health')), isNull);
    expect(extractPairCode(Uri.parse('https://littlelove.dev/pair/')), isNull);
  });
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd app && flutter test test/pairing/invite_link_test.dart`
Expected: FAIL — `invite_link.dart` does not exist.

- [ ] **Step 3: Implement `invite_link.dart`**

Create `app/lib/pairing/invite_link.dart`:

```dart
/// The universal-link form of an invite. One token, three forms (link, QR =
/// link, 4-word code); this module defines the link shape shared by QR
/// rendering and incoming deep-link parsing. Domain matches the iOS
/// `applinks:` entitlement and the Axum AASA `/pair/*` pattern.
const String pairLinkHost = 'littlelove.dev';

/// Build the shareable universal link for a 4-word invite [code].
String pairLink(String code) => 'https://$pairLinkHost/pair/$code';

/// Extract the 4-word code from an incoming `/pair/<code>` URI, or null if the
/// URI is not a pair link. Does not validate the code is a real BIP39 code —
/// the consume path does that.
String? extractPairCode(Uri uri) {
  final segs = uri.pathSegments;
  if (segs.length == 2 && segs[0] == 'pair' && segs[1].isNotEmpty) {
    return segs[1];
  }
  return null;
}
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `cd app && flutter test test/pairing/invite_link_test.dart`
Expected: PASS.

- [ ] **Step 5: Make the QR encode the link**

In `app/lib/pairing/qr.dart`, add the import and change `data: code` to `data: pairLink(code)`. Update the doc comment.

Replace the top of the file (imports + doc) with:

```dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'invite_link.dart';

/// Renders a QR code for an invite. The QR encodes the **universal link**
/// (`https://littlelove.dev/pair/<code>`), so scanning with the system camera
/// opens the app straight into the consume path — no in-app scanner needed.
class InviteQr extends StatelessWidget {
  const InviteQr({super.key, required this.code, this.size = 220});

  final String code;
  final double size;
```

Change the `QrImageView` argument from:

```dart
      child: QrImageView(
        data: code,
```

to:

```dart
      child: QrImageView(
        data: pairLink(code),
```

- [ ] **Step 6: Confirm the analyzer is clean**

Run: `cd app && flutter analyze lib/pairing/qr.dart lib/pairing/invite_link.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add app/lib/pairing/invite_link.dart app/lib/pairing/qr.dart app/test/pairing/invite_link_test.dart
git commit -m "feat(pairing): invite QR encodes the universal link; add invite_link helpers"
```

---

## Task 3: Single symmetric pairing screen

One screen shows **both** "Here's your code" (link + QR + 4 words, with copy/share) **and** "Enter your partner's code." Whoever enters the other's code first completes the handshake. The enter-code side consumes **directly** (no preview — preview 404s for roomless invites). On success the `InviteConsumed`/`RoomCreated` frame lands a room in the inbox, `HomeScreen` re-renders the list, and single-room auto-open drops the user into the chat.

**Files:**
- Create: `app/lib/screens/pair/pairing_screen.dart`
- Modify: `app/lib/screens/inbox/home_screen.dart` (`_emptyState()` body)
- Test: `app/test/screens/pair/pairing_screen_test.dart` (create)

**Interfaces:**
- Consumes: `pairingTransportProvider` (`PairingTransport`), `currentIdentityProvider` (`FutureProvider<DerivedIdentity>`), `createInvite(transport)` (`app/lib/pairing/invite_create.dart`), `consumeInvite({transport, identity, code})` (`app/lib/pairing/invite_consume.dart`), `decodeInviteCode(code)` (`app/lib/pairing/bip39_invite.dart`), `InviteQr(code:)`, `pairLink(code)`, `PairingTransportException`.
- Produces: `class PairingScreen extends ConsumerStatefulWidget` with `const PairingScreen({super.key, required this.selfUsername})`.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/screens/pair/pairing_screen_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/pair/pairing_screen.dart';
import 'package:littlelove/wire/frames.dart';

class _FakeTransport implements PairingTransport {
  String? consumedCode;
  @override
  Future<InviteCreatedFrame> createInvite() async => InviteCreatedFrame(
    code: 'abandon-pilot-react-zoo',
    qrPngBase64: '',
    expiresAt: DateTime.utc(2026, 6, 20),
  );
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async {
    consumedCode = code;
    return const InviteConsumedFrame(roomId: 'r1', name: '', members: []);
  }
}

Widget _app(_FakeTransport t) => ProviderScope(
  overrides: [
    pairingTransportProvider.overrideWithValue(t),
    // A throwaway identity so consume can sign without a keystore.
    currentIdentityProvider.overrideWith(
      (_) => deriveIdentity(Uint8List.fromList(List<int>.generate(16, (i) => i))),
    ),
  ],
  child: const MaterialApp(home: PairingScreen(selfUsername: 'court')),
);

void main() {
  testWidgets('shows your code, the link, and the QR', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_app(t));
    await tester.pumpAndSettle();
    expect(find.text('abandon-pilot-react-zoo'), findsOneWidget);
    expect(
      find.text('https://littlelove.dev/pair/abandon-pilot-react-zoo'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pairing-enter-field')), findsOneWidget);
  });

  testWidgets('entering a code drives consume', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_app(t));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pairing-enter-field')),
      'remote-circus-velvet-omega',
    );
    await tester.tap(find.byKey(const Key('pairing-join-button')));
    await tester.pumpAndSettle();
    expect(t.consumedCode, 'remote-circus-velvet-omega');
  });
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd app && flutter test test/screens/pair/pairing_screen_test.dart`
Expected: FAIL — `pairing_screen.dart` does not exist.

- [ ] **Step 3: Implement `PairingScreen`**

Create `app/lib/screens/pair/pairing_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/current_identity.dart';
import '../../pairing/bip39_invite.dart';
import '../../pairing/invite_consume.dart';
import '../../pairing/invite_create.dart';
import '../../pairing/invite_link.dart';
import '../../pairing/pairing_transport.dart';
import '../../pairing/qr.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';

/// The single symmetric pre-pairing surface. Shows your own roomless invite
/// (link + QR + 4 words) **and** a field to enter your partner's code. Whoever
/// enters the other's code first completes the handshake; the server creates
/// the couple room on consume and pushes it to both sides, at which point
/// HomeScreen leaves this empty state for the room list.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key, required this.selfUsername});

  final String selfUsername;

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  Future<InviteCreatedFrame>? _myInvite;
  final _enter = TextEditingController();
  String? _enterError;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _myInvite = createInvite(ref.read(pairingTransportProvider));
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _enter.text.trim();
    setState(() {
      _enterError = null;
      _joining = true;
    });
    try {
      decodeInviteCode(code); // local shape check before the round-trip
    } on InviteCodeException {
      setState(() {
        _enterError = 'That doesn\'t look like a 4-word code.';
        _joining = false;
      });
      return;
    }
    try {
      final identity = await ref.read(currentIdentityProvider.future);
      final transport = ref.read(pairingTransportProvider);
      await consumeInvite(transport: transport, identity: identity, code: code);
      // Success: the InviteConsumed/RoomCreated frame lands the room in the
      // inbox via RoomMessageRouter; HomeScreen rebuilds and (single-room
      // auto-open) pushes the chat. Nothing more to do here.
    } on PairingTransportException catch (e) {
      setState(() {
        _enterError = e.code == 'AlreadyPaired'
            ? 'You\'re already paired.'
            : 'Could not pair: ${e.message.isEmpty ? e.code : e.message}';
        _joining = false;
      });
    } catch (e) {
      setState(() {
        _enterError = 'Could not pair: $e';
        _joining = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'PAIR WITH YOUR PARTNER',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    letterSpacing: 2.4,
                    fontWeight: FontWeight.w500,
                    color: TwilightColors.accentSage,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Send them your code',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 26,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    color: TwilightColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                _MyInvite(future: _myInvite!),
                const SizedBox(height: 36),
                const Divider(color: TwilightColors.borderSoft),
                const SizedBox(height: 24),
                const Text(
                  '…or enter theirs',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: TwilightColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('pairing-enter-field'),
                  controller: _enter,
                  enabled: !_joining,
                  decoration: const InputDecoration(
                    labelText: 'four words separated by dashes',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('pairing-join-button'),
                  onPressed: _joining ? null : _join,
                  child: const Text('Join their chat'),
                ),
                if (_enterError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _enterError!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MyInvite extends StatelessWidget {
  const _MyInvite({required this.future});
  final Future<InviteCreatedFrame> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InviteCreatedFrame>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          final err = snap.error;
          final alreadyPaired =
              err is PairingTransportException && err.code == 'AlreadyPaired';
          return Text(
            alreadyPaired
                ? "You're already paired with a partner."
                : 'Could not create an invite: $err',
            style: const TextStyle(color: TwilightColors.textPrimary),
            textAlign: TextAlign.center,
          );
        }
        final invite = snap.data!;
        final link = pairLink(invite.code);
        return Column(
          children: [
            InviteQr(code: invite.code),
            const SizedBox(height: 18),
            SelectableText(
              invite.code,
              key: const Key('pairing-code-text'),
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: TwilightColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              link,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: TwilightColors.textMuted,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: invite.code)),
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('Copy code'),
                ),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: link)),
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Copy link'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 4: Run the widget test — expect PASS**

Run: `cd app && flutter test test/screens/pair/pairing_screen_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Render `PairingScreen` from `HomeScreen`'s empty state**

In `app/lib/screens/inbox/home_screen.dart`, add the import:

```dart
import '../pair/pairing_screen.dart';
```

In `_emptyState()`, replace the whole bespoke column (the `STEP 4 OF 4 · PAIR` / `Invite your partner` / lede / `PairCard(account: widget.account)` block) with a direct render of the symmetric screen — `PairingScreen` brings its own header and layout:

```dart
  Widget _emptyState() {
    return PairingScreen(selfUsername: _me);
  }
```

Remove the now-unused `import '../inbox/pair_card.dart'` (or wherever `PairCard` was imported) from `home_screen.dart`. Leave the `_body()` gating (`synced || connFailed`) untouched — the blank-canvas-before-sync behaviour still prevents the launch flash.

- [ ] **Step 6: Update the HomeScreen empty-state test for the new copy**

In `app/test/screens/inbox/home_screen_test.dart`, the empty-state tests assert `find.text('Invite your partner')`. `PairingScreen` reads `pairingTransportProvider` and `currentIdentityProvider` in `initState`, so those tests must override both (a perpetually-pending transport is enough; the screen shows its spinner). Update the two affected tests:

For `'empty inbox, once synced, shows the pairing affordance'`, change the assertion to the new header and add the overrides to `_container()` used by these tests. Add to the `_container()` overrides list:

```dart
      pairingTransportProvider.overrideWith((ref) {
        // Never resolves — PairingScreen shows its spinner; enough to assert
        // the empty state mounted the symmetric screen.
        throw UnimplementedError('not needed for this test');
      }),
```

Because `pairingTransportProvider` is read in `initState`, prefer overriding it with a fake that returns a never-completing `createInvite()`. Replace the override above with a small fake at the top of the test file:

```dart
class _PendingTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() => Completer<InviteCreatedFrame>().future;
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => Completer<InviteConsumedFrame>().future;
}
```

and override with `pairingTransportProvider.overrideWithValue(_PendingTransport())`. Then change the assertion from `expect(find.text('Invite your partner'), findsOneWidget);` to:

```dart
    expect(find.text('PAIR WITH YOUR PARTNER'), findsOneWidget);
```

(Add the needed imports to the test: `dart:typed_data`, `package:littlelove/pairing/pairing_transport.dart`. The `'no pairing flash'` test asserts `findsNothing` for the header text — update its string to `'PAIR WITH YOUR PARTNER'` too; it still passes because the blank canvas renders before sync.)

- [ ] **Step 7: Run the affected widget tests — expect PASS**

Run: `cd app && flutter test test/screens/inbox/home_screen_test.dart test/screens/pair/pairing_screen_test.dart`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/lib/screens/pair/pairing_screen.dart app/lib/screens/inbox/home_screen.dart app/test/screens/pair/pairing_screen_test.dart app/test/screens/inbox/home_screen_test.dart
git commit -m "feat(pairing): single symmetric PairingScreen as HomeScreen empty state"
```

---

## Task 4: Delete the three-door card, pending-invite plumbing, and pre-pairing channel screens (#16)

Now that the symmetric screen owns pre-pairing, remove the old surfaces. This also resolves #16 by construction: with no pre-consume room, there is no pending-invite *room* to mislabel, and `PendingInvitesNotifier` (the room-keyed map that rendered "Inviting partner…") is deleted.

**Files:**
- Delete: `app/lib/inbox/pending_invites_provider.dart`, `app/lib/screens/pair/show_invite.dart`, `app/lib/screens/pair/enter_code.dart`, `app/lib/screens/create_chat/create_chat_invite_screen.dart`, `app/lib/screens/create_chat/create_chat_pick_screen.dart`, `app/lib/screens/inbox/pair_card.dart`, `app/lib/screens/inbox/new_chat_screen.dart`
- Modify: `app/lib/conversation/room_message_router.dart`, `app/lib/screens/inbox/home_screen.dart`
- Delete tests: `app/test/pairing/invite_show_test.dart`, `app/test/pairing/invite_consume_widget_test.dart`, `app/test/pairing/inbox_shell_pair_wiring_test.dart`, `app/test/screens/create_chat_invite_widget_test.dart`

- [ ] **Step 1: Drop the pending-invite plumbing from the router**

In `app/lib/conversation/room_message_router.dart`:
- Remove the import `import '../inbox/pending_invites_provider.dart';` (line 8).
- In the `RoomCreatedFrame` case, remove the `pendingInvite` binding and the `if (pendingInvite != null) { ... }` block, leaving:

```dart
    case RoomCreatedFrame(:final roomId, :final name, :final members):
      _upsertRoom(roomId, name, members);
      _subscribe(roomId);
```

- [ ] **Step 2: Simplify HomeScreen `[+]` to channel-creation only**

After Part B, any room in the inbox implies a partner, so the `[+]` no longer needs the unpaired branch (the symmetric screen covers unpaired). In `home_screen.dart`, replace the `[+]` `onPressed` body:

```dart
            onPressed: () {
              if (_isPaired(inbox.rooms)) {
                showCreateChannelSheet(context, ref);
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewChatScreen(account: widget.account),
                  ),
                );
              }
            },
```

with:

```dart
            onPressed: () => showCreateChannelSheet(context, ref),
```

Remove the now-unused `import` of `new_chat_screen.dart` and the `_isPaired` helper if nothing else references it (`grep _isPaired` first — if unused, delete the method).

- [ ] **Step 3: Delete the dead source files**

```bash
git rm app/lib/inbox/pending_invites_provider.dart \
  app/lib/screens/pair/show_invite.dart \
  app/lib/screens/pair/enter_code.dart \
  app/lib/screens/create_chat/create_chat_invite_screen.dart \
  app/lib/screens/create_chat/create_chat_pick_screen.dart \
  app/lib/screens/inbox/pair_card.dart \
  app/lib/screens/inbox/new_chat_screen.dart
```

- [ ] **Step 4: Delete the dead tests**

```bash
git rm app/test/pairing/invite_show_test.dart \
  app/test/pairing/invite_consume_widget_test.dart \
  app/test/pairing/inbox_shell_pair_wiring_test.dart \
  app/test/screens/create_chat_invite_widget_test.dart
```

- [ ] **Step 5: Find and fix any remaining references**

Run: `cd app && grep -rln "pending_invites_provider\|pendingInvitesProvider\|DismissedInvites\|show_invite\|ShowInviteScreen\|enter_code\|openEnterCodeScreen\|create_chat_invite\|CreateChatInviteScreen\|create_chat_pick\|CreateChatPickScreen\|pair_card\|PairCard\|new_chat_screen\|NewChatScreen" lib test`
Expected: no matches. Fix any stragglers (e.g. leftover imports) until the grep is empty. (`enter_code.dart` was also imported by `create_chat_invite_screen.dart`, which is itself deleted — confirm no other importer remains.)

- [ ] **Step 6: Full analyze + test — expect clean**

Run: `cd app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test`
Expected: format clean, `No issues found!`, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(pairing): delete three-door card, pending-invite map (#16), pre-pairing channel screens"
```

---

## Task 5: Backend — serve AASA + `/pair/:token` web fallback

iOS only treats `littlelove.dev` links as universal links if `https://littlelove.dev/.well-known/apple-app-site-association` returns the app's `appID` and path pattern with `Content-Type: application/json`. Serve that plus a minimal landing page from Axum. Both GETs are inert (no consume without a signature).

**Files:**
- Create: `server/src/well_known.rs`
- Modify: `server/src/lib.rs` (add `pub mod well_known;`), `server/src/main.rs` (register routes), `server/tests/common/mod.rs` (register routes in `build_app`)
- Test: `server/tests/well_known.rs` (create)

**Interfaces:**
- Produces: `pub async fn apple_app_site_association() -> impl IntoResponse` (JSON, content-type `application/json`); `pub async fn pair_landing(Path(token): Path<String>) -> impl IntoResponse` (HTML).

- [ ] **Step 1: Write the failing integration test**

Create `server/tests/well_known.rs`:

```rust
mod common;
use common::spawn_server;

#[tokio::test]
async fn aasa_advertises_the_app_id_and_pair_path() {
    let addr = spawn_server(None).await;
    let resp = reqwest::Client::new()
        .get(format!("http://{addr}/.well-known/apple-app-site-association"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        resp.headers()["content-type"],
        "application/json",
        "AASA must be served as application/json"
    );
    let body: serde_json::Value = resp.json().await.unwrap();
    let details = &body["applinks"]["details"][0];
    assert_eq!(details["appIDs"][0], "9PVUX2535W.dev.littlelove.littlelove");
    assert_eq!(details["components"][0]["/"], "/pair/*");
}

#[tokio::test]
async fn pair_landing_serves_html() {
    let addr = spawn_server(None).await;
    let resp = reqwest::Client::new()
        .get(format!("http://{addr}/pair/abandon-pilot-react-zoo"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert!(resp.headers()["content-type"]
        .to_str()
        .unwrap()
        .starts_with("text/html"));
    let body = resp.text().await.unwrap();
    assert!(body.contains("LittleLove"));
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd server && DATABASE_URL="postgres://localhost/littlelove_test" cargo test --test well_known`
Expected: FAIL — routes 404 (`apple_app_site_association` / `pair_landing` don't exist; `well_known.rs` missing). (These tests pass `None` for the store, so they don't touch the DB, but `DATABASE_URL` must still be set for the crate to build its test harness.)

- [ ] **Step 3: Implement the handlers**

Create `server/src/well_known.rs`:

```rust
//! Universal-link support served by the API (spec Part B, §B4). iOS fetches
//! the AASA to learn this app claims `littlelove.dev/pair/*`; the landing page
//! is the web fallback when the app isn't installed. Both GETs are inert — a
//! consume requires the app's Ed25519 signature, which a browser GET can't
//! produce.

use axum::extract::Path;
use axum::http::header;
use axum::response::{Html, IntoResponse};

/// `<TeamID>.<bundleID>` for the iOS app.
const APP_ID: &str = "9PVUX2535W.dev.littlelove.littlelove";

/// Serve `.well-known/apple-app-site-association` as `application/json` (no
/// file extension, exact content-type — iOS is strict about both).
pub async fn apple_app_site_association() -> impl IntoResponse {
    let body = serde_json::json!({
        "applinks": {
            "details": [
                {
                    "appIDs": [APP_ID],
                    "components": [
                        { "/": "/pair/*", "comment": "partner pairing links" }
                    ]
                }
            ]
        }
    });
    (
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
}

/// Minimal web fallback for `/pair/:token`. Shown only when the app isn't
/// installed to intercept the universal link. The token is not consumed here.
pub async fn pair_landing(Path(_token): Path<String>) -> impl IntoResponse {
    Html(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<title>Open in LittleLove</title></head>\
<body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:48px\">\
<h1>LittleLove</h1>\
<p>Open this invite in the LittleLove app.</p>\
<p>Don't have it yet? Install LittleLove, then tap the link again.</p>\
</body></html>",
    )
}
```

- [ ] **Step 4: Register the module and routes**

In `server/src/lib.rs`, add (keep modules alphabetical-ish, after `wire` is fine):

```rust
pub mod well_known;
```

In `server/src/main.rs`, add the two routes to the `Router` (after the `/invites/:code/preview` route, before `/ws`):

```rust
        .route(
            "/.well-known/apple-app-site-association",
            get(littlelove_api::well_known::apple_app_site_association),
        )
        .route(
            "/pair/:token",
            get(littlelove_api::well_known::pair_landing),
        )
```

In `server/tests/common/mod.rs`, add the same two routes to `build_app`'s `Router` (and add `use littlelove_api::well_known::{apple_app_site_association, pair_landing};` to the imports, matching the file's existing import style), so the test harness serves them:

```rust
        .route(
            "/.well-known/apple-app-site-association",
            get(apple_app_site_association),
        )
        .route("/pair/:token", get(pair_landing))
```

- [ ] **Step 5: Run the test — expect PASS**

Run: `cd server && DATABASE_URL="postgres://localhost/littlelove_test" cargo test --test well_known`
Expected: PASS (both tests).

- [ ] **Step 6: Lint the server**

Run: `cd server && cargo fmt --all && cargo clippy --all-targets -- -D warnings`
Expected: formatted, no clippy warnings.

- [ ] **Step 7: Commit**

```bash
git add server/src/well_known.rs server/src/lib.rs server/src/main.rs server/tests/common/mod.rs server/tests/well_known.rs
git commit -m "feat(server): serve AASA + /pair/:token web fallback for universal links"
```

---

## Task 6: iOS — Associated Domains entitlement

Add `applinks:littlelove.dev` so iOS routes matching links into the app. No automated test — verified on device.

**Files:**
- Modify: `app/ios/Runner/Runner.entitlements`

- [ ] **Step 1: Add the entitlement**

In `app/ios/Runner/Runner.entitlements`, add the `com.apple.developer.associated-domains` key alongside the existing APNs + app-groups keys, so the file reads:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.dev.littlelove.littlelove</string>
	</array>
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>applinks:littlelove.dev</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Confirm the project still builds the entitlement reference**

This is a plist-only change; there is no unit test. Confirm the file is well-formed:

Run: `plutil -lint app/ios/Runner/Runner.entitlements`
Expected: `app/ios/Runner/Runner.entitlements: OK`

- [ ] **Step 3: Commit**

```bash
git add app/ios/Runner/Runner.entitlements
git commit -m "feat(ios): add applinks:littlelove.dev Associated Domains entitlement"
```

> **Device-verification note (not a code step):** Associated Domains only activate against the live AASA. Verify after Task 5 is deployed to prod `littlelove.dev` by installing via `./scripts/ios-deploy.sh --server <url>` to both physical phones (one at a time) and tapping a `https://littlelove.dev/pair/<code>` link.

---

## Task 7: App — deep-link handling via `app_links`

Funnel an incoming `https://littlelove.dev/pair/<token>` (cold start + warm) into the symmetric screen's consume path. Mirror the existing `requestedRoomProvider` one-shot-command pattern with a `pendingPairCodeProvider`; `PairingScreen` listens and prefills + consumes. Already-paired is a graceful no-op (consume returns `AlreadyPaired`, which the screen already surfaces).

**Files:**
- Modify: `app/pubspec.yaml` (add `app_links`)
- Create: `app/lib/pairing/deep_link.dart`
- Modify: `app/lib/screens/inbox/home_screen.dart` (activate bootstrap), `app/lib/screens/pair/pairing_screen.dart` (listen for the pending code)
- Test: `app/test/pairing/deep_link_test.dart` (create — pure parsing/command, no platform channel)

**Interfaces:**
- Produces: `pendingPairCodeProvider` (`StateProvider<String?>`); `deepLinkBootstrapProvider` (`Provider` that subscribes to `app_links` and sets the command via `extractPairCode`).

- [ ] **Step 1: Add the dependency**

In `app/pubspec.yaml`, under `dependencies:` (after `url_launcher`), add:

```yaml
  app_links: ^6.3.0
```

Run: `cd app && flutter pub get`
Expected: resolves and adds `app_links` to the lockfile.

- [ ] **Step 2: Write the failing test (the command + handler, not the platform stream)**

Create `app/test/pairing/deep_link_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/deep_link.dart';
import 'package:littlelove/pairing/invite_link.dart';

void main() {
  test('handlePairUri sets the pending code for a /pair link', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    handlePairUri(c, Uri.parse(pairLink('abandon-pilot-react-zoo')));
    expect(c.read(pendingPairCodeProvider), 'abandon-pilot-react-zoo');
  });

  test('handlePairUri ignores non-pair links', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    handlePairUri(c, Uri.parse('https://littlelove.dev/health'));
    expect(c.read(pendingPairCodeProvider), isNull);
  });
}
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `cd app && flutter test test/pairing/deep_link_test.dart`
Expected: FAIL — `deep_link.dart` does not exist.

- [ ] **Step 4: Implement `deep_link.dart`**

Create `app/lib/pairing/deep_link.dart`:

```dart
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_link.dart';

/// One-shot "a pair link arrived" command. [PairingScreen] listens, prefills
/// the enter-code field, consumes, and resets this to null. Mirrors
/// `requestedRoomProvider`: a value here is a command, not retained state.
final pendingPairCodeProvider = StateProvider<String?>((ref) => null);

/// Pure handler: if [uri] is a `/pair/<code>` link, stash the code as the
/// pending command. Split out from the platform stream so it's unit-testable.
void handlePairUri(Ref ref, Uri uri) {
  final code = extractPairCode(uri);
  if (code != null) {
    ref.read(pendingPairCodeProvider.notifier).state = code;
  }
}

/// Subscribes to `app_links` for the lifetime of the signed-in session: the
/// cold-start initial link and every warm link while running. Activated by
/// HomeScreen via `ref.watch`. Tolerant of platform errors (e.g. tests /
/// unsupported platforms) — it simply never fires there.
final deepLinkBootstrapProvider = Provider<void>((ref) {
  final appLinks = AppLinks();
  unawaited(
    appLinks.getInitialLink().then((uri) {
      if (uri != null) handlePairUri(ref, uri);
    }).catchError((_) {}),
  );
  final sub = appLinks.uriLinkStream.listen(
    (uri) => handlePairUri(ref, uri),
    onError: (_) {},
  );
  ref.onDispose(sub.cancel);
});
```

Note: `Ref` (not `WidgetRef`) is the parameter type, so `handlePairUri` works with a bare `ProviderContainer` in tests and with the provider's `ref` in production.

- [ ] **Step 5: Run the test — expect PASS**

Run: `cd app && flutter test test/pairing/deep_link_test.dart`
Expected: PASS.

- [ ] **Step 6: Activate the bootstrap and consume the command in `PairingScreen`**

In `app/lib/screens/inbox/home_screen.dart` `build()`, alongside the other session-lifetime watches (inside or just after the `liveConnection.whenData` block), add:

```dart
    ref.watch(deepLinkBootstrapProvider);
```

and add the import `import '../../pairing/deep_link.dart';`.

In `app/lib/screens/pair/pairing_screen.dart`, consume the pending code. Add the import:

```dart
import '../../pairing/deep_link.dart';
```

In `_PairingScreenState.build()`, before `return Center(`, add a listener that prefills and auto-joins when a deep link arrives:

```dart
    ref.listen<String?>(pendingPairCodeProvider, (_, code) {
      if (code == null) return;
      // Reset the one-shot command after this frame (Riverpod forbids mutating
      // a provider inside a listener that runs during build).
      Future.microtask(
        () => ref.read(pendingPairCodeProvider.notifier).state = null,
      );
      if (_joining) return;
      _enter.text = code;
      _join();
    });
```

Also handle a code that arrived *before* the screen mounted (cold start): in `initState`, after `_myInvite = ...`, add a post-frame check:

```dart
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ref.read(pendingPairCodeProvider);
      if (pending != null && mounted && !_joining) {
        ref.read(pendingPairCodeProvider.notifier).state = null;
        _enter.text = pending;
        _join();
      }
    });
```

(Add `import 'package:flutter/scheduler.dart';` only if `WidgetsBinding` isn't already resolved via `material.dart` — it is, so no extra import needed.)

- [ ] **Step 7: Full app analyze + test — expect clean**

Run: `cd app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test`
Expected: format clean, `No issues found!`, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/pairing/deep_link.dart app/lib/screens/inbox/home_screen.dart app/lib/screens/pair/pairing_screen.dart app/test/pairing/deep_link_test.dart
git commit -m "feat(pairing): app_links deep-link handling → symmetric screen consume path"
```

---

## Final verification (before finishing the branch)

- [ ] **Full CI lint, both stacks:**

```bash
cd server && cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && DATABASE_URL="postgres://localhost/littlelove_test" cargo test
cd ../app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test
```

Expected: everything green.

- [ ] **On-device smoke test** (after deploying the AASA to prod `littlelove.dev`): build to **both** physical phones one at a time via `./scripts/ios-deploy.sh --server <url> --device <udid>`; on a fresh pair of accounts confirm: (a) creating an invite shows the symmetric screen with code + QR + link and does **not** drop you into an empty chat; (b) entering the partner's code pairs and auto-opens the chat on both sides; (c) no "Inviting partner…" ever appears; (d) tapping a `https://littlelove.dev/pair/<code>` iMessage link opens the app into the consume path.

- [ ] **Finish the branch:** Announce and use **superpowers:finishing-a-development-branch** to verify tests, present options, and execute the chosen completion path. This branch carries Part A (nav) + the manual-test fixes + logout + Part B (pairing) together.

---

## Self-Review

**Spec coverage** (against `2026-06-19-pairing-nav-redesign-design.md` Part B, steps 9-14):
- B1 roomless invite (step 9) → Task 1 (client switch; server already done + tested — noted as a deviation from the spec's assumption that the backend needed building).
- B2 symmetric screen (step 10) → Task 3; collapse of `show_invite.dart`/`enter_code.dart` + delete `PendingInvitesNotifier` + "Inviting partner…" (#16) → Task 4.
- B3 invite transport, QR-over-link (within step 10) → Task 2.
- Step 11 (channel creation post-pairing only) → Task 4 Step 2.
- B4 AASA + `/pair/:token` (step 12) → Task 5.
- B5 iOS entitlement (step 13) → Task 6.
- B6 `app_links` deep-link (step 14) → Task 7.

**Deviation from spec, flagged:** the spec's step 9 ("new frame + handler branch") is unnecessary — `RoomClientFrame::CreateInvite` + `handle_create_invite` (roomless, `room_id NULL`) and the `room_id IS NULL` consume branch already exist (`server/src/ws.rs:206,310,338`; `server/tests/invites_consume.rs`). Task 1 is therefore a client-only change; Task 1 Step 6 just re-confirms the existing server test. This is the single biggest scope reduction versus the spec.

**Type consistency:** `pairLink(String)`/`extractPairCode(Uri)` are defined in Task 2 and reused verbatim in Tasks 3 and 7. `pendingPairCodeProvider` (`StateProvider<String?>`) and `handlePairUri(Ref, Uri)` defined in Task 7 and used in its own steps. `PairingScreen({required selfUsername})` defined in Task 3 and rendered by `HomeScreen` (`_me`). `CreateInviteFrame().toJson()` defined in Task 1, sent by the transport in the same task. `InviteCreatedFrame{code, qrPngBase64, expiresAt}` / `InviteConsumedFrame{roomId, name, members}` / `PairingTransportException{code, message}` referenced consistently with their existing definitions.

**Placeholder scan:** no TBD/TODO; every code step shows full code; every run step states the expected result.
