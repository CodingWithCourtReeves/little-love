import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/conversation_list_item.dart';
import 'package:littlelove/theme/twilight.dart';

void main() {
  testWidgets('tap fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: Scaffold(
          body: ConversationListItem(
            key: const Key('item-1'),
            label: 'Kaitlyn',
            selected: false,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('item-1')));
    expect(tapped, isTrue);
  });

  testWidgets('tap target is at least 44x44', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: Scaffold(
          body: ConversationListItem(
            key: const Key('item-1'),
            label: 'K',
            selected: false,
            onTap: () {},
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byKey(const Key('item-1')));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('selected variant has a distinct background', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: Scaffold(
          body: Column(
            children: [
              ConversationListItem(
                key: const Key('item-unsel'),
                label: 'Kaitlyn',
                selected: false,
                onTap: () {},
              ),
              ConversationListItem(
                key: const Key('item-sel'),
                label: 'Kaitlyn',
                selected: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    final unselDecoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(const Key('item-unsel')),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration?;
    final selDecoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(const Key('item-sel')),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration?;
    expect(unselDecoration?.color, isNot(equals(selDecoration?.color)));
  });
}
