import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'attachment_descriptor.dart';

/// Full-screen viewer for a decrypted attachment file. Image → InteractiveViewer;
/// video → video_player. [file] is the decrypted plaintext on local disk.
class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({super.key, required this.file, required this.descriptor});
  final File file;
  final AttachmentDescriptor descriptor;
  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.descriptor.isVideo) {
      _video = VideoPlayerController.file(widget.file)
        ..initialize().then((_) {
          if (mounted) setState(() => _video!..play());
        });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      backgroundColor: const Color(0xFF140C12),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(widget.descriptor.filename, style: const TextStyle(fontSize: 13)),
      ),
      body: Center(
        child: widget.descriptor.isVideo
            ? (v != null && v.value.isInitialized
                ? GestureDetector(
                    onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
                    child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
                  )
                : const CircularProgressIndicator())
            : InteractiveViewer(child: Image.file(widget.file)),
      ),
    );
  }
}
