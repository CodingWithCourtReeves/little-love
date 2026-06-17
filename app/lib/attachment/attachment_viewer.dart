import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
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
  String? _error;
  bool _saving = false;

  Future<void> _saveToGallery() async {
    setState(() => _saving = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        await Gal.requestAccess(toAlbum: true);
      }
      if (widget.descriptor.isVideo) {
        await Gal.putVideo(widget.file.path);
      } else {
        await Gal.putImage(widget.file.path);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to Photos')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.descriptor.isVideo) {
      _video = VideoPlayerController.file(widget.file)
        ..initialize().then((_) {
          if (mounted) setState(() => _video!..play());
        }).catchError((Object e) {
          // Don't spin forever if AVFoundation can't open the file.
          if (mounted) setState(() => _error = '$e');
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
        actions: [
          IconButton(
            tooltip: 'Save to Photos',
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_rounded),
            onPressed: _saving ? null : _saveToGallery,
          ),
        ],
      ),
      body: Center(
        child: widget.descriptor.isVideo
            ? (_error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "Can't play this video.\n$_error",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  )
                : (v != null && v.value.isInitialized
                    ? _videoView(v)
                    : const CircularProgressIndicator()))
            : InteractiveViewer(child: Image.file(widget.file)),
      ),
    );
  }

  /// Video surface plus controls: tap to play/pause, a centered play badge when
  /// paused, and a bottom bar with a play/pause button, a scrubbable progress
  /// slider, and elapsed/total time. `video_player`'s `VideoPlayer` is only the
  /// raw surface, so the controls are built here.
  Widget _videoView(VideoPlayerController v) {
    return Stack(
      alignment: Alignment.center,
      children: [
        GestureDetector(
          onTap: () => setState(() => v.value.isPlaying ? v.pause() : _resumeOrRestart(v)),
          child: Center(
            child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
          ),
        ),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: v,
          builder: (_, val, _) => IgnorePointer(
            child: AnimatedOpacity(
              opacity: val.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 180),
              child: Container(
                width: 66,
                height: 66,
                decoration: const BoxDecoration(
                  color: Color(0x66000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0xB3000000)],
              ),
            ),
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: v,
              builder: (_, val, _) => Row(
                children: [
                  IconButton(
                    icon: Icon(val.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white),
                    onPressed: () =>
                        setState(() => val.isPlaying ? v.pause() : _resumeOrRestart(v)),
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      v,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Color(0x55FFFFFF),
                        backgroundColor: Color(0x33FFFFFF),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${_fmt(val.position)} / ${_fmt(val.duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Tapping play after the clip ended should restart from the beginning.
  void _resumeOrRestart(VideoPlayerController v) {
    if (v.value.position >= v.value.duration) {
      v.seekTo(Duration.zero);
    }
    v.play();
  }

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }
}
