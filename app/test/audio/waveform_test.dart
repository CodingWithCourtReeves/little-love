import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/audio/waveform.dart';

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

    test('a short recording fills every bucket (no interior gaps)', () {
      // Fewer samples than buckets must upsample, not leave most buckets at 0
      // (a sub-6s memo otherwise renders a near-flat waveform).
      final out = downsampleWaveform(List.filled(5, -5.0), buckets: 64);
      expect(out.length, 64);
      expect(out.every((p) => p > 0), isTrue);
    });
  });
}
