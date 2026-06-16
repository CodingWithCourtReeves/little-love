import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/inbox/channel_switcher.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u, {bool bot = false, String? owner}) => Member(
  username: u,
  ed25519PubBase64: '',
  x25519PubBase64: '',
  isBot: bot,
  ownerUsername: owner,
);

Room room(String id, List<Member> members, {String name = ''}) => Room(
  roomId: id,
  name: name,
  members: members,
  createdAt: DateTime.utc(2026, 6, 14),
);

Widget harness({required List<Room> rooms, String? selected}) {
  return ProviderScope(
    child: MaterialApp(
      home: _HarnessHome(rooms: rooms, selected: selected),
    ),
  );
}

class _HarnessHome extends ConsumerStatefulWidget {
  const _HarnessHome({required this.rooms, this.selected});
  final List<Room> rooms;
  final String? selected;

  @override
  ConsumerState<_HarnessHome> createState() => _HarnessHomeState();
}

class _HarnessHomeState extends ConsumerState<_HarnessHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(inboxStateProvider.notifier).setRooms(widget.rooms);
      if (widget.selected != null) {
        ref.read(inboxStateProvider.notifier).select(widget.selected!);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: ChannelSwitcher(selfUsername: 'court'));
}

void main() {
  testWidgets('pill shows partner name when partner room selected', (t) async {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    await t.pumpWidget(harness(rooms: [partner], selected: 'p'));
    await t.pump();
    expect(find.text('Kaitlyn'), findsOneWidget);
  });

  testWidgets('tapping pill opens dropdown listing channels', (t) async {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    final chan = room('c', [m('court'), m('kaitlyn')], name: 'date-ideas');
    await t.pumpWidget(harness(rooms: [partner, chan], selected: 'p'));
    await t.pump();
    await t.tap(find.byKey(const Key('channel-switcher-pill')));
    await t.pumpAndSettle();
    expect(find.text('date-ideas'), findsOneWidget);
    expect(find.byKey(const Key('switcher-new-channel')), findsOneWidget);
  });
}
