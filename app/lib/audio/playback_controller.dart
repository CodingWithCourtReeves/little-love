import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_download.dart';
import '../wire/live_connection.dart';

/// Player seam so the controller is unit-testable without audio hardware.
abstract class PlayerBackend {
  Future<void> setFilePath(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setSpeed(double s);
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;

  /// Emits once each time playback reaches the end of the clip.
  Stream<void> get onCompleted;
  Future<void> dispose();
}

class JustAudioBackend implements PlayerBackend {
  final AudioPlayer _p = AudioPlayer();
  @override
  Future<void> setFilePath(String path) => _p.setFilePath(path);
  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration to) => _p.seek(to);
  @override
  Future<void> setSpeed(double s) => _p.setSpeed(s);
  @override
  Stream<bool> get playingStream => _p.playingStream;
  @override
  Stream<Duration> get positionStream => _p.positionStream;
  @override
  Stream<Duration?> get durationStream => _p.durationStream;
  @override
  Stream<void> get onCompleted => _p.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});
  @override
  Future<void> dispose() => _p.dispose();
}

/// Resolve a descriptor to a local playable file path. Injectable so tests
/// avoid the network; the default fetches + decrypts via [fetchAndDecrypt].
typedef PathResolver =
    Future<String> Function(AttachmentDescriptor d, LiveConnection? conn);

Future<String> _defaultResolve(
  AttachmentDescriptor d,
  LiveConnection? conn,
) async {
  final file = await fetchAndDecrypt(conn: conn!, descriptor: d);
  return file.path;
}

/// Owns a single audio player shared across all voice-memo bubbles and the
/// chat-info Voice tab, so only one memo plays at a time. Tracks the active
/// blob key, play/pause state, position, duration, and playback speed.
class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController({PlayerBackend? backend, PathResolver? resolvePath})
    : _p = backend ?? JustAudioBackend(),
      _resolve = resolvePath ?? _defaultResolve {
    _p.playingStream.listen((v) {
      _isPlaying = v;
      notifyListeners();
    });
    _p.positionStream.listen((v) {
      _position = v;
      notifyListeners();
    });
    _p.durationStream.listen((v) {
      _duration = v ?? Duration.zero;
      notifyListeners();
    });
    // On completion just_audio parks at the end with playing still latched, so
    // a follow-up play() is a no-op and the button looks stuck. Rewind to the
    // start and sit paused so the next tap replays from the beginning.
    _p.onCompleted.listen((_) {
      _isPlaying = false;
      _position = Duration.zero;
      _p.seek(Duration.zero);
      notifyListeners();
    });
  }

  final PlayerBackend _p;
  final PathResolver _resolve;

  String? _activeBlobKey;
  bool _isPlaying = false;
  double _speed = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  String? get activeBlobKey => _activeBlobKey;
  bool get isPlaying => _isPlaying;
  double get speed => _speed;
  Duration get position => _position;
  Duration get duration => _duration;

  Future<void> toggle(AttachmentDescriptor d, LiveConnection? conn) async {
    if (_activeBlobKey == d.blobKey) {
      if (_isPlaying) {
        await _p.pause();
      } else {
        await _p.play();
      }
      return;
    }
    await _p.pause();
    final path = await _resolve(d, conn);
    _activeBlobKey = d.blobKey;
    _position = Duration.zero;
    await _p.setFilePath(path);
    await _p.setSpeed(_speed);
    await _p.play();
    notifyListeners();
  }

  Future<void> seek(Duration to) => _p.seek(to);

  void cycleSpeed() {
    _speed = switch (_speed) {
      1.0 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    _p.setSpeed(_speed);
    notifyListeners();
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }
}
