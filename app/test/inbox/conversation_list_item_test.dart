import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/status_marker.dart';
import 'package:littlelove/inbox/conversation_list_item.dart';
import 'package:littlelove/inbox/room_preview.dart';
import 'package:littlelove/theme/app_palette.dart';

// Thursday, Oct 29 2026, 9:41 PM local.
final _now = DateTime(2026, 10, 29, 21, 41);

Widget _host(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: buildAppTheme(AppPalette.light),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: Column(children: [child])),
  ),
);

ConversationListItem _row(
  RoomPreview preview, {
  Key key = const Key('row'),
  String label = 'Kaitlyn',
  VoidCallback? onTap,
}) => ConversationListItem(
  key: key,
  label: label,
  preview: preview,
  now: _now,
  onTap: onTap ?? () {},
);

/// The preview line as plain text (an icon shows up as U+FFFC).
String _previewText(WidgetTester tester, {Key row = const Key('row')}) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(row),
        matching: find.byKey(const Key('row-preview')),
      ),
    )
    .textSpan!
    .toPlainText();

void main() {
  testWidgets('tap fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(_row(const RoomPreview(), onTap: () => tapped = true)),
    );
    await tester.tap(find.byKey(const Key('row')));
    expect(tapped, isTrue);
  });

  testWidgets('tap target is at least 44x44', (tester) async {
    await tester.pumpWidget(_host(_row(const RoomPreview(), label: 'K')));
    final size = tester.getSize(find.byKey(const Key('row')));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('a short and a long preview make rows of the same height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: Scaffold(
          body: Column(
            children: [
              _row(const RoomPreview(text: 'hi'), key: const Key('short')),
              _row(
                RoomPreview(text: 'Running ten minutes late. ' * 8),
                key: const Key('long'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('short'))).height,
      tester.getSize(find.byKey(const Key('long'))).height,
    );
    final long = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('long')),
        matching: find.byKey(const Key('row-preview')),
      ),
    );
    expect(long.maxLines, 2);
    expect(long.overflow, TextOverflow.ellipsis);
  });

  testWidgets('larger system text grows the row without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _row(
          RoomPreview(
            text: 'Found a place in Alfama with a rooftop terrace. ' * 3,
            at: DateTime(2026, 10, 29, 21, 38),
            unread: 12,
          ),
          label: 'wedding-guest-list-and-seating-chart-for-june',
        ),
        textScale: 1.6,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('row'))).height,
      greaterThan(76),
    );
  });

  testWidgets("today's message shows the clock time; older ones the day", (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_row(RoomPreview(text: 'hi', at: DateTime(2026, 10, 29, 21, 38)))),
    );
    expect(find.text('9:38 PM'), findsOneWidget);

    await tester.pumpWidget(
      _host(_row(RoomPreview(text: 'hi', at: DateTime(2026, 10, 28, 9)))),
    );
    expect(find.text('Yesterday'), findsOneWidget);
  });

  testWidgets('no time is shown for a room with no messages', (tester) async {
    await tester.pumpWidget(
      _host(
        _row(
          const RoomPreview(
            text: 'No messages yet',
            tone: PreviewTone.placeholder,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('row-time')), findsNothing);
  });

  testWidgets('unread shows a count, capped at 99+', (tester) async {
    await tester.pumpWidget(
      _host(_row(const RoomPreview(text: 'x', unread: 3))),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('unread-count')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _host(_row(const RoomPreview(text: 'x', unread: 140))),
    );
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('a read room shows no count', (tester) async {
    await tester.pumpWidget(_host(_row(const RoomPreview(text: 'x'))));
    expect(find.byKey(const Key('unread-count')), findsNothing);
  });

  testWidgets('my latest message shows "You: " and its delivery mark', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _row(
          RoomPreview(
            text: 'Booked it',
            fromMe: true,
            mark: StatusMark.read,
            at: DateTime(2026, 10, 29, 20, 15),
          ),
        ),
      ),
    );
    expect(_previewText(tester), 'You: Booked it');
    expect(find.byKey(const Key('status-double-heart')), findsOneWidget);
  });

  testWidgets('a failed send shows the not-sent mark', (tester) async {
    await tester.pumpWidget(
      _host(
        _row(
          RoomPreview(
            text: 'move it to 8?',
            fromMe: true,
            failed: true,
            at: DateTime(2026, 10, 29, 20, 51),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('row-send-failed')), findsOneWidget);
    expect(find.byType(StatusMarker), findsNothing);
  });

  testWidgets('a draft is labelled "Draft: "', (tester) async {
    await tester.pumpWidget(
      _host(_row(const RoomPreview(text: 'oat milk', isDraft: true))),
    );
    expect(_previewText(tester), 'Draft: oat milk');
  });

  testWidgets('a photo preview leads with a camera glyph', (tester) async {
    await tester.pumpWidget(
      _host(_row(const RoomPreview(text: 'Photo', icon: PreviewIcon.photo))),
    );
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    expect(_previewText(tester), endsWith('Photo'));
  });
}
