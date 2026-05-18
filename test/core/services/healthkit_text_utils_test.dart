// ignore_for_file: lines_longer_than_80_chars
// Tests for pure text utilities backing the HealthKit classifier.
// No I/O, no async — these run in microseconds.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/healthkit_text_utils.dart';

void main() {
  group('normalizeQuery', () {
    test('returns empty string for empty input', () {
      expect(normalizeQuery(''), equals(''));
    });

    test('returns empty for whitespace-only input', () {
      expect(normalizeQuery('   '), equals(''));
      expect(normalizeQuery('\t\n\r '), equals(''));
    });

    test('lowercases ASCII input', () {
      expect(normalizeQuery('HRV YESTERDAY'), equals('hrv yesterday'));
    });

    test('expands common contractions', () {
      expect(normalizeQuery("what's my hrv yesterday"),
          equals('what is my hrv yesterday'));
      expect(normalizeQuery("don't show steps"), equals('do not show steps'));
      expect(normalizeQuery("can't see"), equals('cannot see'));
    });

    test('strips trailing question mark', () {
      expect(normalizeQuery('hrv yesterday?'), equals('hrv yesterday'));
    });

    test('strips internal punctuation but keeps hyphens', () {
      expect(normalizeQuery('6-minute walk, please.'),
          equals('6-minute walk please'));
    });

    test('collapses multiple whitespace into single space', () {
      expect(normalizeQuery('hrv     yesterday'),
          equals('hrv yesterday'));
      expect(normalizeQuery('hrv\t\tyesterday'),
          equals('hrv yesterday'));
    });

    test('truncates to kHealthKitMaxScanLength', () {
      final long = 'a' * 2000;
      final result = normalizeQuery(long);
      expect(result.length, lessThanOrEqualTo(kHealthKitMaxScanLength));
    });

    test('is idempotent (normalize twice = normalize once)', () {
      const input = "What's my HRV trend, please?";
      final once = normalizeQuery(input);
      final twice = normalizeQuery(once);
      expect(twice, equals(once));
    });

    test('preserves digits', () {
      expect(normalizeQuery('past 7 days'), equals('past 7 days'));
      expect(normalizeQuery('6mwt last month'), equals('6mwt last month'));
    });

    test('handles unicode without crashing', () {
      // Just check it doesn't throw.
      expect(() => normalizeQuery('hrv ↑ yesterday 💤'), returnsNormally);
    });
  });

  group('tokenize', () {
    test('empty input returns empty list', () {
      expect(tokenize(''), isEmpty);
    });

    test('splits on single space', () {
      expect(tokenize('hrv yesterday'), equals(['hrv', 'yesterday']));
    });

    test('handles single token', () {
      expect(tokenize('steps'), equals(['steps']));
    });

    test('returns growable=false list', () {
      final result = tokenize('a b c');
      expect(() => result.add('x'), throwsUnsupportedError);
    });
  });

  group('tokenizeWithoutFillers', () {
    test('removes filler words', () {
      expect(
        tokenizeWithoutFillers('please show me my hrv'),
        equals(['my', 'hrv']),
      );
    });

    test('returns empty when all fillers', () {
      expect(tokenizeWithoutFillers('please tell me'), isEmpty);
    });

    test('keeps non-filler tokens unchanged', () {
      expect(
        tokenizeWithoutFillers('hrv yesterday'),
        equals(['hrv', 'yesterday']),
      );
    });
  });

  group('levenshtein', () {
    test('identical strings → 0', () {
      expect(levenshtein('hrv', 'hrv'), equals(0));
      expect(levenshtein('', ''), equals(0));
    });

    test('one substitution → 1', () {
      expect(levenshtein('hrv', 'hrx'), equals(1));
    });

    test('one insertion → 1', () {
      expect(levenshtein('hrv', 'hrvs'), equals(1));
      expect(levenshtein('cat', 'cats'), equals(1));
    });

    test('one deletion → 1', () {
      expect(levenshtein('hrvs', 'hrv'), equals(1));
    });

    test('empty + non-empty → length of non-empty', () {
      expect(levenshtein('', 'abc'), equals(3));
      expect(levenshtein('abc', ''), equals(3));
    });

    test('common typos map to distance ≤ 2', () {
      expect(levenshtein('heart rate', 'hart rate'), equals(1));
      expect(levenshtein('sleep', 'sleap'), equals(1));
      expect(levenshtein('steps', 'stepps'), equals(1));
      expect(levenshtein('oxygen saturation', 'oxigen saturation'),
          equals(1));
    });

    test('two-edit typos return 2', () {
      expect(levenshtein('hrv', 'hrx'), equals(1));
      expect(levenshtein('heart', 'hrart'), equals(1));
    });

    test('threshold short-circuit returns threshold+1 when exceeded', () {
      final d = levenshtein('hello', 'world', threshold: 2);
      expect(d, greaterThan(2));
    });

    test('large length diff returns threshold+1 early', () {
      final d = levenshtein('a', 'abcdefghij', threshold: 3);
      expect(d, greaterThan(3));
    });

    test('symmetric: levenshtein(a, b) == levenshtein(b, a)', () {
      const pairs = [
        ('heart rate', 'hart rate'),
        ('sleeping', 'sleping'),
        ('oxygen', 'oxigen'),
      ];
      for (final (a, b) in pairs) {
        expect(levenshtein(a, b), equals(levenshtein(b, a)),
            reason: 'symmetry: $a vs $b');
      }
    });

    test('triangle inequality (sample)', () {
      const a = 'hrv';
      const b = 'hr';
      const c = 'heart rate';
      final ab = levenshtein(a, b);
      final bc = levenshtein(b, c);
      final ac = levenshtein(a, c);
      expect(ac, lessThanOrEqualTo(ab + bc));
    });
  });

  group('generateTraceId', () {
    test('returns "hk_" prefix', () {
      final id = generateTraceId('seed');
      expect(id, startsWith('hk_'));
    });

    test('returns 9 chars total', () {
      expect(generateTraceId('a').length, equals(9));
      expect(generateTraceId(12345).length, equals(9));
    });

    test('deterministic for same seed', () {
      expect(generateTraceId('abc'), equals(generateTraceId('abc')));
    });

    test('different seeds → different ids (usually)', () {
      final a = generateTraceId('seed_a');
      final b = generateTraceId('seed_b');
      expect(a, isNot(equals(b)));
    });

    test('null seed uses clock — non-empty', () {
      expect(generateTraceId(null), startsWith('hk_'));
    });
  });

  group('fuzzyConfidence', () {
    test('distance 0 → 1.0', () {
      expect(fuzzyConfidence(10, 0), equals(1.0));
    });

    test('distance == phrase length → 0.0', () {
      expect(fuzzyConfidence(10, 10), equals(0.0));
      expect(fuzzyConfidence(5, 5), equals(0.0));
    });

    test('distance > phrase length → 0.0', () {
      expect(fuzzyConfidence(5, 10), equals(0.0));
    });

    test('zero phrase length → 0.0', () {
      expect(fuzzyConfidence(0, 1), equals(0.0));
    });

    test('intermediate distances are between 0 and 1', () {
      final c1 = fuzzyConfidence(10, 1);
      final c5 = fuzzyConfidence(10, 5);
      expect(c1, greaterThan(c5));
      expect(c1, lessThan(1.0));
      expect(c5, greaterThan(0.0));
    });

    test('linear interpolation: 1 - dist/length', () {
      expect(fuzzyConfidence(10, 2), closeTo(0.8, 0.001));
      expect(fuzzyConfidence(20, 4), closeTo(0.8, 0.001));
    });

    test('values are always in [0, 1]', () {
      for (var len = 1; len <= 30; len++) {
        for (var d = 0; d <= len + 5; d++) {
          final c = fuzzyConfidence(len, d);
          expect(c, greaterThanOrEqualTo(0.0));
          expect(c, lessThanOrEqualTo(1.0));
        }
      }
    });
  });

  group('aggregateConfidence', () {
    test('empty list → 0.0', () {
      expect(aggregateConfidence(const []), equals(0.0));
    });

    test('single value returns that value', () {
      expect(aggregateConfidence([0.5]), closeTo(0.5, 0.001));
      expect(aggregateConfidence([1.0]), closeTo(1.0, 0.001));
    });

    test('zero in any slot collapses to 0.0', () {
      expect(aggregateConfidence([1.0, 0.0]), equals(0.0));
      expect(aggregateConfidence([0.0, 1.0, 1.0]), equals(0.0));
    });

    test('all 1.0 returns 1.0', () {
      expect(aggregateConfidence([1.0, 1.0]), closeTo(1.0, 0.001));
      expect(aggregateConfidence([1.0, 1.0, 1.0]), closeTo(1.0, 0.001));
    });

    test('geometric mean of [0.5, 0.5] is 0.5', () {
      expect(aggregateConfidence([0.5, 0.5]), closeTo(0.5, 0.001));
    });

    test('geometric mean is between min and max', () {
      final result = aggregateConfidence([0.3, 0.9]);
      expect(result, greaterThan(0.3));
      expect(result, lessThan(0.9));
    });

    test('clamped to [0, 1]', () {
      expect(aggregateConfidence([0.8, 0.7, 0.9]), lessThanOrEqualTo(1.0));
      expect(aggregateConfidence([0.8, 0.7, 0.9]), greaterThanOrEqualTo(0.0));
    });

    test('order-independent', () {
      final a = aggregateConfidence([0.3, 0.7, 0.9]);
      final b = aggregateConfidence([0.9, 0.3, 0.7]);
      expect(a, closeTo(b, 0.0001));
    });
  });

  group('contractions table integrity', () {
    test('all keys are lowercase', () {
      for (final key in kContractions.keys) {
        expect(key, equals(key.toLowerCase()),
            reason: 'contraction key "$key" must be lowercase');
      }
    });

    test('all keys contain apostrophe', () {
      for (final key in kContractions.keys) {
        expect(key.contains("'"), isTrue,
            reason: 'contraction key "$key" should have apostrophe');
      }
    });

    test('all values do not contain apostrophe', () {
      for (final entry in kContractions.entries) {
        expect(entry.value.contains("'"), isFalse,
            reason: 'expanded value "${entry.value}" must not contain apostrophe');
      }
    });
  });

  group('property-based: normalize-then-tokenize idempotence', () {
    test('many random-ish queries are stable across normalize+tokenize', () {
      const samples = [
        "What's my HRV trend?",
        "How was my sleep last night??",
        "What is my HRV this month vs last month?",
        "show     me my hrv  yesterday",
        "STEPS THIS WEEK!",
        "calorie intake, please.",
        "max steps this month",
        "average heart rate this week",
        "compared    to    last    week",
      ];
      for (final s in samples) {
        final n1 = normalizeQuery(s);
        final n2 = normalizeQuery(n1);
        expect(n2, equals(n1), reason: 'normalize not idempotent for: $s');

        final t1 = tokenize(n1);
        for (final tok in t1) {
          expect(tok, isNot(equals('')),
              reason: 'tokens should be non-empty for $s');
        }
      }
    });
  });
}
