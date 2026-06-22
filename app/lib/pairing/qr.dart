import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'invite_link.dart';

/// Renders a QR code for an invite. The QR encodes the **universal link**
/// (`https://littlelove.dev/pair/<code>`), so scanning with the system camera
/// opens the app straight into the consume path — no in-app scanner needed.
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
        data: pairLink(code),
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
