// In-memory observability for the HealthKit intent pipeline.
//
// Contract:
//   - PHI-safe: NEVER records the raw query text, normalized text, or any
//     numeric value returned to the user. Only attribute keys & resolution
//     status are stored.
//   - Bounded: ring buffer with [maxEvents] capacity; oldest events evicted.
//   - Lock-free: single-threaded Dart isolate semantics; no synchronisation.
//   - Non-throwing: every method swallows exceptions in production usage.
//
// Intended consumers: dashboard charts, regression detection, A/B analysis.

import 'healthkit_intent.dart';

/// Single telemetry event. Immutable.
class HealthKitTelemetryEvent {
  HealthKitTelemetryEvent({
    required this.timestamp,
    required this.eventName,
    required this.traceId,
    required this.attributes,
    this.latencyMs,
  });

  /// When the event was recorded (UTC). Used for time-window aggregations.
  final DateTime timestamp;

  /// Stable event name (e.g. 'intent_classified', 'aggregation_executed').
  final String eventName;

  /// Trace id from [HealthKitIntent.traceId] for cross-event correlation.
  final String traceId;

  /// Latency in milliseconds for this stage (null when not a timed event).
  final int? latencyMs;

  /// Attribute bag (PHI-redacted before being passed in).
  final Map<String, Object?> attributes;
}

/// Aggregated metrics over a recent window. Returned by
/// [HealthKitTelemetry.summary] for dashboards.
class HealthKitTelemetrySummary {
  const HealthKitTelemetrySummary({
    required this.totalEvents,
    required this.classifications,
    required this.resolvedRate,
    required this.futureWindowRate,
    required this.fuzzyMatchRate,
    required this.medianLatencyMs,
    required this.p95LatencyMs,
    required this.variantCounts,
    required this.aggregationOverrideCounts,
    required this.confidenceTierCounts,
  });

  final int totalEvents;
  final int classifications;

  /// Fraction of classifications where intent.isResolved == true.
  final double resolvedRate;

  /// Fraction of classifications where intent.isFutureWindow == true.
  final double futureWindowRate;

  /// Fraction of classifications where a fuzzy match was used.
  final double fuzzyMatchRate;

  /// Median latency across the window (rounded to int ms).
  final int medianLatencyMs;

  /// P95 latency (rounded). Production SLO: ≤ 50 ms on-device.
  final int p95LatencyMs;

  /// Count of classifications per variant id.
  final Map<String, int> variantCounts;

  /// Count per aggregation method (e.g. 'max', 'median', 'defaultForMetric').
  final Map<String, int> aggregationOverrideCounts;

  /// Count per IntentConfidenceTier name.
  final Map<String, int> confidenceTierCounts;

  Map<String, Object?> toMap() => {
        'total_events': totalEvents,
        'classifications': classifications,
        'resolved_rate':
            double.parse(resolvedRate.toStringAsFixed(3)),
        'future_window_rate':
            double.parse(futureWindowRate.toStringAsFixed(3)),
        'fuzzy_match_rate':
            double.parse(fuzzyMatchRate.toStringAsFixed(3)),
        'median_latency_ms': medianLatencyMs,
        'p95_latency_ms': p95LatencyMs,
        'variant_counts': Map<String, int>.from(variantCounts),
        'aggregation_override_counts':
            Map<String, int>.from(aggregationOverrideCounts),
        'confidence_tier_counts':
            Map<String, int>.from(confidenceTierCounts),
      };
}

/// In-memory telemetry sink with bounded retention.
class HealthKitTelemetry {
  HealthKitTelemetry({
    int maxEvents = 1000,
    DateTime Function()? clock,
  })  : _maxEvents = maxEvents < 1 ? 1 : maxEvents,
        _clock = clock ?? (() => DateTime.now().toUtc());

  final int _maxEvents;
  final DateTime Function() _clock;
  final List<HealthKitTelemetryEvent> _ring = <HealthKitTelemetryEvent>[];

  /// Returns an unmodifiable view of currently-buffered events.
  List<HealthKitTelemetryEvent> get events => List.unmodifiable(_ring);

  /// Clears all buffered events. Used by tests.
  void reset() => _ring.clear();

  /// Records the outcome of [HealthKitIntentClassifier.classify].
  void recordClassification({
    required HealthKitIntent intent,
    required int latencyMs,
  }) {
    _record(
      eventName: 'intent_classified',
      traceId: intent.traceId,
      latencyMs: latencyMs,
      attributes: {
        ...intent.toTelemetryAttributes(),
        'used_fuzzy': intent.diagnostics
            .any((d) => d.signal == 'fuzzy_phrase'),
        'diagnostics_count': intent.diagnostics.length,
      },
    );
  }

  /// Records the outcome of an aggregation execution.
  void recordExecution({
    required String traceId,
    required String metricDbName,
    required int latencyMs,
    required int sampleDays,
    required bool hadValue,
    String? aggregationMethod,
  }) {
    _record(
      eventName: 'aggregation_executed',
      traceId: traceId,
      latencyMs: latencyMs,
      attributes: {
        'metric_db_name': metricDbName,
        'sample_days': sampleDays,
        'had_value': hadValue,
        if (aggregationMethod != null) 'aggregation': aggregationMethod,
      },
    );
  }

  /// Records a render-stage event.
  void recordRender({
    required String traceId,
    required int latencyMs,
    required int responseLength,
    required bool isComparison,
    required bool isMultiMetric,
  }) {
    _record(
      eventName: 'response_rendered',
      traceId: traceId,
      latencyMs: latencyMs,
      attributes: {
        'response_length_bucket': _lengthBucket(responseLength),
        'is_comparison': isComparison,
        'is_multi_metric': isMultiMetric,
      },
    );
  }

  /// Records a routing decision (which variant served the query).
  void recordRouting({
    required String traceId,
    required String variantId,
    required String routeName,
  }) {
    _record(
      eventName: 'route_selected',
      traceId: traceId,
      latencyMs: null,
      attributes: {
        'variant_id': variantId,
        'route_name': routeName,
      },
    );
  }

  /// Aggregates buffered events into [HealthKitTelemetrySummary].
  /// If [since] is provided only events after that timestamp are considered.
  HealthKitTelemetrySummary summary({DateTime? since}) {
    final filtered = since == null
        ? _ring
        : _ring.where((e) => e.timestamp.isAfter(since)).toList();

    final classifications =
        filtered.where((e) => e.eventName == 'intent_classified').toList();

    var resolved = 0;
    var future = 0;
    var fuzzy = 0;
    final latencies = <int>[];
    final variants = <String, int>{};
    final aggCounts = <String, int>{};
    final tierCounts = <String, int>{};

    for (final e in classifications) {
      final attrs = e.attributes;
      if (attrs['metric_resolved'] == true &&
          attrs['window_resolved'] == true &&
          attrs['is_future_window'] == false) {
        resolved++;
      }
      if (attrs['is_future_window'] == true) future++;
      if (attrs['used_fuzzy'] == true) fuzzy++;
      final lat = e.latencyMs;
      if (lat != null) latencies.add(lat);
      final variant = attrs['variant_id'] as String?;
      if (variant != null) {
        variants[variant] = (variants[variant] ?? 0) + 1;
      }
      final agg = attrs['aggregation'] as String?;
      if (agg != null) {
        aggCounts[agg] = (aggCounts[agg] ?? 0) + 1;
      }
      final tier = attrs['confidence_tier'] as String?;
      if (tier != null) {
        tierCounts[tier] = (tierCounts[tier] ?? 0) + 1;
      }
    }

    final classCount = classifications.length;
    final medianLat = _percentile(latencies, 0.5);
    final p95Lat = _percentile(latencies, 0.95);

    return HealthKitTelemetrySummary(
      totalEvents: filtered.length,
      classifications: classCount,
      resolvedRate: classCount == 0 ? 0.0 : resolved / classCount,
      futureWindowRate: classCount == 0 ? 0.0 : future / classCount,
      fuzzyMatchRate: classCount == 0 ? 0.0 : fuzzy / classCount,
      medianLatencyMs: medianLat,
      p95LatencyMs: p95Lat,
      variantCounts: Map.unmodifiable(variants),
      aggregationOverrideCounts: Map.unmodifiable(aggCounts),
      confidenceTierCounts: Map.unmodifiable(tierCounts),
    );
  }

  void _record({
    required String eventName,
    required String traceId,
    required Map<String, Object?> attributes,
    int? latencyMs,
  }) {
    if (_ring.length >= _maxEvents) {
      _ring.removeAt(0);
    }
    _ring.add(HealthKitTelemetryEvent(
      timestamp: _clock(),
      eventName: eventName,
      traceId: traceId,
      latencyMs: latencyMs,
      attributes: Map.unmodifiable(_scrubAttributes(attributes)),
    ));
  }

  /// Strips any keys that could carry PHI. Defensive — callers should already
  /// have scrubbed, but we double-check to harden the boundary.
  Map<String, Object?> _scrubAttributes(Map<String, Object?> attrs) {
    const banned = {
      'raw_query',
      'normalized_query',
      'value',
      'numeric_value',
      'response_text',
      'rendered_text',
      'metric_value',
    };
    final out = <String, Object?>{};
    for (final entry in attrs.entries) {
      if (banned.contains(entry.key.toLowerCase())) continue;
      final v = entry.value;
      if (v is String || v is num || v is bool || v == null) {
        out[entry.key] = v;
      } else if (v is List) {
        out[entry.key] = v.length;
      } else if (v is Map) {
        out[entry.key] = v.length;
      } else {
        out[entry.key] = v.toString();
      }
    }
    return out;
  }

  String _lengthBucket(int length) {
    if (length <= 50) return '0-50';
    if (length <= 150) return '51-150';
    if (length <= 300) return '151-300';
    if (length <= 600) return '301-600';
    return '600+';
  }

  int _percentile(List<int> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.from(values)..sort();
    final idx = (p * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }
}
