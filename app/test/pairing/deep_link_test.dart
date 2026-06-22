import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/deep_link.dart';
import 'package:littlelove/pairing/invite_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('handlePairUri sets the pending code for a /pair link', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    handlePairUri(
      Uri.parse(pairLink('abandon-pilot-react-zoo')),
      (code) => c.read(pendingPairCodeProvider.notifier).state = code,
    );
    expect(c.read(pendingPairCodeProvider), 'abandon-pilot-react-zoo');
  });

  test('handlePairUri ignores non-pair links', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    handlePairUri(
      Uri.parse('https://littlelove.dev/health'),
      (code) => c.read(pendingPairCodeProvider.notifier).state = code,
    );
    expect(c.read(pendingPairCodeProvider), isNull);
  });
}
