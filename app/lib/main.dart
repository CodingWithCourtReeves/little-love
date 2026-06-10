import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'inbox/mock_fixtures.dart';
import 'screens/auth/auth_gate.dart';
import 'theme/twilight.dart';

const _fixtures = String.fromEnvironment('LLOVE_FIXTURES', defaultValue: '');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  if (_fixtures == 'demo') {
    seedDemoFixtures(container);
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LittleLoveApp(),
    ),
  );
}

class LittleLoveApp extends StatelessWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LittleLove',
      theme: buildTwilightTheme(),
      home: const AuthGate(),
    );
  }
}
