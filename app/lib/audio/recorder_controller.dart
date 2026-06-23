import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'waveform.dart';

enum RecorderState { idle, recording, locked, stopped, cancelled }

class VoiceRecording {
  const VoiceRecording({
    required this.path,
    required this.duration,
    required this.waveform,
  });
  final String path;
  final Duration duration;
  final List<int> waveform;
}

/// Hardware seam so the controller's state machine is testable without a mic.
abstract class RecorderBackend {
  Future<bool> hasPermission();
  Future<void> start(String path);
  Future<String?> stop();
  Stream<double> amplitudeStream();
}

/// Default backend over the `record` package (AAC-LC `.m4a`).
class RecordBackend implements RecorderBackend {
  final AudioRecorder _rec = AudioRecorder();

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start(String path) =>
      _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Stream<double> amplitudeStream() => _rec
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((a) => a.current);
}

/// Where to write the next `.m4a`. Injectable so tests avoid platform channels.
typedef TempPathFactory = Future<String> Function();

Future<String> _defaultTempPath() async {
  final dir = await getTemporaryDirectory();
  return p.join(dir.path, 'voice_${DateTime.now().microsecondsSinceEpoch}.m4a');
}

class VoiceRecorderController extends ChangeNotifier {
  VoiceRecorderController({
    RecorderBackend? backend,
    TempPathFactory? tempPathFactory,
    this.maxDuration = const Duration(minutes: 5),
  }) : _backend = backend ?? RecordBackend(),
       _tempPath = tempPathFactory ?? _defaultTempPath;

  final RecorderBackend _backend;
  final TempPathFactory _tempPath;
  final Duration maxDuration;

  RecorderState _state = RecorderState.idle;
  RecorderState get state => _state;

  final List<double> _amplitudes = [];
  StreamSubscription<double>? _ampSub;
  Stopwatch? _watch;
  Timer? _ticker;
  String? _path;

  Duration get elapsed => _watch?.elapsed ?? Duration.zero;

  /// Begin recording. Returns false (and stays idle) if already recording or
  /// microphone permission is denied, so the caller can surface that instead of
  /// failing silently.
  Future<bool> start() async {
    if (_state != RecorderState.idle) return false;
    if (!await _backend.hasPermission()) return false;
    _path = await _tempPath();
    _amplitudes.clear();
    await _backend.start(_path!);
    _ampSub = _backend.amplitudeStream().listen(_amplitudes.add);
    _watch = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (elapsed >= maxDuration) stop();
      notifyListeners();
    });
    _state = RecorderState.recording;
    notifyListeners();
    return true;
  }

  void lock() {
    if (_state == RecorderState.recording) {
      _state = RecorderState.locked;
      notifyListeners();
    }
  }

  Future<VoiceRecording?> stop() async {
    if (_state != RecorderState.recording && _state != RecorderState.locked) {
      return null;
    }
    final duration = elapsed;
    await _teardown();
    final path = await _backend.stop();
    _state = RecorderState.stopped;
    notifyListeners();
    if (path == null) return null;
    return VoiceRecording(
      path: path,
      duration: duration,
      waveform: downsampleWaveform(List<double>.of(_amplitudes)),
    );
  }

  Future<void> cancel() async {
    await _teardown();
    await _backend.stop();
    final path = _path;
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    _state = RecorderState.cancelled;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _ticker?.cancel();
    _ticker = null;
    _watch?.stop();
    await _ampSub?.cancel();
    _ampSub = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
