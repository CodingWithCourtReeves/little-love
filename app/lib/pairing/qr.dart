import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Renders a QR code for an invite. The code string is the canonical payload
/// per spec §4.3 — no JSON, no URL scheme. White background / dark foreground
/// kept simple; theme integration can come later without breaking callers.
class InviteQr extends StatelessWidget {
  const InviteQr({super.key, required this.code, this.size = 220});

  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(8),
      child: QrImageView(
        data: code,
        version: QrVersions.auto,
        size: size,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ),
    );
  }
}
