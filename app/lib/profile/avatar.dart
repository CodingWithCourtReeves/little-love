import 'dart:io';
import 'package:flutter/material.dart';

/// Circular avatar: shows [imageFile] when present and readable, else the first
/// letter of [seedText] on a deterministic accent color. Used for self + partner.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.seedText,
    this.imageFile,
    this.radius = 20,
  });

  final String seedText;
  final File? imageFile;
  final double radius;

  static const _accents = <Color>[
    Color(0xFFE57373),
    Color(0xFF9575CD),
    Color(0xFF4DB6AC),
    Color(0xFF7986CB),
    Color(0xFFA1887F),
    Color(0xFF4FC3F7),
  ];

  Color _color() {
    if (seedText.isEmpty) return _accents.first;
    var h = 0;
    for (final c in seedText.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _accents[h % _accents.length];
  }

  @override
  Widget build(BuildContext context) {
    final file = imageFile;
    if (file != null && file.existsSync()) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
    }
    final initial = seedText.isEmpty ? '?' : seedText[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: _color(),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
