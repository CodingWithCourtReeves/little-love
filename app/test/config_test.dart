import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/config.dart';

void main() {
  group('AppConfig.parse', () {
    test('parses required fields', () {
      const toml = '''
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:7707/ws"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
''';
      final cfg = AppConfig.parse(toml);
      expect(cfg.username, 'court');
      expect(cfg.displayName, 'Court');
      expect(cfg.serverUrl, 'ws://127.0.0.1:7707/ws');
      expect(cfg.contactUsername, 'kaitlyn');
      expect(cfg.contactDisplayName, 'Kaitlyn');
      expect(cfg.sharedKeyHex, isNull);
    });

    test('parses optional shared_key for Day-1c', () {
      const toml = '''
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:7707/ws"
shared_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
''';
      final cfg = AppConfig.parse(toml);
      expect(cfg.sharedKeyHex, isNotNull);
      expect(cfg.sharedKeyHex!.length, 64);
    });

    test('throws on missing username', () {
      const toml = '''
display_name = "Court"
server_url = "ws://x/ws"

[contact]
username = "k"
display_name = "K"
''';
      expect(() => AppConfig.parse(toml), throwsA(isA<FormatException>()));
    });
  });
}
