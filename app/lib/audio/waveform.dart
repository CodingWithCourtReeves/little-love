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
