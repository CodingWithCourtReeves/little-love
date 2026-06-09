import 'package:flutter/material.dart';

void main() {
  runApp(const LittleLoveApp());
}

class LittleLoveApp extends StatelessWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'LittleLove',
      home: Scaffold(
        body: Center(child: Text('LittleLove — bootstrapping')),
      ),
    );
  }
}
