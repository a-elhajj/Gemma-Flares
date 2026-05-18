// HealthKit intent value types — produced by [HealthKitIntentClassifier] and
// consumed by [WearableAggregationService] and the local agent reply pipeline.
//
// Design contract
//   1. All types are immutable; copy-with semantics use [copyWith].
//   2. No PHI is ever embedded in diagnostics or trace metadata.
//   3. Confidence is a unit interval [0.0, 1.0] — never NaN or out-of-range.
//   4. Identifiers (traceId, variantId) are short opaque strings — safe to log.

import 'wearable_aggregation_service.dart' show WearableWindow;

/// How a metric should be aggregated when reducing daily values to a single
/// answer. The classifier sets this from explicit user keywords; if none are
/// detected it returns [AggregationMethod.defaultForMetric] and the service
/// falls back to the metric's natural rule (sum/avg/total/latest).
enum AggregationMethod {
  /// Use the metric's per-spec rule (sum for steps, avg for HRV, …).
  defaultForMetric,

  /// Arithmetic mean across the window's daily values.
  average,

  /// Cumulative sum across the window. Identical to [total].
  sum,

  /// Cumulative sum (alias for [sum] — user keyword: "total").
  total,

  /// Largest single-day value in the window.
  max,

  /// Smallest single-day value in the window.
  min,

  /// Middle value after sorting — robust to one-day outliers.
  median,

  /// Most recent non-null reading (sparse metrics like VO₂ max).
  latest,
}

extension AggregationMethodLabel on AggregationMethod {
  /// Stable, user-visible label safe for response rendering.
  String get displayLabel {
    return switch (this) {
      AggregationMethod.defaultForMetric => '',
      AggregationMethod.average => 'average',
      AggregationMethod.sum => 'total',
      AggregationMethod.total => 'total',
      AggregationMethod.max => 'peak',
      AggregationMethod.min => 'lowest',
      AggregationMethod.median => 'median',
      AggregationMethod.latest => 'most recent',
    };
  }

  /// Wire-safe string used in telemetry attributes.
  String get wireName => name;
}

/// Qualitative classification confidence — drives whether the agent should
/// answer deterministically, hedge, or hand off to a generative path.
enum IntentConfidenceTier {
  /// All required slots filled with high per-slot confidence (≥ 0.85 each).
  high,

  /// Slots filled but at least one came from a fuzzy/weak match.
  medium,

  /// At least one required slot is missing or had low confidence.
  low,

  /// Insufficient signal — caller should refuse or hand off.
  none,
}

/// A single classifier diagnostic — explains how a slot was filled.
/// Used both for telemetry (PHI-safe) and developer debugging.
class IntentDiagnostic {
  const IntentDiagnostic({
    required this.slot,
    required this.signal,
    required this.confidence,
    this.detail,
  });

  /// Slot name ('metric', 'window', 'aggregation', 'comparison_window').
  final String slot;

  /// Signal source ('exact_phrase', 'fuzzy_phrase', 'regex', 'fallback').
  final String signal;

  /// Per-slot confidence in [0.0, 1.0].
  final double confidence;

  /// Optional non-PHI detail (e.g. the matched phrase, never the value).
  final String? detail;

  Map<String, Object?> toTelemetryMap() => {
        'slot': slot,
        'signal': signal,
        'confidence': double.parse(confidence.toStringAsFixed(2)),
        if (detail != null) 'detail': detail,
      };
}

/// Structured intent — the contract between [HealthKitIntentClassifier]
/// and downstream execution. Every field is independently testable.
class HealthKitIntent {
  const HealthKitIntent({
    required this.traceId,
    required this.rawQuery,
    required this.normalizedQuery,
    required this.metricDbName,
    required this.additionalMetricDbNames,
    required this.window,
    required this.comparisonWindow,
    required this.aggregation,
    required this.confidence,
    required this.confidenceTier,
    required this.diagnostics,
    required this.variantId,
    required this.isFutureWindow,
  });

  /// Short opaque trace id (e.g. 'hk_8f3a') — safe for logs, not a session id.
  final String traceId;

  /// Original user query truncated to the input cap. PHI-safe — never logged.
  final String rawQuery;

  /// Normalized lowercase query used by the classifier. Useful for debugging.
  final String normalizedQuery;

  /// Resolved primary metric DB name (e.g. 'hrv_sdnn') or null.
  final String? metricDbName;

  /// Additional metric DB names when the user asks for multiple metrics
  /// in one query (e.g. "steps and sleep yesterday"). Empty for single-metric.
  final List<String> additionalMetricDbNames;

  /// Primary time window or null if none could be resolved.
  final WearableWindow? window;

  /// Reference comparison window (e.g. "last week" in "this week vs last week")
  /// or null if the query is not a comparison.
  final WearableWindow? comparisonWindow;

  /// Aggregation method the user requested, or [AggregationMethod.defaultForMetric].
  final AggregationMethod aggregation;

  /// Overall confidence (geometric mean of slot confidences).
  final double confidence;

  /// Tiered classification of [confidence].
  final IntentConfidenceTier confidenceTier;

  /// Slot-by-slot diagnostics for telemetry and debugging.
  final List<IntentDiagnostic> diagnostics;

  /// A/B variant assigned by the experiment router.
  final String variantId;

  /// True when the user referenced a future window ("tomorrow", "next week").
  /// Caller must refuse rather than answer with stale or empty data.
  final bool isFutureWindow;

  /// True when classifier resolved a metric AND a window.
  bool get isResolved =>
      metricDbName != null && window != null && !isFutureWindow;

  /// True when classifier resolved two windows of the same metric.
  bool get isComparison => isResolved && comparisonWindow != null;

  /// True when classifier resolved 2+ metrics sharing one window.
  bool get isMultiMetric =>
      isResolved && additionalMetricDbNames.isNotEmpty;

  /// Telemetry-safe attribute bag — never contains query text or numeric values.
  Map<String, Object?> toTelemetryAttributes() => {
        'trace_id': traceId,
        'variant_id': variantId,
        'metric_resolved': metricDbName != null,
        'window_resolved': window != null,
        'comparison': comparisonWindow != null,
        'multi_metric_count': additionalMetricDbNames.length,
        'aggregation': aggregation.wireName,
        'confidence_tier': confidenceTier.name,
        'is_future_window': isFutureWindow,
        'query_length': rawQuery.length,
      };

  HealthKitIntent copyWith({
    String? variantId,
    AggregationMethod? aggregation,
  }) =>
      HealthKitIntent(
        traceId: traceId,
        rawQuery: rawQuery,
        normalizedQuery: normalizedQuery,
        metricDbName: metricDbName,
        additionalMetricDbNames: additionalMetricDbNames,
        window: window,
        comparisonWindow: comparisonWindow,
        aggregation: aggregation ?? this.aggregation,
        confidence: confidence,
        confidenceTier: confidenceTier,
        diagnostics: diagnostics,
        variantId: variantId ?? this.variantId,
        isFutureWindow: isFutureWindow,
      );
}

/// Classifier-tunable parameters. Each field has a production default; the
/// experiment router may override fields per-variant.
class HealthKitClassifierConfig {
  const HealthKitClassifierConfig({
    this.maxQueryLength = 512,
    this.enableFuzzyFallback = true,
    this.fuzzyMaxEditDistance = 2,
    this.fuzzyMinPhraseLength = 4,
    this.highConfidenceThreshold = 0.85,
    this.mediumConfidenceThreshold = 0.60,
    this.fuzzyConfidencePenalty = 0.30,
  });

  /// Hard cap on input length. Queries longer than this are truncated.
  final int maxQueryLength;

  /// Whether to use Levenshtein-based fuzzy matching when exact match fails.
  final bool enableFuzzyFallback;

  /// Max edit distance accepted for fuzzy matches on longer phrases.
  final int fuzzyMaxEditDistance;

  /// Phrases shorter than this are NEVER fuzzy-matched (avoids 'hr'→'hrv').
  final int fuzzyMinPhraseLength;

  /// Confidence ≥ this is tier 'high'.
  final double highConfidenceThreshold;

  /// Confidence ≥ this is tier 'medium' (below is 'low').
  final double mediumConfidenceThreshold;

  /// Subtracted from per-slot confidence when a fuzzy match was used.
  final double fuzzyConfidencePenalty;

  /// Production default — safe and conservative.
  static const production = HealthKitClassifierConfig();

  /// Variant A: lexical-only (no fuzzy). Used in experiments to measure
  /// the marginal benefit of fuzzy matching.
  static const lexicalOnly = HealthKitClassifierConfig(
    enableFuzzyFallback: false,
  );

  /// Variant B: aggressive fuzzy (higher edit distance, lower penalty).
  static const fuzzyAggressive = HealthKitClassifierConfig(
    fuzzyMaxEditDistance: 3,
    fuzzyConfidencePenalty: 0.20,
  );
}
