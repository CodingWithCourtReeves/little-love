import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  test('Msg.fromJson parses a server frame', () {
    final json = {
      'type': 'msg',
      'id': '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      'from': 'court',
      'to': 'kaitlyn',
      'body': 'hey',
      'ts': '2026-06-09T17:00:00Z',
    };
    final m = Msg.fromJson(json);
    expect(m.from, 'court');
    expect(m.to, 'kaitlyn');
    expect(m.body, 'hey');
    expect(m.replayed, false);
  });

  test('Msg.fromJson parses replayed=true', () {
    final json = {
      'type': 'msg',
      'id': '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      'from': 'court',
      'to': 'kaitlyn',
      'body': 'old',
      'ts': '2026-06-08T17:00:00Z',
      'replayed': true,
    };
    final m = Msg.fromJson(json);
    expect(m.replayed, true);
  });

  test('Msg.toJson elides replayed when false', () {
    final m = Msg(
      id: '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      from: 'court',
      to: 'kaitlyn',
      body: 'hi',
      ts: DateTime.utc(2026, 6, 9, 17),
      replayed: false,
    );
    final j = m.toJson();
    expect(j.containsKey('replayed'), false);
    expect(j['type'], 'msg');
  });
}
