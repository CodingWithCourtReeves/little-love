import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/auth/auth_gate.dart';
import 'theme/twilight.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: LittleLoveApp()));
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
