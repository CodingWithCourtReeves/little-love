import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/hold_until_ready.dart';

void main() {
  test('holds items until ready, then delivers them in order', () async {
    final got = <int>[];
    final hold = HoldUntilReady<int>((i) async => got.add(i));
    await hold.add(1);
    await hold.add(2);
    expect(got, isEmpty);
    await hold.ready();
    expect(got, [1, 2]);
  });

  test('delivers straight through once ready', () async {
    final got = <int>[];
    final hold = HoldUntilReady<int>((i) async => got.add(i));
    await hold.ready();
    await hold.add(3);
    expect(got, [3]);
  });

  test('ready twice does not redeliver', () async {
    final got = <int>[];
    final hold = HoldUntilReady<int>((i) async => got.add(i));
    await hold.add(1);
    await hold.ready();
    await hold.ready();
    expect(got, [1]);
  });

  test('a failing delivery does not stop the rest', () async {
    final got = <int>[];
    final hold = HoldUntilReady<int>((i) async {
      if (i == 1) throw StateError('bad candidate');
      got.add(i);
    });
    await hold.add(1);
    await hold.add(2);
    await hold.ready();
    expect(got, [2]);
  });
}
