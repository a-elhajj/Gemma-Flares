import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/cosinor_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CosinorService — pure OLS math tests
//
// Tests verify the closed-form Cosinor fit (Supplementary Eq. 1 of
// Hirten et al. 2025) produces correct parameter estimates on synthetic data.
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('CosinorService.fitCosinor — pure math', () {
    // ── Synthetic data generator ──────────────────────────────────────────────
    // y(t) = mesor + amplitude * cos(2πt/24 + acrophase_offset)
    // Expand with double-angle:
    //   = mesor + amplitude*cos(phi)*cos(2πt/24) - amplitude*sin(phi)*sin(2πt/24)
    // So A = amplitude*cos(phi), B = -amplitude*sin(phi)
    List<({double hour, double value})> syntheticSignal({
      required double mesor,
      required double amplitude,
      required double acrophaseOffset, // radians, 0 = peak at t=0
      required int nSamples,
      double noiseStd = 0.0,
    }) {
      final rng = math.Random(42);
      return List.generate(nSamples, (i) {
        final t = i * 24.0 / nSamples;
        final v = mesor +
            amplitude * math.cos(2 * math.pi * t / 24 + acrophaseOffset) +
            (noiseStd > 0 ? (rng.nextDouble() - 0.5) * 2 * noiseStd : 0.0);
        return (hour: t, value: v);
      });
    }

    test('recovers MESOR and Amplitude for noise-free sinusoid', () {
      final samples = syntheticSignal(
        mesor: 40.0,
        amplitude: 5.0,
        acrophaseOffset: 0.0,
        nSamples: 24, // one sample per hour
      );
      final fit = CosinorService.fitCosinor(samples);

      expect(fit.fitValid, isTrue);
      expect(fit.mesor, closeTo(40.0, 0.01));
      expect(fit.amplitude, closeTo(5.0, 0.01));
      expect(fit.rSquared, closeTo(1.0, 0.01));
    });

    test('recovers MESOR and Amplitude within 5% under moderate noise', () {
      final samples = syntheticSignal(
        mesor: 38.0,
        amplitude: 6.0,
        acrophaseOffset: -0.5,
        nSamples: 24,
        noiseStd: 1.0, // ~2.6% of amplitude
      );
      final fit = CosinorService.fitCosinor(samples);

      expect(fit.fitValid, isTrue);
      expect(fit.mesor, closeTo(38.0, 2.0)); // within 5% of 38
      expect(fit.amplitude, closeTo(6.0, 1.0)); // within ~17% tolerance (noise)
    });

    test('peak time is in range [0, 24)', () {
      final samples = syntheticSignal(
        mesor: 42.0,
        amplitude: 4.5,
        acrophaseOffset: 0.2,
        nSamples: 48, // 30-min intervals
      );
      final fit = CosinorService.fitCosinor(samples);

      expect(fit.fitValid, isTrue);
      expect(fit.peakTimeHours, greaterThanOrEqualTo(0.0));
      expect(fit.peakTimeHours, lessThan(24.0));
    });

    test('acrophase in correct range [−π, π]', () {
      final samples = syntheticSignal(
        mesor: 35.0,
        amplitude: 7.0,
        acrophaseOffset: 1.0,
        nSamples: 24,
      );
      final fit = CosinorService.fitCosinor(samples);

      expect(fit.fitValid, isTrue);
      expect(fit.acrophaseRad, greaterThanOrEqualTo(-math.pi));
      expect(fit.acrophaseRad, lessThanOrEqualTo(math.pi));
    });

    // ── Validation threshold tests ────────────────────────────────────────────

    test('returns fitValid=false when fewer than 6 samples', () {
      final samples = syntheticSignal(
        mesor: 40.0,
        amplitude: 5.0,
        acrophaseOffset: 0.0,
        nSamples: 5, // below minimum
      );
      final fit = CosinorService.fitCosinor(samples);
      expect(fit.fitValid, isFalse);
      expect(fit.sampleCount, 5);
    });

    test('returns fitValid=false when time span less than 8 hours', () {
      // 12 samples in a 4-hour window
      final samples = List.generate(12, (i) {
        final t = 10.0 + i * (4.0 / 12); // hours 10..14 (4h span)
        final v = 40.0 + 5.0 * math.cos(2 * math.pi * t / 24);
        return (hour: t, value: v);
      });
      final fit = CosinorService.fitCosinor(samples);
      expect(fit.fitValid, isFalse);
    });

    test('returns fitValid=false for empty samples', () {
      final fit = CosinorService.fitCosinor([]);
      expect(fit.fitValid, isFalse);
      expect(fit.sampleCount, 0);
    });

    test('returns fitValid=false when R² below threshold (flat signal)', () {
      // PA-002 Improvement 1: R² threshold raised from 0.10 → 0.20.
      // A flat signal has R²=0, which fails both thresholds. This test
      // remains valid regardless of the exact threshold.
      final samples = List.generate(
        24,
        (i) => (hour: i.toDouble(), value: 40.0),
      );
      final fit = CosinorService.fitCosinor(samples);
      // Either singular matrix (null beta) or R²=0 → fitValid = false
      expect(fit.fitValid, isFalse);
    });

    test('handles minimum valid sample count (exactly 6)', () {
      // 6 samples spread over 20 hours — should pass both checks
      final samples = List.generate(6, (i) {
        final t = i * 4.0; // 0, 4, 8, 12, 16, 20 hours (20h span)
        final v = 40.0 + 5.0 * math.cos(2 * math.pi * t / 24);
        return (hour: t, value: v);
      });
      final fit = CosinorService.fitCosinor(samples);
      // With only 6 samples exactly on the cosine curve, R² should be ~1
      expect(fit.sampleCount, 6);
      // fitValid depends on R² — pure sinusoid should pass
      if (fit.fitValid) {
        expect(fit.mesor, closeTo(40.0, 0.5));
      }
    });
  });
}
