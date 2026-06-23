# Voice Memos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Telegram-parity voice memos — hold-to-record in the composer (slide-to-cancel, lock-to-record), an E2EE `kind:"audio"` message, a playback bubble with waveform/scrub/speed, and the chat-info Voice tab.

**Architecture:** Almost entirely client-side Dart. A new `audio/` library provides three isolated units — a pure waveform downsampler, a recorder state-machine wrapping `record`, and a single-active-player wrapping `just_audio`. Audio is sent as a new `MessageContent` kind reusing the existing `AttachmentDescriptor` + E2EE upload/download flow. The waveform (~64 peaks) rides as plain ints inside the already-encrypted descriptor. The server treats the body as opaque ciphertext, so there are **no Rust changes and no migration**.

**Tech Stack:** Flutter, Riverpod, `record` (AAC-LC `.m4a` capture + amplitude stream), `just_audio` (playback/seek/speed), XChaCha20-Poly1305 (existing `file_crypto.dart`).

## Global Constraints

- iOS-only. Prefer iOS-native packages (project is iOS-only MVP).
- Audio container/codec: **AAC-LC in `.m4a`**, `mime = "audio/mp4"`.
- Max recording length: **5 minutes (300s)**, auto-stop at the cap.
- Waveform: **exactly 64 peaks**, each normalized to **0–31** (one byte).
- Message envelope is versioned `{'v': 1, 'kind': ...}`; unknown kinds decode to plain text (back-compat).
- Voice memos **send immediately on release** — they do NOT go through the photo staging tray.
- Only **one** voice memo plays at a time (shared playback controller).
- Server body cap is 98 KiB base64; audio bytes go to the blob store, only the descriptor (incl. 64-byte waveform) rides in the body — stays well under.
- No data statements in migrations (none needed here anyway).
- Before pushing: run `dart format`, full `flutter analyze`, and `flutter test` (per-file checks miss CI failures).

---

### Task 1: Add dependencies + iOS mic permission

**Files:**
- Modify: `app/pubspec.yaml` (dependencies block)
- Modify: `app/ios/Runner/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: `record` (`AudioRecorder`, `RecordConfig`, `AudioEncoder.aacLc`) and `just_audio` (`AudioPlayer`) packages available to later tasks; `NSMicrophoneUsageDescription` so recording doesn't crash on first use.

- [ ] **Step 1: Add the two packages**

In `app/pubspec.yaml`, under `dependencies:` (alphabetical-ish, near the other media packages), add:

```yaml
  record: ^5.1.2
  just_audio: ^0.9.40
```

- [ ] **Step 2: Resolve dependencies**

Run: `cd app && flutter pub get`
Expected: resolves with no version conflicts; `record` and `just_audio` appear in `pubspec.lock`.

- [ ] **Step 3: Add the iOS microphone usage string**

In `app/ios/Runner/Info.plist`, add the key inside the top-level `<dict>` (next to the other usage descriptions like camera/photo if present):

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>little love uses the microphone to record voice messages.</string>
```

- [ ] **Step 4: Verify the plist parses**

Run: `plutil -lint app/ios/Runner/Info.plist`
Expected: `app/ios/Runner/Info.plist: OK`

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/ios/Runner/Info.plist
git commit -m "feat(voice): add record + just_audio deps and mic permission"
```

---

### Task 2: Waveform downsampler (pure logic)

**Files:**
- Create: `app/lib/audio/waveform.dart`
- Test: `app/test/audio/waveform_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `List<int> downsampleWaveform(List<double> amplitudes, {int buckets = 64})` — buckets raw amplitude samples into exactly `buckets` peaks, each normalized to 0–31. `amplitudes` are dBFS values as emitted by `record` (≤ 0.0, with roughly -160.0 = silence, 0.0 = max). Always returns a list of length `buckets`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/audio/waveform_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/audio/waveform.dart';

void main() {
  group('downsampleWaveform', () {
    test('always returns exactly `buckets` peaks', () {
      expect(downsampleWaveform([], buckets: 64).length, 64);
      expect(downsampleWaveform([-10.0], buckets: 64).length, 64);
      expect(
        downsampleWaveform(List.filled(5000, -10.0), buckets: 64).length,
        64,
      );
      expect(downsampleWaveform([-10.0, -20.0], buckets: 8).length, 8);
    });

    test('all peaks are within 0..31', () {
      final out = downsampleWaveform(
        List.generate(200, (i) => -i.toDouble()),
        buckets: 64,
      );
      for (final p in out) {
        expect(p, inInclusiveRange(0, 31));
      }
    });

    test('louder (closer to 0 dBFS) maps to taller peaks than quieter', () {
      final loud = downsampleWaveform(List.filled(64, -5.0), buckets: 64);
      final quiet = downsampleWaveform(List.filled(64, -80.0), buckets: 64);
      expect(loud.first, greaterThan(quiet.first));
    });

    test('silence (empty input) is a flat zero waveform', () {
      expect(downsampleWaveform([], buckets: 64), List.filled(64, 0));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/audio/waveform_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'little_love' ... waveform.dart` / `downsampleWaveform` not defined.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/audio/waveform.dart

/// Floor (in dBFS) we treat as silence. `record` reports amplitude in dBFS
/// where 0.0 is the loudest and large-negative is quiet; -60 is already near
/// inaudible, so anything below maps to a flat baseline.
const double _floorDb = -60.0;

/// Downsample a stream of dBFS amplitude samples into exactly [buckets] peaks,
/// each normalized to 0..31 (one byte). Empty input yields a flat zero
/// waveform. The peaks are stored in the (already-encrypted) attachment
/// descriptor and drawn as the static bar waveform under a voice memo.
List<int> downsampleWaveform(List<double> amplitudes, {int buckets = 64}) {
  if (amplitudes.isEmpty) return List<int>.filled(buckets, 0);
  final out = List<int>.filled(buckets, 0);
  final per = amplitudes.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final start = (b * per).floor();
    final end = b == buckets - 1 ? amplitudes.length : ((b + 1) * per).floor();
    // Peak (max amplitude) within the window, like Telegram's bar waveform.
    var peak = _floorDb;
    for (var i = start; i < end && i < amplitudes.length; i++) {
      if (amplitudes[i] > peak) peak = amplitudes[i];
    }
    out[b] = _normalize(peak);
  }
  return out;
}

/// Map a dBFS value (<= 0.0) onto 0..31. [_floorDb] and quieter → 0, 0 dBFS → 31.
int _normalize(double db) {
  if (db <= _floorDb) return 0;
  if (db >= 0.0) return 31;
  final frac = (db - _floorDb) / (0.0 - _floorDb); // 0..1
  return (frac * 31).round().clamp(0, 31);
}
```

> NOTE: confirm the package name. `import 'package:little_love/...'` assumes the pubspec `name:` is `little_love`. Check `app/pubspec.yaml` line 1 and use whatever `name:` is set there in every test import.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/audio/waveform_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/audio/waveform.dart app/test/audio/waveform_test.dart
git commit -m "feat(voice): pure waveform downsampler"
```

---

### Task 3: Add `waveform` to AttachmentDescriptor (tolerate missing thumb)

**Files:**
- Modify: `app/lib/attachment/attachment_descriptor.dart:9-62`
- Test: `app/test/attachment/attachment_descriptor_waveform_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `AttachmentDescriptor` gains `final List<int>? waveform;` (named param `waveform`, default `null`). `toJson` emits `'waveform'` only when non-null. `fromJson` reads `'waveform'` (a JSON list of ints) and tolerates a **missing** `'thumb'` key by defaulting `thumbB64` to `''` (audio has no thumbnail).

- [ ] **Step 1: Write the failing test**

```dart
// app/test/attachment/attachment_descriptor_waveform_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/attachment/attachment_descriptor.dart';

AttachmentDescriptor _audio({List<int>? wave}) => AttachmentDescriptor(
  blobKey: 'k',
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: 'memo.m4a',
  size: 1234,
  width: 0,
  height: 0,
  durationMs: 4200,
  thumbB64: '',
  waveform: wave,
);

void main() {
  test('waveform round-trips through toJson/fromJson', () {
    final wave = List<int>.generate(64, (i) => i % 32);
    final back = AttachmentDescriptor.fromJson(_audio(wave: wave).toJson());
    expect(back.waveform, wave);
    expect(back.durationMs, 4200);
    expect(back.mime, 'audio/mp4');
  });

  test('null waveform is omitted from json and decodes back to null', () {
    final json = _audio(wave: null).toJson();
    expect(json.containsKey('waveform'), isFalse);
    expect(AttachmentDescriptor.fromJson(json).waveform, isNull);
  });

  test('fromJson tolerates a missing thumb key (audio has no thumbnail)', () {
    final json = _audio(wave: [1, 2, 3]).toJson()..remove('thumb');
    final back = AttachmentDescriptor.fromJson(json);
    expect(back.thumbB64, '');
    expect(back.waveform, [1, 2, 3]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/attachment/attachment_descriptor_waveform_test.dart`
Expected: FAIL — `No named parameter with the name 'waveform'`.

- [ ] **Step 3: Write minimal implementation**

In `app/lib/attachment/attachment_descriptor.dart`, add the field to the constructor, the field declaration, `toJson`, and `fromJson`:

```dart
  const AttachmentDescriptor({
    required this.blobKey,
    required this.contentKeyB64,
    required this.nonceB64,
    required this.mime,
    required this.filename,
    required this.size,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.thumbB64,
    this.waveform,
  });
```

```dart
  final String thumbB64;

  /// For `kind:"audio"`: ~64 amplitude peaks (0..31) drawn as the static bar
  /// waveform. Null for non-audio attachments. Rides inside the already-
  /// encrypted descriptor, so no separate blob is needed.
  final List<int>? waveform;

  bool get isAudio => mime.startsWith('audio/');
```

```dart
  Map<String, Object?> toJson() => {
    'blob_key': blobKey,
    'content_key': contentKeyB64,
    'nonce': nonceB64,
    'mime': mime,
    'filename': filename,
    'size': size,
    'width': width,
    'height': height,
    if (durationMs != null) 'duration_ms': durationMs,
    'thumb': thumbB64,
    if (waveform != null) 'waveform': waveform,
  };
```

```dart
  factory AttachmentDescriptor.fromJson(Map<String, Object?> j) =>
      AttachmentDescriptor(
        blobKey: j['blob_key']! as String,
        contentKeyB64: j['content_key']! as String,
        nonceB64: j['nonce']! as String,
        mime: j['mime']! as String,
        filename: (j['filename'] as String?) ?? '',
        size: (j['size'] as num).toInt(),
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        thumbB64: (j['thumb'] as String?) ?? '',
        waveform: (j['waveform'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList(),
      );
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/attachment/attachment_descriptor_waveform_test.dart test/wire/msg_attachment_test.dart`
Expected: PASS — new tests pass AND the existing attachment test still passes (no regression from the `thumb` default).

- [ ] **Step 5: Commit**

```bash
git add app/lib/attachment/attachment_descriptor.dart app/test/attachment/attachment_descriptor_waveform_test.dart
git commit -m "feat(voice): add waveform field to AttachmentDescriptor"
```

---

### Task 4: `AudioContent` message kind

**Files:**
- Modify: `app/lib/conversation/message_content.dart:16-48` (decode switch) and add a new class after `FileContent`
- Test: `app/test/conversation/audio_content_test.dart`

**Interfaces:**
- Consumes: `AttachmentDescriptor` (Task 3).
- Produces: `class AudioContent extends MessageContent` with `final AttachmentDescriptor descriptor;` and `final String? caption;`, constructed `AudioContent(descriptor, {caption})`. Encodes `{'v':1,'kind':'audio', if caption..., ...descriptor.toJson()}`. `MessageContent.decode` returns `AudioContent` for `kind == 'audio'`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/conversation/audio_content_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/attachment/attachment_descriptor.dart';
import 'package:little_love/conversation/message_content.dart';

void main() {
  final descriptor = AttachmentDescriptor(
    blobKey: 'blob',
    contentKeyB64: 'ck',
    nonceB64: 'nc',
    mime: 'audio/mp4',
    filename: 'memo.m4a',
    size: 999,
    width: 0,
    height: 0,
    durationMs: 3000,
    thumbB64: '',
    waveform: List<int>.filled(64, 7),
  );

  test('AudioContent encodes then decodes back to AudioContent', () {
    final encoded = AudioContent(descriptor, caption: 'hi').encode();
    final decoded = MessageContent.decode(encoded);
    expect(decoded, isA<AudioContent>());
    final a = decoded as AudioContent;
    expect(a.caption, 'hi');
    expect(a.descriptor.mime, 'audio/mp4');
    expect(a.descriptor.durationMs, 3000);
    expect(a.descriptor.waveform, List<int>.filled(64, 7));
  });

  test('empty caption is omitted and decodes to null', () {
    final decoded =
        MessageContent.decode(AudioContent(descriptor).encode())
            as AudioContent;
    expect(decoded.caption, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/audio_content_test.dart`
Expected: FAIL — `AudioContent` not defined.

- [ ] **Step 3: Write minimal implementation**

In `message_content.dart`, add a case to the decode switch (right after the `'file'` case, before `'reaction'`):

```dart
          case 'audio':
            final cap = j['caption'] as String?;
            return AudioContent(
              AttachmentDescriptor.fromJson(j),
              caption: (cap == null || cap.isEmpty) ? null : cap,
            );
```

And add the class after `FileContent`:

```dart
/// A voice memo. Same wire shape as [FileContent] but rendered as an audio
/// player bubble. The [AttachmentDescriptor] carries the AAC `.m4a` blob key,
/// per-file key, duration, and the 64-peak waveform. Full audio bytes live in
/// R2; only the descriptor rides in the encrypted body.
class AudioContent extends MessageContent {
  const AudioContent(this.descriptor, {this.caption});
  final AttachmentDescriptor descriptor;
  final String? caption;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'audio',
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
    ...descriptor.toJson(),
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/conversation/audio_content_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/message_content.dart app/test/conversation/audio_content_test.dart
git commit -m "feat(voice): add AudioContent message kind"
```

---

### Task 5: Teach the download cache about `.m4a`

**Files:**
- Modify: `app/lib/attachment/attachment_download.dart:20-31` (`_cacheExt` switch)
- Test: `app/test/attachment/cache_ext_test.dart`

**Interfaces:**
- Consumes: `AttachmentDescriptor` (`isAudio`, `mime`).
- Produces: `_cacheExt` returns `.m4a` for `audio/mp4` so `just_audio` (AVFoundation) picks a demuxer. To test the private function, expose it via a thin top-level wrapper `cacheExtFor(AttachmentDescriptor)` in the same file.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/attachment/cache_ext_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/attachment/attachment_descriptor.dart';
import 'package:little_love/attachment/attachment_download.dart';

AttachmentDescriptor _d({required String mime, String filename = ''}) =>
    AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: 'c',
      nonceB64: 'n',
      mime: mime,
      filename: filename,
      size: 1,
      width: 0,
      height: 0,
      durationMs: null,
      thumbB64: '',
    );

void main() {
  test('audio/mp4 maps to .m4a', () {
    expect(cacheExtFor(_d(mime: 'audio/mp4')), '.m4a');
  });

  test('explicit filename extension still wins', () {
    expect(cacheExtFor(_d(mime: 'audio/mp4', filename: 'note.aac')), '.aac');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/attachment/cache_ext_test.dart`
Expected: FAIL — `cacheExtFor` not defined.

- [ ] **Step 3: Write minimal implementation**

In `attachment_download.dart`, add the `audio/mp4` case inside the `switch (d.mime)` (before `default`), and add the public wrapper just below the `_cacheExt` function:

```dart
    case 'video/quicktime':
      return '.mov';
    case 'audio/mp4':
      return '.m4a';
    case 'image/png':
```

```dart
/// Test-visible wrapper for [_cacheExt].
String cacheExtFor(AttachmentDescriptor d) => _cacheExt(d);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/attachment/cache_ext_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/attachment/attachment_download.dart app/test/attachment/cache_ext_test.dart
git commit -m "feat(voice): cache voice memos with .m4a extension"
```

---

### Task 6: Recorder controller (state machine)

**Files:**
- Create: `app/lib/audio/recorder_controller.dart`
- Test: `app/test/audio/recorder_controller_test.dart`

**Interfaces:**
- Consumes: `record` package; `downsampleWaveform` (Task 2).
- Produces:
  - `enum RecorderState { idle, recording, locked, stopped, cancelled }`
  - `class VoiceRecorderController extends ChangeNotifier` with:
    - constructor `VoiceRecorderController({AudioRecorder? recorder, Duration maxDuration = const Duration(minutes: 5)})` (inject a fake recorder in tests)
    - `RecorderState get state`
    - `Duration get elapsed`
    - `Future<void> start()` — checks permission, begins capture to a temp `.m4a`, samples amplitude, transitions `idle → recording`
    - `void lock()` — `recording → locked`
    - `Future<VoiceRecording?> stop()` — stops capture, returns the result (path + duration + `waveform`), transitions to `stopped`; returns null if nothing was recorded
    - `Future<void> cancel()` — stops + deletes the temp file, transitions to `cancelled`
    - auto-calls `stop()` when `elapsed >= maxDuration`
  - `class VoiceRecording { final String path; final Duration duration; final List<int> waveform; }`
  - An abstraction seam so tests don't touch real hardware: define `abstract class RecorderBackend` with `Future<bool> hasPermission()`, `Future<void> start(String path)`, `Future<String?> stop()`, `Stream<double> amplitudeStream()`, and a default `RecordBackend` implementing it over `AudioRecorder`. The controller takes a `RecorderBackend`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/audio/recorder_controller_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/audio/recorder_controller.dart';

class FakeBackend implements RecorderBackend {
  final _amp = StreamController<double>.broadcast();
  bool started = false;
  bool stopped = false;
  String? lastPath;

  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> start(String path) async {
    started = true;
    lastPath = path;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return lastPath;
  }

  @override
  Stream<double> amplitudeStream() => _amp.stream;

  void emit(double db) => _amp.add(db);
}

void main() {
  test('start moves idle -> recording and begins capture', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(backend: be);
    expect(c.state, RecorderState.idle);
    await c.start();
    expect(c.state, RecorderState.recording);
    expect(be.started, isTrue);
  });

  test('lock moves recording -> locked', () async {
    final c = VoiceRecorderController(backend: FakeBackend());
    await c.start();
    c.lock();
    expect(c.state, RecorderState.locked);
  });

  test('stop returns a recording with a 64-peak waveform', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(backend: be);
    await c.start();
    be.emit(-5.0);
    be.emit(-50.0);
    await Future<void>.delayed(Duration.zero);
    final rec = await c.stop();
    expect(c.state, RecorderState.stopped);
    expect(rec, isNotNull);
    expect(rec!.waveform.length, 64);
    expect(be.stopped, isTrue);
  });

  test('cancel deletes capture and moves to cancelled', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(backend: be);
    await c.start();
    await c.cancel();
    expect(c.state, RecorderState.cancelled);
    expect(be.stopped, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/audio/recorder_controller_test.dart`
Expected: FAIL — `RecorderBackend`/`VoiceRecorderController` not defined.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/audio/recorder_controller.dart
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
  Future<void> start(String path) => _rec.start(
    const RecordConfig(encoder: AudioEncoder.aacLc),
    path: path,
  );

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Stream<double> amplitudeStream() => _rec
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((a) => a.current);
}

class VoiceRecorderController extends ChangeNotifier {
  VoiceRecorderController({
    RecorderBackend? backend,
    this.maxDuration = const Duration(minutes: 5),
  }) : _backend = backend ?? RecordBackend();

  final RecorderBackend _backend;
  final Duration maxDuration;

  RecorderState _state = RecorderState.idle;
  RecorderState get state => _state;

  final List<double> _amplitudes = [];
  StreamSubscription<double>? _ampSub;
  Stopwatch? _watch;
  Timer? _ticker;
  String? _path;

  Duration get elapsed => _watch?.elapsed ?? Duration.zero;

  Future<void> start() async {
    if (_state != RecorderState.idle) return;
    if (!await _backend.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    _path = p.join(
      dir.path,
      'voice_${DateTime.now().microsecondsSinceEpoch}.m4a',
    );
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/audio/recorder_controller_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/audio/recorder_controller.dart app/test/audio/recorder_controller_test.dart
git commit -m "feat(voice): recorder controller state machine"
```

---

### Task 7: Playback controller (single active player)

**Files:**
- Create: `app/lib/audio/playback_controller.dart`
- Test: `app/test/audio/playback_controller_test.dart`

**Interfaces:**
- Consumes: `just_audio` (`AudioPlayer`), `fetchAndDecrypt` (existing), `AttachmentDescriptor`, `LiveConnection`.
- Produces:
  - `class VoicePlaybackController extends ChangeNotifier` with:
    - `String? get activeBlobKey` — which memo is loaded/playing (null = none)
    - `bool get isPlaying`
    - `double get speed` (1.0 / 1.5 / 2.0)
    - `Duration get position`, `Duration get duration`
    - `Future<void> toggle(AttachmentDescriptor d, LiveConnection conn)` — if `d` is the active memo, play/pause it; otherwise stop the current one, load `d` (fetch+decrypt via `fetchAndDecrypt`, set as active), and play. Enforces one-at-a-time.
    - `Future<void> seek(Duration to)`
    - `void cycleSpeed()` — 1.0 → 1.5 → 2.0 → 1.0
  - A player seam: `abstract class PlayerBackend` (`setFilePath`, `play`, `pause`, `seek`, `setSpeed`, streams for `playing`/`position`/`duration`, `dispose`) with a default `JustAudioBackend`. Inject a fake in tests. The fetch step is injected as `Future<String> Function(AttachmentDescriptor) resolvePath` (defaults to a closure over `fetchAndDecrypt`) so tests don't hit the network.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/audio/playback_controller_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/attachment/attachment_descriptor.dart';
import 'package:little_love/audio/playback_controller.dart';

class FakePlayer implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  bool playing = false;
  String? loadedPath;
  double speed = 1.0;

  @override
  Future<void> setFilePath(String path) async => loadedPath = path;
  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setSpeed(double s) async => speed = s;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

AttachmentDescriptor _audio(String blob) => AttachmentDescriptor(
  blobKey: blob,
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: '$blob.m4a',
  size: 1,
  width: 0,
  height: 0,
  durationMs: 1000,
  thumbB64: '',
  waveform: List<int>.filled(64, 4),
);

void main() {
  test('toggling a new memo loads + plays and becomes active', () async {
    final fake = FakePlayer();
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d) async => '/tmp/${d.blobKey}.m4a',
    );
    await c.toggle(_audio('a'), FakeConn());
    expect(fake.loadedPath, '/tmp/a.m4a');
    expect(fake.playing, isTrue);
    expect(c.activeBlobKey, 'a');
  });

  test('toggling the active memo again pauses it', () async {
    final fake = FakePlayer();
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d) async => '/tmp/${d.blobKey}.m4a',
    );
    final a = _audio('a');
    await c.toggle(a, FakeConn());
    await c.toggle(a, FakeConn());
    expect(fake.playing, isFalse);
  });

  test('cycleSpeed walks 1.0 -> 1.5 -> 2.0 -> 1.0', () {
    final c = VoicePlaybackController(
      backend: FakePlayer(),
      resolvePath: (d) async => '',
    );
    expect(c.speed, 1.0);
    c.cycleSpeed();
    expect(c.speed, 1.5);
    c.cycleSpeed();
    expect(c.speed, 2.0);
    c.cycleSpeed();
    expect(c.speed, 1.0);
  });
}
```

> NOTE: `FakeConn` is a stand-in for `LiveConnection` — since `resolvePath` is injected, the controller never calls the connection in tests. Add a minimal `class FakeConn implements LiveConnection { noSuchMethod(_) => null; }` at the top of the test file (import `live_connection.dart`), or change `toggle` to accept the conn only to thread into `resolvePath` and pass `null as dynamic`. Prefer the `noSuchMethod` stub.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/audio/playback_controller_test.dart`
Expected: FAIL — `PlayerBackend`/`VoicePlaybackController` not defined.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/audio/playback_controller.dart
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
  Future<void> dispose() => _p.dispose();
}

typedef PathResolver = Future<String> Function(AttachmentDescriptor d);

class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController({
    PlayerBackend? backend,
    PathResolver? resolvePath,
  }) : _p = backend ?? JustAudioBackend(),
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
  }

  final PlayerBackend _p;
  final PathResolver _resolve;

  // Captured per call below; set on first non-resolved toggle.
  static LiveConnection? _conn;
  static Future<String> _defaultResolve(AttachmentDescriptor d) async {
    final file = await fetchAndDecrypt(conn: _conn!, descriptor: d);
    return file.path;
  }

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

  Future<void> toggle(AttachmentDescriptor d, LiveConnection conn) async {
    _conn = conn; // used by the default resolver
    if (_activeBlobKey == d.blobKey) {
      if (_isPlaying) {
        await _p.pause();
      } else {
        await _p.play();
      }
      return;
    }
    await _p.pause();
    final path = await _resolve(d);
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
```

> NOTE: the `_conn` static is a pragmatic bridge so the default resolver can reach `fetchAndDecrypt` without widening every call site. If a reviewer dislikes the static, switch `_resolve` to a `PathResolver` stored per-controller that closes over the conn passed at construction from the provider in Task 8/10. Keep the injected-resolver seam regardless — it's what the tests use.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/audio/playback_controller_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/audio/playback_controller.dart app/test/audio/playback_controller_test.dart
git commit -m "feat(voice): single-active-player playback controller"
```

---

### Task 8: Recording UX in the composer (overlay + gestures)

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (`_micButton` at 1446-1482, `_trailingButton` at 1412-1423, widget fields/callbacks at 100-145, and add overlay state)
- Test: `app/test/conversation/recording_overlay_test.dart`

**Interfaces:**
- Consumes: `VoiceRecorderController` (Task 6).
- Produces: a new callback on `ConversationPage`: `final Future<void> Function(VoiceRecording rec)? onSendVoice;` (wired in Task 9). The mic button becomes a press-and-hold target: `onLongPressStart` → `controller.start()`, drag tracked via `onLongPressMoveUpdate` (left past `-80px` arms cancel; up past `-80px` locks), `onLongPressEnd` → if cancel-armed `cancel()`, else `stop()` then `onSendVoice(rec)`. While recording (and not locked) the composer row is replaced by a recording overlay (`Key('recording-overlay')`) showing a red dot, mm:ss timer, "‹ slide to cancel", and a lock chevron. When locked, show a stop button (`Key('recording-stop')`) and a send button (`Key('recording-send')`).

- [ ] **Step 1: Write the failing widget test**

```dart
// app/test/conversation/recording_overlay_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/conversation/recording_overlay.dart';

void main() {
  testWidgets('overlay shows timer, cancel hint, and lock affordance', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingOverlay(
            elapsed: Duration(seconds: 5),
            locked: false,
            cancelArmed: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('recording-overlay')), findsOneWidget);
    expect(find.text('0:05'), findsOneWidget);
    expect(find.textContaining('slide to cancel'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('locked overlay shows stop + send', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingOverlay(
            elapsed: Duration(seconds: 5),
            locked: true,
            cancelArmed: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('recording-stop')), findsOneWidget);
    expect(find.byKey(const Key('recording-send')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/recording_overlay_test.dart`
Expected: FAIL — `recording_overlay.dart` not found.

- [ ] **Step 3: Write the overlay widget**

Create `app/lib/conversation/recording_overlay.dart` as a pure, stateless presentation widget (state lives in the page). It must format `elapsed` as `m:ss`:

```dart
// app/lib/conversation/recording_overlay.dart
import 'package:flutter/material.dart';

String formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class RecordingOverlay extends StatelessWidget {
  const RecordingOverlay({
    super.key,
    required this.elapsed,
    required this.locked,
    required this.cancelArmed,
    this.onStop,
    this.onSend,
  });

  final Duration elapsed;
  final bool locked;
  final bool cancelArmed;
  final VoidCallback? onStop;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('recording-overlay'),
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.circle, color: Colors.red, size: 12),
          const SizedBox(width: 10),
          Text(formatElapsed(elapsed)),
          const Spacer(),
          if (locked) ...[
            IconButton(
              key: const Key('recording-stop'),
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: onStop,
            ),
            IconButton(
              key: const Key('recording-send'),
              icon: const Icon(Icons.arrow_upward),
              onPressed: onSend,
            ),
          ] else ...[
            Opacity(
              opacity: cancelArmed ? 1.0 : 0.6,
              child: const Text('‹ slide to cancel'),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.lock_outline, size: 18),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the overlay test to verify it passes**

Run: `cd app && flutter test test/conversation/recording_overlay_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the gesture + overlay into the composer**

In `conversation_page.dart`:

1. Add the field near the other callbacks (around line 124):

```dart
  final Future<void> Function(VoiceRecording rec)? onSendVoice;
```
and the matching constructor param `this.onSendVoice,`. Import `../audio/recorder_controller.dart` and `recording_overlay.dart`.

2. Add state to the `State` class:

```dart
  late final VoiceRecorderController _recorder = VoiceRecorderController()
    ..addListener(() => setState(() {}));
  bool _cancelArmed = false;
  double _dragDx = 0, _dragDy = 0;
```
and dispose it in `dispose()`: `_recorder.dispose();`.

3. Replace `_micButton`'s `InkWell.onTap` snackbar with a long-press gesture:

```dart
  Widget _micButton() {
    return GestureDetector(
      key: const Key('composer-mic'),
      onLongPressStart: (_) {
        _cancelArmed = false;
        _dragDx = _dragDy = 0;
        _recorder.start();
      },
      onLongPressMoveUpdate: (d) {
        _dragDx = d.offsetFromOrigin.dx;
        _dragDy = d.offsetFromOrigin.dy;
        setState(() => _cancelArmed = _dragDx < -80);
        if (_dragDy < -80) _recorder.lock();
      },
      onLongPressEnd: (_) async {
        if (_recorder.state == RecorderState.locked) return; // handled by buttons
        if (_cancelArmed) {
          await _recorder.cancel();
        } else {
          final rec = await _recorder.stop();
          if (rec != null) await widget.onSendVoice?.call(rec);
        }
      },
      child: _micGlassCircle(), // the existing ClipOval/BackdropFilter visual, factored out
    );
  }
```

4. In the composer build (around line 1300, where the pill + trailing button assemble), when `_recorder.state == RecorderState.recording || _recorder.state == RecorderState.locked`, render `RecordingOverlay` in place of the text pill:

```dart
  if (_recorder.state == RecorderState.recording ||
      _recorder.state == RecorderState.locked)
    RecordingOverlay(
      elapsed: _recorder.elapsed,
      locked: _recorder.state == RecorderState.locked,
      cancelArmed: _cancelArmed,
      onStop: () => _recorder.stop(),
      onSend: () async {
        final rec = await _recorder.stop();
        if (rec != null) await widget.onSendVoice?.call(rec);
      },
    )
  else
    _existingComposerRow(),
```

- [ ] **Step 6: Run the full conversation test suite + analyze**

Run: `cd app && flutter test test/conversation/ && flutter analyze lib/conversation/conversation_page.dart lib/conversation/recording_overlay.dart`
Expected: tests PASS; analyze reports no errors (warnings about the new callback being unused until Task 9 are acceptable).

- [ ] **Step 7: Commit**

```bash
git add app/lib/conversation/recording_overlay.dart app/lib/conversation/conversation_page.dart app/test/conversation/recording_overlay_test.dart
git commit -m "feat(voice): hold-to-record composer with slide-to-cancel and lock"
```

---

### Task 9: Send path for recorded voice memos

**Files:**
- Modify: `app/lib/screens/inbox/home_screen.dart` (add `_sendVoice`, wire `onSendVoice` at the `ConversationPage` construction ~line 215-237)
- Test: manual on-device (send/playback is platform audio; covered by the controller unit tests). Add a small unit test for the descriptor built from a `VoiceRecording` if you factor that out (optional).

**Interfaces:**
- Consumes: `VoiceRecording` (Task 6), `AudioContent` (Task 4), `uploadCiphertext`, `encryptFileBytes`, `buildSendFrame`, `MessageStore.add`.
- Produces: `onSendVoice` wired so a released/sent recording is encrypted, uploaded, and fanned out as `AudioContent`, with an optimistic bubble — mirroring `_sendAttachment` (home_screen.dart:338-419) but with no thumbnail and `waveform`/`durationMs` populated.

- [ ] **Step 1: Add `_sendVoice`**

In `home_screen.dart`, modeled on `_sendAttachment`:

```dart
  /// Encrypt + upload a recorded voice memo, then fan it out as a
  /// `kind:"audio"` message through the same outbox path as files. Voice memos
  /// skip the staging tray — they send the moment the user releases the mic.
  Future<void> _sendVoice(
    WidgetRef ref,
    Room room,
    BuildContext context,
    VoiceRecording rec,
  ) async {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    final clientMsgId = ref.read(outboxIdGenProvider)();
    try {
      final bytes = await File(rec.path).readAsBytes();
      final enc = await encryptFileBytes(bytes);
      final blobKey = await uploadCiphertext(
        conn: conn,
        roomId: room.roomId,
        ciphertext: enc.ciphertext,
      );
      final descriptor = AttachmentDescriptor(
        blobKey: blobKey,
        contentKeyB64: base64.encode(enc.key),
        nonceB64: base64.encode(enc.nonce),
        mime: 'audio/mp4',
        filename: 'voice.m4a',
        size: bytes.length,
        width: 0,
        height: 0,
        durationMs: rec.duration.inMilliseconds,
        thumbB64: '',
        waveform: rec.waveform,
      );
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: _me,
        plaintext: AudioContent(descriptor).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
      ref
          .read(messageStoreProvider(room.roomId).notifier)
          .add(
            Msg(
              id: clientMsgId,
              from: _me,
              to: room.roomId,
              body: '',
              ts: DateTime.now().toUtc(),
              clientMsgId: clientMsgId,
              sendStatus: SendStatus.sending,
              attachment: descriptor,
            ),
          );
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't send voice message.")),
      );
    }
  }
```

Add imports if missing: `dart:io` (`File`), `../../audio/recorder_controller.dart` (`VoiceRecording`), `../../conversation/message_content.dart` (`AudioContent`) — match the existing import style/paths in the file.

- [ ] **Step 2: Wire the callback**

In `_openRoom`, add to the `ConversationPage(...)` constructor:

```dart
          onSendVoice: (rec) => _sendVoice(ref, room, context, rec),
```

- [ ] **Step 3: Analyze**

Run: `cd app && flutter analyze lib/screens/inbox/home_screen.dart`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/inbox/home_screen.dart
git commit -m "feat(voice): send recorded voice memos as kind:audio"
```

---

### Task 10: Audio playback bubble

**Files:**
- Create: `app/lib/conversation/audio_bubble.dart`
- Modify: `app/lib/conversation/conversation_page.dart` `_bubbleContent` (~line 951) to branch to `AudioBubble` when `m.attachment!.isAudio`
- Test: `app/test/conversation/audio_bubble_test.dart`

**Interfaces:**
- Consumes: `VoicePlaybackController` (Task 7), `AttachmentDescriptor` (waveform/durationMs), `LiveConnection`.
- Produces: `class AudioBubble extends StatelessWidget` taking `descriptor`, `isMe`, `controller` (VoicePlaybackController), `conn`. Renders a play/pause button (`Key('audio-play')`), a waveform bar row driven by `descriptor.waveform`, the duration text, and a speed badge (`Key('audio-speed')`) that calls `controller.cycleSpeed()`. Tapping play calls `controller.toggle(descriptor, conn)`. A horizontal drag over the waveform calls `controller.seek(...)`.

- [ ] **Step 1: Write the failing widget test**

```dart
// app/test/conversation/audio_bubble_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/attachment/attachment_descriptor.dart';
import 'package:little_love/audio/playback_controller.dart';
import 'package:little_love/conversation/audio_bubble.dart';

AttachmentDescriptor _audio() => AttachmentDescriptor(
  blobKey: 'a',
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: 'a.m4a',
  size: 1,
  width: 0,
  height: 0,
  durationMs: 65000,
  thumbB64: '',
  waveform: List<int>.filled(64, 10),
);

void main() {
  testWidgets('renders play button, duration, and 64 waveform bars', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioBubble(
            descriptor: _audio(),
            isMe: true,
            controller: VoicePlaybackController(
              backend: _NoopPlayer(),
              resolvePath: (d) async => '',
            ),
            conn: null,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('audio-play')), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.byKey(const Key('audio-waveform')), findsOneWidget);
  });
}

// Minimal no-op player so the controller construct doesn't touch hardware.
class _NoopPlayer implements PlayerBackend {
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #playingStream) return const Stream<bool>.empty();
    if (i.memberName == #positionStream) return const Stream<Duration>.empty();
    if (i.memberName == #durationStream) return const Stream<Duration?>.empty();
    return Future<void>.value();
  }
}
```

> NOTE: `conn: null` works because the test never plays; the bubble accepts `LiveConnection?`. Format `durationMs` as `m:ss` using the same `formatElapsed` helper from `recording_overlay.dart` (import and reuse it — do NOT duplicate).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/audio_bubble_test.dart`
Expected: FAIL — `audio_bubble.dart` not found.

- [ ] **Step 3: Write the bubble**

```dart
// app/lib/conversation/audio_bubble.dart
import 'package:flutter/material.dart';

import '../attachment/attachment_descriptor.dart';
import '../audio/playback_controller.dart';
import '../wire/live_connection.dart';
import 'recording_overlay.dart' show formatElapsed;

class AudioBubble extends StatelessWidget {
  const AudioBubble({
    super.key,
    required this.descriptor,
    required this.isMe,
    required this.controller,
    required this.conn,
  });

  final AttachmentDescriptor descriptor;
  final bool isMe;
  final VoicePlaybackController controller;
  final LiveConnection? conn;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final active = controller.activeBlobKey == descriptor.blobKey;
        final playing = active && controller.isPlaying;
        final total = Duration(milliseconds: descriptor.durationMs ?? 0);
        final progress = (active && total.inMilliseconds > 0)
            ? controller.position.inMilliseconds / total.inMilliseconds
            : 0.0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('audio-play'),
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: conn == null
                    ? null
                    : () => controller.toggle(descriptor, conn!),
              ),
              GestureDetector(
                onHorizontalDragUpdate: (d) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null || total == Duration.zero) return;
                  final frac = (d.localPosition.dx / box.size.width)
                      .clamp(0.0, 1.0);
                  controller.seek(total * frac);
                },
                child: SizedBox(
                  key: const Key('audio-waveform'),
                  width: 160,
                  height: 32,
                  child: CustomPaint(
                    painter: _WaveformPainter(
                      peaks: descriptor.waveform ?? const [],
                      progress: progress.clamp(0.0, 1.0),
                      color: isMe ? Colors.white : Colors.blueGrey,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(formatElapsed(active ? controller.position : total)),
              const SizedBox(width: 8),
              if (active)
                GestureDetector(
                  key: const Key('audio-speed'),
                  onTap: controller.cycleSpeed,
                  child: Text('${_fmtSpeed(controller.speed)}×'),
                ),
            ],
          ),
        );
      },
    );
  }

  String _fmtSpeed(double s) => s == s.roundToDouble()
      ? s.toStringAsFixed(0)
      : s.toStringAsFixed(1);
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.color,
  });
  final List<int> peaks;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final barW = size.width / (peaks.length * 1.5);
    final played = color;
    final unplayed = color.withValues(alpha: 0.35);
    for (var i = 0; i < peaks.length; i++) {
      final x = i * 1.5 * barW;
      final h = (peaks[i] / 31.0) * size.height;
      final paint = Paint()
        ..color = (i / peaks.length) <= progress ? played : unplayed;
      final top = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barW, h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.peaks != peaks;
}
```

- [ ] **Step 4: Branch the bubble in `_bubbleContent`**

In `conversation_page.dart` `_bubbleContent`, replace the `if (m.attachment != null)` block so audio renders `AudioBubble`:

```dart
    if (m.attachment != null) {
      final att = m.attachment!;
      final child = att.isAudio
          ? AudioBubble(
              descriptor: att,
              isMe: mine,
              controller: ref.read(voicePlaybackControllerProvider),
              conn: ref.read(liveConnectionProvider).asData?.value,
            )
          : _MediaBubble(
              msg: m,
              isMe: mine,
              marker: marker,
              onOpen: () => widget.onOpenAttachment?.call(att),
            );
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: child,
        ),
      );
    }
```

Add a Riverpod provider (in `conversation_page.dart` or a small `audio/playback_provider.dart`):

```dart
final voicePlaybackControllerProvider =
    Provider<VoicePlaybackController>((ref) {
  final c = VoicePlaybackController();
  ref.onDispose(c.dispose);
  return c;
});
```

> NOTE: `conversation_page.dart`'s State accesses `ref` — confirm it's a `ConsumerState`/has a `ref` in scope at `_bubbleContent`. If `_bubbleContent` is not in a Consumer context, thread the controller + conn down from `build` instead of reading providers inline.

- [ ] **Step 5: Run tests + analyze**

Run: `cd app && flutter test test/conversation/audio_bubble_test.dart && flutter analyze lib/conversation/audio_bubble.dart lib/conversation/conversation_page.dart`
Expected: test PASSES; analyze clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/audio_bubble.dart app/lib/conversation/conversation_page.dart
git commit -m "feat(voice): audio playback bubble with waveform, scrub, speed"
```

---

### Task 11: Chat-info Voice tab + exclude audio from Media grid

**Files:**
- Modify: `app/lib/conversation/chat_info_page.dart:42-49` (filters), `:74-80` (tab view)
- Test: `app/test/conversation/chat_info_voice_test.dart`

**Interfaces:**
- Consumes: `AttachmentDescriptor.isAudio` (Task 3), `AudioBubble` or a compact voice row, `voicePlaybackControllerProvider` (Task 10).
- Produces: the Media filter excludes audio (`m.attachment != null && !m.attachment!.isAudio`); a new `voice` list (`m.attachment != null && m.attachment!.isAudio`); the second tab renders a reverse-chronological list of voice rows instead of the placeholder.

- [ ] **Step 1: Write the failing widget test**

```dart
// app/test/conversation/chat_info_voice_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ... import chat_info_page, message_store provider override helpers, Msg, etc.

void main() {
  testWidgets('Voice tab lists audio messages and Media grid excludes them', (
    tester,
  ) async {
    // Build a ChatInfoPage with a MessageStore override containing one audio
    // message and one image message (see existing chat_info tests for the
    // provider-override harness used in this repo).
    // Expect: tapping the 'Voice' tab shows a row with Key('chat-info-voice-0');
    // the Media grid (Key('chat-info-media-grid')) contains only the image.
    expect(true, isTrue); // replace with the real harness assertions
  });
}
```

> NOTE: Before writing this test, open an existing chat-info / message-store widget test in `app/test/` to copy the exact `ProviderScope` override pattern (`messageStoreProvider(roomId)`), the `Msg` construction with an `attachment`, and the tab-tap helper. Reuse that harness — do not invent a new one. Replace the placeholder assertion with: pump the page, `await tester.tap(find.text('Voice'))`, `pumpAndSettle()`, `expect(find.byKey(const Key('chat-info-voice-0')), findsOneWidget)`, and assert the media grid has exactly one tile.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/chat_info_voice_test.dart`
Expected: FAIL (placeholder until the harness + Voice tab exist).

- [ ] **Step 3: Update filters + Voice tab**

In `chat_info_page.dart` `build`, change the `media` comprehension and add `voice`:

```dart
    final media = [
      for (final m in messages.reversed)
        if (m.attachment != null && !m.attachment!.isAudio) m,
    ];
    final voice = [
      for (final m in messages.reversed)
        if (m.attachment != null && m.attachment!.isAudio) m,
    ];
```

Replace the placeholder in the `TabBarView` children:

```dart
                  _mediaTab(context, media),
                  _voiceTab(context, ref, voice),
                  _linksTab(context, links),
```

Add `_voiceTab` (a `Consumer`/`ref`-aware list reusing `AudioBubble`, or a compact row):

```dart
  Widget _voiceTab(BuildContext context, WidgetRef ref, List<Msg> voice) {
    if (voice.isEmpty) return _emptyTab(context, 'No voice messages yet');
    final controller = ref.read(voicePlaybackControllerProvider);
    final conn = ref.read(liveConnectionProvider).asData?.value;
    return ListView.builder(
      key: const Key('chat-info-voice-list'),
      itemCount: voice.length,
      itemBuilder: (_, i) => ListTile(
        key: Key('chat-info-voice-$i'),
        title: AudioBubble(
          descriptor: voice[i].attachment!,
          isMe: false,
          controller: controller,
          conn: conn,
        ),
      ),
    );
  }
```

Ensure `build` has a `WidgetRef ref` in scope (the file already uses `ref.watch(messageStoreProvider...)`, so it's a `ConsumerWidget` — pass `ref` through). Add imports for `audio_bubble.dart` and the playback provider.

- [ ] **Step 4: Finish the test harness + run**

Replace the placeholder assertion (Step 1 NOTE) with the real one, then:

Run: `cd app && flutter test test/conversation/chat_info_voice_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/chat_info_page.dart app/test/conversation/chat_info_voice_test.dart
git commit -m "feat(voice): chat-info Voice tab; exclude audio from Media grid"
```

---

### Task 12: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Format**

Run: `cd app && dart format lib test`
Expected: only the new/changed files reformat, if anything.

- [ ] **Step 2: Analyze the whole app**

Run: `cd app && flutter analyze`
Expected: `No issues found!` (or only pre-existing, unrelated warnings).

- [ ] **Step 3: Run the full test suite**

Run: `cd app && flutter test`
Expected: all tests PASS, including the existing attachment/message tests (no regressions).

- [ ] **Step 4: On-device smoke (manual)**

Deploy to BOTH physical phones one at a time (never Kaitlyn's), per CLAUDE.md:
`./scripts/ios-deploy.sh --server <dev-url> --device 0DC6E4DC-B58D-509A-A5B8-FD316A255D89`
then the iPhone 13 Pro Max `F031FD6D-9E3D-5005-918D-BB860CE37C26`.

Verify: hold mic → record → release sends; slide-left cancels; slide-up locks then stop+send; the memo plays back with a moving waveform; scrub seeks; speed cycles 1×/1.5×/2×; the memo appears under chat-info → Voice and NOT under Media.

- [ ] **Step 5: Commit any format-only changes**

```bash
git add -A && git commit -m "chore(voice): format + analyze pass" || echo "nothing to commit"
```
