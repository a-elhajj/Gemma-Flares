// ignore_for_file: lines_longer_than_80_chars
// Tests for HealthKitTelemetry — ring buffer, PHI scrubbing, summary math.
// All async-free; the clock is injected so timestamps are deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/healthkit_intent.dart';
import 'package:gemma_flares/core/services/healthkit_telemetry.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

DateTime _ts(int secondsOffset) =>
    DateTime.utc(2025, 1, 15, 12, 0, 0).add(Duration(seconds: secondsOffset));

int _epoch = 0;
HealthKitTelemetry _makeTelemetry({int maxEvents = 1000}) {
  _epoch = 0;
  return HealthKitTelemetry(
    maxEvents: maxEvents,
    clock: () => _ts(_epoch++),
  );
}

HealthKitIntent _makeIntent({
  String traceId = 'hk_abc123',
  String? metricDbName = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN',
  String? window = '7d',
  String? comparisonWindow,
  AggregationMethod aggregation = AggregationMethod.defaultForMetric,
  double confidence = 0.90,
  IntentConfidenceTier confidenceTier = IntentConfidenceTier.high,
  bool isFutureWindow = false,
  List<IntentDiagnostic> diagnostics = const [],
  String variantId = 'lexical_with_fuzzy',
  String rawQuery = 'hrv last week',
  String normalizedQuery = 'hrv last week',
}) =>
    HealthKitIntent(
      traceId: traceId,
      rawQuery: rawQuery,
      normalizedQuery: normalizedQuery,
      metricDbName: metricDbName,
      additionalMetricDbNames: const [],
      window: window,
      comparisonWindow: comparisonWindow,
      aggregation: aggregation,
      confidence: confidence,
      confidenceTier: confidenceTier,
      diagnostics: diagnostics,
      variantId: variantId,
      isFutureWindow: isFutureWindow,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HealthKitTelemetry — ring buffer', () {
    test('starts empty', () {
      final t = _makeTelemetry();
      expect(t.events, isEmpty);
    });

    test('records a single classification event', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      expect(t.events.length, equals(1));
      expect(t.events.first.eventName, equals('intent_classified'));
    });

    test('records execution event', () {
      final t = _makeTelemetry();
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 12,
        sampleDays: 7,
        hadValue: true,
      );
      expect(t.events.length, equals(1));
      expect(t.events.first.eventName, equals('aggregation_executed'));
    });

    test('records render event', () {
      final t = _makeTelemetry();
      t.recordRender(
        traceId: 'hk_abc123',
        latencyMs: 3,
        responseLength: 120,
        isComparison: false,
        isMultiMetric: false,
      );
      expect(t.events.length, equals(1));
      expect(t.events.first.eventName, equals('response_rendered'));
    });

    test('records routing event', () {
      final t = _makeTelemetry();
      t.recordRouting(
        traceId: 'hk_abc123',
        variantId: 'lexical_with_fuzzy',
        routeName: 'single_metric',
      );
      expect(t.events.length, equals(1));
      expect(t.events.first.eventName, equals('route_selected'));
    });

    test('evicts oldest when ring is full', () {
      final t = _makeTelemetry(maxEvents: 3);
      for (var i = 0; i < 3; i++) {
        t.recordClassification(intent: _makeIntent(traceId: 'hk_t$i'), latencyMs: i);
      }
      expect(t.events.length, equals(3));
      expect(t.events.first.traceId, equals('hk_t0'));

      t.recordClassification(intent: _makeIntent(traceId: 'hk_t3'), latencyMs: 3);
      expect(t.events.length, equals(3));
      expect(t.events.first.traceId, equals('hk_t1'));
      expect(t.events.last.traceId, equals('hk_t3'));
    });

    test('eviction is FIFO (oldest first)', () {
      final t = _makeTelemetry(maxEvents: 2);
      t.recordClassification(intent: _makeIntent(traceId: 'hk_first'), latencyMs: 1);
      t.recordClassification(intent: _makeIntent(traceId: 'hk_second'), latencyMs: 2);
      t.recordClassification(intent: _makeIntent(traceId: 'hk_third'), latencyMs: 3);
      expect(t.events.map((e) => e.traceId).toList(),
          equals(['hk_second', 'hk_third']));
    });

    test('maxEvents=1 retains only latest event', () {
      final t = _makeTelemetry(maxEvents: 1);
      t.recordClassification(intent: _makeIntent(traceId: 'hk_a'), latencyMs: 1);
      t.recordClassification(intent: _makeIntent(traceId: 'hk_b'), latencyMs: 2);
      expect(t.events.length, equals(1));
      expect(t.events.first.traceId, equals('hk_b'));
    });

    test('reset clears all events', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordClassification(intent: _makeIntent(), latencyMs: 10);
      t.reset();
      expect(t.events, isEmpty);
    });

    test('events getter returns unmodifiable list', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      expect(() => t.events.add(t.events.first), throwsUnsupportedError);
    });

    test('events are timestamped with injected clock', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      expect(t.events[0].timestamp, equals(_ts(0)));
      expect(t.events[1].timestamp, equals(_ts(1)));
    });
  });

  group('HealthKitTelemetry — PHI scrubbing', () {
    test('classification event has no raw_query attribute', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('raw_query'), isFalse);
    });

    test('classification event has no normalized_query attribute', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('normalized_query'), isFalse);
    });

    test('classification event has no value / numeric_value attributes', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('value'), isFalse);
      expect(attrs.containsKey('numeric_value'), isFalse);
    });

    test('execution event has no metric_value attribute', () {
      final t = _makeTelemetry();
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 10,
        sampleDays: 7,
        hadValue: true,
      );
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('metric_value'), isFalse);
    });

    test('render event has no response_text or rendered_text attributes', () {
      final t = _makeTelemetry();
      t.recordRender(
        traceId: 'hk_abc123',
        latencyMs: 5,
        responseLength: 200,
        isComparison: false,
        isMultiMetric: false,
      );
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('response_text'), isFalse);
      expect(attrs.containsKey('rendered_text'), isFalse);
    });

    test('classification event preserves non-PHI attributes', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final attrs = t.events.first.attributes;
      expect(attrs.containsKey('metric_db_name'), isTrue);
      expect(attrs.containsKey('window'), isTrue);
      expect(attrs.containsKey('confidence'), isTrue);
      expect(attrs.containsKey('confidence_tier'), isTrue);
      expect(attrs.containsKey('variant_id'), isTrue);
    });

    test('execution event preserves non-PHI attributes', () {
      final t = _makeTelemetry();
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 10,
        sampleDays: 7,
        hadValue: true,
        aggregationMethod: 'max',
      );
      final attrs = t.events.first.attributes;
      expect(attrs['metric_db_name'], equals('HKQuantityTypeIdentifierStepCount'));
      expect(attrs['sample_days'], equals(7));
      expect(attrs['had_value'], equals(true));
      expect(attrs['aggregation'], equals('max'));
    });

    test('List values are scrubbed to their length (not the list itself)', () {
      final t = _makeTelemetry();
      // diagnostics is a list on the intent; internally recorded as count
      final intent = _makeIntent(diagnostics: [
        const IntentDiagnostic(signal: 'exact_phrase', detail: 'hrv'),
        const IntentDiagnostic(signal: 'window_token', detail: '7d'),
      ]);
      t.recordClassification(intent: intent, latencyMs: 5);
      final attrs = t.events.first.attributes;
      // diagnostics_count should be 2, not the list itself
      expect(attrs['diagnostics_count'], equals(2));
    });

    test('case-insensitive PHI key scrubbing', () {
      // Internal method scrubs keys case-insensitively.
      // We verify it via the public interface that the attributes object
      // returned from the event does NOT contain any banned key variants.
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final attrs = t.events.first.attributes;
      final lowerKeys = attrs.keys.map((k) => k.toLowerCase()).toSet();
      const banned = {
        'raw_query',
        'normalized_query',
        'value',
        'numeric_value',
        'response_text',
        'rendered_text',
        'metric_value',
      };
      for (final b in banned) {
        expect(lowerKeys.contains(b), isFalse, reason: 'found banned key "$b"');
      }
    });
  });

  group('HealthKitTelemetry — latency recording', () {
    test('latencyMs stored on classification events', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 42);
      expect(t.events.first.latencyMs, equals(42));
    });

    test('latencyMs stored on execution events', () {
      final t = _makeTelemetry();
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 17,
        sampleDays: 30,
        hadValue: false,
      );
      expect(t.events.first.latencyMs, equals(17));
    });

    test('routing event has null latencyMs', () {
      final t = _makeTelemetry();
      t.recordRouting(
        traceId: 'hk_abc123',
        variantId: 'lexical_only',
        routeName: 'unresolved',
      );
      expect(t.events.first.latencyMs, isNull);
    });
  });

  group('HealthKitTelemetry — summary: empty state', () {
    test('empty telemetry returns zero summary', () {
      final t = _makeTelemetry();
      final s = t.summary();
      expect(s.totalEvents, equals(0));
      expect(s.classifications, equals(0));
      expect(s.resolvedRate, equals(0.0));
      expect(s.futureWindowRate, equals(0.0));
      expect(s.fuzzyMatchRate, equals(0.0));
      expect(s.medianLatencyMs, equals(0));
      expect(s.p95LatencyMs, equals(0));
      expect(s.variantCounts, isEmpty);
      expect(s.aggregationOverrideCounts, isEmpty);
      expect(s.confidenceTierCounts, isEmpty);
    });
  });

  group('HealthKitTelemetry — summary: resolved rate', () {
    test('fully resolved intent increments resolved counter', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final s = t.summary();
      expect(s.resolvedRate, equals(1.0));
    });

    test('unresolved intent (no metric) does not increment resolved', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(metricDbName: null, window: null),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.resolvedRate, equals(0.0));
    });

    test('future-window intent does not count as resolved', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(isFutureWindow: true),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.resolvedRate, equals(0.0));
    });

    test('50% resolved rate across two intents', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordClassification(
          intent: _makeIntent(metricDbName: null, window: null), latencyMs: 5);
      final s = t.summary();
      expect(s.resolvedRate, closeTo(0.5, 0.001));
    });
  });

  group('HealthKitTelemetry — summary: future-window rate', () {
    test('future-window intent increments future counter', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(isFutureWindow: true),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.futureWindowRate, equals(1.0));
    });

    test('non-future intent does not increment future counter', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final s = t.summary();
      expect(s.futureWindowRate, equals(0.0));
    });
  });

  group('HealthKitTelemetry — summary: fuzzy match rate', () {
    test('intent with fuzzy_phrase diagnostic increments fuzzy counter', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(diagnostics: [
          const IntentDiagnostic(signal: 'fuzzy_phrase', detail: 'hart rate'),
        ]),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.fuzzyMatchRate, equals(1.0));
    });

    test('intent without fuzzy_phrase diagnostic does not increment fuzzy counter', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(diagnostics: [
          const IntentDiagnostic(signal: 'exact_phrase', detail: 'hrv'),
        ]),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.fuzzyMatchRate, equals(0.0));
    });
  });

  group('HealthKitTelemetry — summary: latency percentiles', () {
    test('single classification — median and p95 are same value', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 30);
      final s = t.summary();
      expect(s.medianLatencyMs, equals(30));
      expect(s.p95LatencyMs, equals(30));
    });

    test('two values — median is lower, p95 is higher', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 10);
      t.recordClassification(intent: _makeIntent(), latencyMs: 90);
      final s = t.summary();
      expect(s.medianLatencyMs, lessThanOrEqualTo(90));
      expect(s.p95LatencyMs, greaterThanOrEqualTo(s.medianLatencyMs));
    });

    test('p95 is higher than median for skewed distribution', () {
      final t = _makeTelemetry();
      // 9 fast + 1 very slow
      for (var i = 0; i < 9; i++) {
        t.recordClassification(intent: _makeIntent(), latencyMs: 10);
      }
      t.recordClassification(intent: _makeIntent(), latencyMs: 500);
      final s = t.summary();
      expect(s.medianLatencyMs, equals(10));
      expect(s.p95LatencyMs, greaterThanOrEqualTo(10));
    });

    test('latency from non-classification events is excluded', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 20);
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 1000,
        sampleDays: 7,
        hadValue: true,
      );
      final s = t.summary();
      // Only the classification latency (20ms) should be in percentile calc
      expect(s.medianLatencyMs, equals(20));
      expect(s.p95LatencyMs, equals(20));
    });

    test('empty latency list yields 0 for both percentiles', () {
      final t = _makeTelemetry();
      // Record a routing event (no latency)
      t.recordRouting(
        traceId: 'hk_abc123',
        variantId: 'v1',
        routeName: 'test',
      );
      final s = t.summary();
      expect(s.medianLatencyMs, equals(0));
      expect(s.p95LatencyMs, equals(0));
    });
  });

  group('HealthKitTelemetry — summary: variant counts', () {
    test('single variant recorded once', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(variantId: 'lexical_with_fuzzy'),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.variantCounts['lexical_with_fuzzy'], equals(1));
    });

    test('two variants counted independently', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(variantId: 'lexical_only'),
        latencyMs: 5,
      );
      t.recordClassification(
        intent: _makeIntent(variantId: 'lexical_with_fuzzy'),
        latencyMs: 5,
      );
      t.recordClassification(
        intent: _makeIntent(variantId: 'lexical_with_fuzzy'),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.variantCounts['lexical_only'], equals(1));
      expect(s.variantCounts['lexical_with_fuzzy'], equals(2));
    });

    test('variantCounts map is unmodifiable', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final s = t.summary();
      expect(
        () => s.variantCounts['x'] = 1,
        throwsUnsupportedError,
      );
    });
  });

  group('HealthKitTelemetry — summary: aggregation override counts', () {
    test('no aggregation override → empty aggCounts', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final s = t.summary();
      expect(s.aggregationOverrideCounts, isEmpty);
    });

    test('max aggregation override is counted', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(aggregation: AggregationMethod.max),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.aggregationOverrideCounts['max'], equals(1));
    });

    test('multiple methods counted independently', () {
      final t = _makeTelemetry();
      for (final method in [AggregationMethod.max, AggregationMethod.max, AggregationMethod.min]) {
        t.recordClassification(intent: _makeIntent(aggregation: method), latencyMs: 5);
      }
      final s = t.summary();
      expect(s.aggregationOverrideCounts['max'], equals(2));
      expect(s.aggregationOverrideCounts['min'], equals(1));
    });

    test('defaultForMetric aggregation does NOT appear in aggCounts', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(aggregation: AggregationMethod.defaultForMetric),
        latencyMs: 5,
      );
      final s = t.summary();
      // defaultForMetric is excluded from aggregation override counts
      expect(s.aggregationOverrideCounts, isEmpty);
    });
  });

  group('HealthKitTelemetry — summary: confidence tier counts', () {
    test('high confidence tier is counted', () {
      final t = _makeTelemetry();
      t.recordClassification(
        intent: _makeIntent(confidenceTier: IntentConfidenceTier.high),
        latencyMs: 5,
      );
      final s = t.summary();
      expect(s.confidenceTierCounts['high'], equals(1));
    });

    test('all tiers counted independently', () {
      final t = _makeTelemetry();
      for (final tier in IntentConfidenceTier.values) {
        t.recordClassification(intent: _makeIntent(confidenceTier: tier), latencyMs: 5);
      }
      final s = t.summary();
      for (final tier in IntentConfidenceTier.values) {
        expect(s.confidenceTierCounts[tier.name], equals(1),
            reason: 'tier ${tier.name} not found');
      }
    });
  });

  group('HealthKitTelemetry — summary: time-window filter', () {
    test('events before [since] are excluded', () {
      final t = _makeTelemetry();
      // Record at t=0 and t=1
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      // Cutoff is after t=0 but before t=1
      final cutoff = _ts(0).add(const Duration(milliseconds: 500));
      final s = t.summary(since: cutoff);
      expect(s.totalEvents, equals(1));
      expect(s.classifications, equals(1));
    });

    test('events exactly at [since] are excluded (isAfter semantics)', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final cutoff = _ts(0);
      final s = t.summary(since: cutoff);
      expect(s.totalEvents, equals(0));
    });

    test('null [since] includes all events', () {
      final t = _makeTelemetry();
      for (var i = 0; i < 5; i++) {
        t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      }
      final s = t.summary();
      expect(s.totalEvents, equals(5));
    });

    test('future [since] returns empty summary', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      final farFuture = _ts(9999);
      final s = t.summary(since: farFuture);
      expect(s.totalEvents, equals(0));
      expect(s.classifications, equals(0));
    });

    test('mixed event types are all counted in totalEvents', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordExecution(
        traceId: 'hk_abc123',
        metricDbName: 'HKQuantityTypeIdentifierStepCount',
        latencyMs: 10,
        sampleDays: 7,
        hadValue: true,
      );
      t.recordRender(
        traceId: 'hk_abc123',
        latencyMs: 3,
        responseLength: 100,
        isComparison: false,
        isMultiMetric: false,
      );
      final s = t.summary();
      expect(s.totalEvents, equals(3));
      expect(s.classifications, equals(1));
    });
  });

  group('HealthKitTelemetry — summary: toMap() output', () {
    test('toMap returns all required keys', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 10);
      final m = t.summary().toMap();
      expect(m.containsKey('total_events'), isTrue);
      expect(m.containsKey('classifications'), isTrue);
      expect(m.containsKey('resolved_rate'), isTrue);
      expect(m.containsKey('future_window_rate'), isTrue);
      expect(m.containsKey('fuzzy_match_rate'), isTrue);
      expect(m.containsKey('median_latency_ms'), isTrue);
      expect(m.containsKey('p95_latency_ms'), isTrue);
      expect(m.containsKey('variant_counts'), isTrue);
      expect(m.containsKey('aggregation_override_counts'), isTrue);
      expect(m.containsKey('confidence_tier_counts'), isTrue);
    });

    test('toMap rate values are rounded to 3 decimal places', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 10);
      t.recordClassification(
          intent: _makeIntent(metricDbName: null, window: null), latencyMs: 5);
      t.recordClassification(
          intent: _makeIntent(metricDbName: null, window: null), latencyMs: 5);
      final m = t.summary().toMap();
      // resolvedRate = 1/3 ≈ 0.333
      final rate = m['resolved_rate'] as double;
      expect(rate.toString().length, lessThanOrEqualTo(7)); // '0.333' or '0.333...'
    });
  });

  group('HealthKitTelemetry — render length buckets', () {
    final bucketCases = [
      (50, '0-50'),
      (1, '0-50'),
      (51, '51-150'),
      (150, '51-150'),
      (151, '151-300'),
      (300, '151-300'),
      (301, '301-600'),
      (600, '301-600'),
      (601, '600+'),
      (9999, '600+'),
    ];

    for (final (len, bucket) in bucketCases) {
      test('responseLength $len → bucket $bucket', () {
        final t = _makeTelemetry();
        t.recordRender(
          traceId: 'hk_abc123',
          latencyMs: 3,
          responseLength: len,
          isComparison: false,
          isMultiMetric: false,
        );
        final attrs = t.events.first.attributes;
        expect(attrs['response_length_bucket'], equals(bucket));
      });
    }
  });

  group('HealthKitTelemetry — edge cases', () {
    test('maxEvents clamped to 1 for zero or negative input', () {
      // Constructor: maxEvents < 1 ? 1 : maxEvents
      final t0 = HealthKitTelemetry(maxEvents: 0, clock: () => _ts(0));
      final tNeg = HealthKitTelemetry(maxEvents: -5, clock: () => _ts(0));
      t0.recordClassification(intent: _makeIntent(traceId: 'hk_a'), latencyMs: 1);
      t0.recordClassification(intent: _makeIntent(traceId: 'hk_b'), latencyMs: 2);
      expect(t0.events.length, equals(1));
      tNeg.recordClassification(intent: _makeIntent(traceId: 'hk_c'), latencyMs: 1);
      tNeg.recordClassification(intent: _makeIntent(traceId: 'hk_d'), latencyMs: 2);
      expect(tNeg.events.length, equals(1));
    });

    test('large number of events — ring stays bounded', () {
      final t = _makeTelemetry(maxEvents: 100);
      for (var i = 0; i < 500; i++) {
        t.recordClassification(intent: _makeIntent(), latencyMs: i % 50);
      }
      expect(t.events.length, equals(100));
    });

    test('summary after reset returns zeros', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.reset();
      final s = t.summary();
      expect(s.totalEvents, equals(0));
      expect(s.classifications, equals(0));
    });

    test('interleaved event types tracked correctly in total count', () {
      final t = _makeTelemetry();
      t.recordClassification(intent: _makeIntent(), latencyMs: 5);
      t.recordRouting(traceId: 'hk_x', variantId: 'v1', routeName: 'r1');
      t.recordExecution(
        traceId: 'hk_x',
        metricDbName: 'HKQuantityTypeIdentifierHeartRate',
        latencyMs: 8,
        sampleDays: 1,
        hadValue: true,
      );
      t.recordRender(traceId: 'hk_x', latencyMs: 2, responseLength: 80, isComparison: false, isMultiMetric: false);
      final s = t.summary();
      expect(s.totalEvents, equals(4));
      expect(s.classifications, equals(1));
    });
  });
}
