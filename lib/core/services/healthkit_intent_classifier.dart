// Sophisticated NLU classifier for HealthKit queries.
//
// Pipeline:
//   1. Validate & normalize input (truncate, lowercase, expand contractions).
//   2. Resolve A/B variant via ExperimentService (config swap).
//   3. Extract slots with confidence:
//        a. Metric phrase — exact substring (longest match), fuzzy fallback.
//        b. Window keyword — lexical match using WearableAggregationService.
//        c. Aggregation override — keyword scan (max/min/median/total/avg).
//        d. Comparison window — pattern detection ("X vs Y", "X compared to Y").
//        e. Additional metrics — second/third metric mentions sharing the window.
//   4. Detect future-window queries → flag intent.isFutureWindow.
//   5. Aggregate confidence via geometric mean; map to tier.
//   6. Emit HealthKitIntent (immutable) and record PHI-safe telemetry.
//
// Determinism: classify() with the same (query, now, variant) returns the
// same HealthKitIntent. Variant assignment is deterministic given installId.

import 'experiment_service.dart';
import 'healthkit_intent.dart';
import 'healthkit_telemetry.dart';
import 'healthkit_text_utils.dart';
import 'wearable_aggregation_service.dart';

/// Experiment key registered with [ExperimentService] for classifier A/B.
const String kHealthKitClassifierExperiment = 'healthkit_classifier_v1';
const String kHealthKitClassifierVariantLexical = 'lexical_only';
const String kHealthKitClassifierVariantFuzzy = 'lexical_with_fuzzy';

/// Aggregation-override keyword patterns. Detection is leftmost-match;
/// 'maximum' is checked before 'max' to win on length.
const Map<AggregationMethod, List<String>> _kAggregationKeywords = {
  AggregationMethod.max: [
    'maximum',
    'peak',
    'highest',
    'biggest',
    'largest',
    'best',
    'top',
    'max',
  ],
  AggregationMethod.min: [
    'minimum',
    'lowest',
    'smallest',
    'worst',
    'bottom',
    'least',
    'min',
  ],
  AggregationMethod.median: [
    'median',
    'middle value',
    'p50',
  ],
  AggregationMethod.total: [
    'total',
    'totalled',
    'totaled',
    'overall total',
    'sum of',
    'sum total',
    'cumulative',
    'sum',
    'add up',
    'added up',
  ],
  AggregationMethod.average: [
    'average',
    'avg',
    'mean',
    'typical',
    'on average',
  ],
  AggregationMethod.latest: [
    'most recent',
    'latest',
    'last reading',
    'current',
    'newest',
  ],
};

/// Comparison-trigger keywords. Any match flips the classifier into
/// dual-window mode where a comparison window is also extracted.
const List<String> _kComparisonTriggers = [
  'compared to',
  'compared with',
  'compare to',
  'compare with',
  'versus',
  ' vs ',
  ' vs.',
  ' against ',
  'change from',
  'change vs',
  'change versus',
];

/// Future-window phrases that MUST short-circuit the classifier with refusal.
const List<String> _kFutureWindowPhrases = [
  'tomorrow',
  'next week',
  'next month',
  'next year',
  'coming days',
  'coming week',
  'coming month',
  'upcoming week',
  'upcoming month',
  'will i',
  'will my',
];

/// Result of classification.
typedef HealthKitClassifyResult = HealthKitIntent;

/// Sophisticated NLU for HealthKit queries.
class HealthKitIntentClassifier {
  HealthKitIntentClassifier({
    required WearableAggregationService aggregationService,
    ExperimentService? experimentService,
    HealthKitTelemetry? telemetry,
    HealthKitClassifierConfig config = HealthKitClassifierConfig.production,
    DateTime Function()? clock,
  })  : _agg = aggregationService,
        _experiments = experimentService,
        _telemetry = telemetry,
        _defaultConfig = config,
        _clock = clock ?? DateTime.now;

  final WearableAggregationService _agg;
  final ExperimentService? _experiments;
  final HealthKitTelemetry? _telemetry;
  final HealthKitClassifierConfig _defaultConfig;
  final DateTime Function() _clock;

  /// Phrase index built from [WearableAggregationService.allPhrases].
  /// Lazy-init to avoid duplicating the registry in this file.
  late final List<_PhraseEntry> _phrases = _buildPhraseIndex();

  /// Classifies [userQuery] into a [HealthKitIntent].
  ///
  /// Never throws on user input — invalid input returns an unresolved intent.
  /// Returns even for empty/garbage queries (with very low confidence).
  Future<HealthKitIntent> classify(
    String userQuery, {
    DateTime? now,
    String? overrideVariant,
  }) async {
    final start = _clock();
    final traceId = generateTraceId('${start.microsecondsSinceEpoch}_${userQuery.length}');

    final variantId = overrideVariant ?? await _resolveVariant();
    final config = _configForVariant(variantId);

    final cappedRaw = userQuery.length > config.maxQueryLength
        ? userQuery.substring(0, config.maxQueryLength)
        : userQuery;
    final normalized = normalizeQuery(cappedRaw);

    // Future-window short circuit.
    final isFuture = _detectFutureWindow(normalized);
    if (isFuture) {
      final intent = _unresolvedIntent(
        traceId: traceId,
        variantId: variantId,
        raw: cappedRaw,
        normalized: normalized,
        isFutureWindow: true,
        diagnostic: const IntentDiagnostic(
          slot: 'window',
          signal: 'future_keyword',
          confidence: 1.0,
          detail: 'future_window_refused',
        ),
      );
      await _logIntent(intent, latencyMs: _elapsedMs(start));
      return intent;
    }

    if (normalized.isEmpty) {
      final intent = _unresolvedIntent(
        traceId: traceId,
        variantId: variantId,
        raw: cappedRaw,
        normalized: normalized,
        diagnostic: const IntentDiagnostic(
          slot: 'input',
          signal: 'empty',
          confidence: 0.0,
        ),
      );
      await _logIntent(intent, latencyMs: _elapsedMs(start));
      return intent;
    }

    final diagnostics = <IntentDiagnostic>[];

    // Slot 1: primary metric.
    final metricMatch = _matchMetric(normalized, config: config);
    if (metricMatch != null) {
      diagnostics.add(IntentDiagnostic(
        slot: 'metric',
        signal: metricMatch.fuzzy ? 'fuzzy_phrase' : 'exact_phrase',
        confidence: metricMatch.confidence,
        detail: metricMatch.phrase,
      ));
    }

    // Slot 2: primary window.
    final windowResolved = (now ?? _clock());
    final window = _agg.matchWindow(normalized, now: windowResolved);
    if (window != null) {
      diagnostics.add(IntentDiagnostic(
        slot: 'window',
        signal: 'phrase_match',
        confidence: 1.0,
        detail: window.grain.name,
      ));
    }

    // Slot 3: aggregation override.
    final aggDetection = _detectAggregation(normalized);
    if (aggDetection.method != AggregationMethod.defaultForMetric) {
      diagnostics.add(IntentDiagnostic(
        slot: 'aggregation',
        signal: 'keyword',
        confidence: 1.0,
        detail: aggDetection.method.wireName,
      ));
    }

    // Slot 4: comparison window.
    WearableWindow? comparisonWindow;
    if (window != null && _detectComparisonTrigger(normalized)) {
      comparisonWindow = _resolveComparisonReference(
        normalized,
        primary: window,
        now: windowResolved,
      );
      if (comparisonWindow != null) {
        diagnostics.add(IntentDiagnostic(
          slot: 'comparison_window',
          signal: 'pattern',
          confidence: 1.0,
          detail: comparisonWindow.grain.name,
        ));
      }
    }

    // Slot 5: additional metrics (multi-metric).
    final additional = <String>[];
    if (metricMatch != null && window != null) {
      additional.addAll(_extractAdditionalMetrics(
        normalized,
        primary: metricMatch.dbName,
      ));
      if (additional.isNotEmpty) {
        diagnostics.add(IntentDiagnostic(
          slot: 'additional_metrics',
          signal: 'phrase_match',
          confidence: 0.95,
          detail: '${additional.length}_metrics',
        ));
      }
    }

    // Confidence aggregation.
    final slotConfidences = <double>[
      if (metricMatch != null) metricMatch.confidence,
      if (window != null) 1.0,
    ];
    final confidence = aggregateConfidence(slotConfidences);
    final tier = _confidenceTier(
      confidence,
      hasMetric: metricMatch != null,
      hasWindow: window != null,
      config: config,
    );

    final intent = HealthKitIntent(
      traceId: traceId,
      rawQuery: cappedRaw,
      normalizedQuery: normalized,
      metricDbName: metricMatch?.dbName,
      additionalMetricDbNames: List.unmodifiable(additional),
      window: window,
      comparisonWindow: comparisonWindow,
      aggregation: aggDetection.method,
      confidence: confidence,
      confidenceTier: tier,
      diagnostics: List.unmodifiable(diagnostics),
      variantId: variantId,
      isFutureWindow: false,
    );

    await _logIntent(intent, latencyMs: _elapsedMs(start));
    return intent;
  }

  // ── A/B variant resolution ────────────────────────────────────────────────

  Future<String> _resolveVariant() async {
    if (_experiments == null) return kHealthKitClassifierVariantFuzzy;
    try {
      return await _experiments!.variantFor(
        kHealthKitClassifierExperiment,
        variants: const [
          kHealthKitClassifierVariantLexical,
          kHealthKitClassifierVariantFuzzy,
        ],
      );
    } catch (_) {
      // ExperimentService failures must never break classification.
      return kHealthKitClassifierVariantFuzzy;
    }
  }

  HealthKitClassifierConfig _configForVariant(String variantId) {
    switch (variantId) {
      case kHealthKitClassifierVariantLexical:
        return HealthKitClassifierConfig.lexicalOnly;
      case kHealthKitClassifierVariantFuzzy:
        return _defaultConfig;
      default:
        return _defaultConfig;
    }
  }

  // ── Slot extraction ───────────────────────────────────────────────────────

  _MetricMatch? _matchMetric(
    String normalized, {
    required HealthKitClassifierConfig config,
  }) {
    _PhraseEntry? bestExact;
    var bestExactLen = 0;
    for (final entry in _phrases) {
      if (normalized.contains(entry.phrase) && entry.phrase.length > bestExactLen) {
        bestExact = entry;
        bestExactLen = entry.phrase.length;
      }
    }
    if (bestExact != null) {
      return _MetricMatch(
        dbName: bestExact.dbName,
        phrase: bestExact.phrase,
        confidence: 1.0,
        fuzzy: false,
      );
    }

    if (!config.enableFuzzyFallback) return null;

    // Fuzzy fallback: scan token windows.
    final tokens = tokenizeWithoutFillers(normalized);
    if (tokens.isEmpty) return null;

    _PhraseEntry? bestFuzzy;
    var bestFuzzyDist = config.fuzzyMaxEditDistance + 1;
    String? bestFuzzyMatched;

    for (final entry in _phrases) {
      if (entry.phrase.length < config.fuzzyMinPhraseLength) continue;
      final phraseTokens = entry.phraseTokens;
      if (phraseTokens.length > tokens.length) continue;

      for (var i = 0; i <= tokens.length - phraseTokens.length; i++) {
        final candidate = tokens.skip(i).take(phraseTokens.length).join(' ');
        if ((candidate.length - entry.phrase.length).abs() >
            config.fuzzyMaxEditDistance) {
          continue;
        }
        final dist = levenshtein(
          entry.phrase,
          candidate,
          threshold: config.fuzzyMaxEditDistance,
        );
        if (dist < bestFuzzyDist) {
          bestFuzzyDist = dist;
          bestFuzzy = entry;
          bestFuzzyMatched = candidate;
          if (dist == 0) break; // can't improve.
        }
      }
    }

    if (bestFuzzy == null || bestFuzzyDist > config.fuzzyMaxEditDistance) {
      return null;
    }
    final baseConf =
        fuzzyConfidence(bestFuzzy!.phrase.length, bestFuzzyDist);
    final penalized =
        (baseConf - config.fuzzyConfidencePenalty).clamp(0.0, 1.0);
    return _MetricMatch(
      dbName: bestFuzzy!.dbName,
      phrase: bestFuzzyMatched ?? bestFuzzy!.phrase,
      confidence: penalized,
      fuzzy: true,
    );
  }

  /// Detects an aggregation-method override. Returns
  /// [AggregationMethod.defaultForMetric] if no keyword is present.
  ({AggregationMethod method, String? matchedKeyword}) _detectAggregation(
    String normalized,
  ) {
    if (normalized.isEmpty) {
      return (method: AggregationMethod.defaultForMetric, matchedKeyword: null);
    }
    // Iterate methods in a fixed priority order so 'max' beats 'average' when
    // both somehow appear (e.g. "average and max steps" → max wins by order).
    const priority = [
      AggregationMethod.max,
      AggregationMethod.min,
      AggregationMethod.median,
      AggregationMethod.total,
      AggregationMethod.latest,
      AggregationMethod.average,
    ];
    for (final method in priority) {
      final keywords = _kAggregationKeywords[method] ?? const [];
      for (final kw in keywords) {
        if (_containsAsWord(normalized, kw)) {
          return (method: method, matchedKeyword: kw);
        }
      }
    }
    return (method: AggregationMethod.defaultForMetric, matchedKeyword: null);
  }

  bool _detectComparisonTrigger(String normalized) {
    for (final t in _kComparisonTriggers) {
      if (normalized.contains(t)) return true;
    }
    // Pattern: "X vs Y" — match standalone 'vs' bordered by whitespace.
    if (RegExp(r'\bvs\b').hasMatch(normalized)) return true;
    // Pattern: "this <unit> last <unit>" or vice versa.
    if (RegExp(r'\bthis\s+(week|month|year)\b').hasMatch(normalized) &&
        RegExp(r'\blast\s+(week|month|year)\b').hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  WearableWindow? _resolveComparisonReference(
    String normalized, {
    required WearableWindow primary,
    required DateTime now,
  }) {
    // Strategy: build a probe phrase that ONLY contains the comparison
    // window keyword, then ask the existing matcher to resolve it.
    // Pick the keyword that matches the primary's grain.
    final candidates = <String>[];
    switch (primary.grain) {
      case WearableGrain.week:
        if (normalized.contains('last week') &&
            primary.label.toLowerCase().contains('this week')) {
          candidates.add('last week');
        } else if (normalized.contains('this week') &&
            primary.label.toLowerCase().contains('last week')) {
          candidates.add('this week');
        } else {
          candidates.addAll(['last week', 'past 2 weeks']);
        }
        break;
      case WearableGrain.month:
        if (normalized.contains('last month') &&
            primary.label.toLowerCase().contains('this month')) {
          candidates.add('last month');
        } else if (normalized.contains('this month') &&
            primary.label.toLowerCase().contains('last month')) {
          candidates.add('this month');
        } else {
          candidates.add('last month');
        }
        break;
      case WearableGrain.day:
        candidates.addAll(['yesterday', 'last week']);
        break;
      case WearableGrain.range:
        candidates.add('past 30 days');
        break;
    }

    for (final probe in candidates) {
      final w = _agg.matchWindow(probe, now: now);
      if (w == null) continue;
      // Reject if it's the same window as primary.
      if (w.startDate == primary.startDate && w.endDate == primary.endDate) {
        continue;
      }
      return w;
    }
    return null;
  }

  List<String> _extractAdditionalMetrics(
    String normalized, {
    required String primary,
  }) {
    final seen = <String>{primary};
    final result = <String>[];
    for (final entry in _phrases) {
      if (entry.dbName == primary) continue;
      if (seen.contains(entry.dbName)) continue;
      if (!normalized.contains(entry.phrase)) continue;
      // Avoid spurious "step" → steps when actually "step length" matched.
      // Skip phrases that are substrings of any already-matched phrase.
      if (_isPhraseShadowedBy(entry.phrase, normalized, primary)) continue;
      seen.add(entry.dbName);
      result.add(entry.dbName);
    }
    return result;
  }

  /// Returns true if [phrase] only appears as a substring of a longer phrase
  /// that matched a different metric.
  bool _isPhraseShadowedBy(
    String phrase,
    String normalized,
    String primaryDb,
  ) {
    final idx = normalized.indexOf(phrase);
    if (idx < 0) return true;
    // Look for a longer phrase covering the same span.
    for (final entry in _phrases) {
      if (entry.phrase == phrase) continue;
      if (entry.phrase.length <= phrase.length) continue;
      if (!entry.phrase.contains(phrase)) continue;
      if (normalized.contains(entry.phrase)) return true;
    }
    return false;
  }

  // ── Confidence tier ───────────────────────────────────────────────────────

  IntentConfidenceTier _confidenceTier(
    double confidence, {
    required bool hasMetric,
    required bool hasWindow,
    required HealthKitClassifierConfig config,
  }) {
    if (!hasMetric || !hasWindow) return IntentConfidenceTier.none;
    if (confidence >= config.highConfidenceThreshold) {
      return IntentConfidenceTier.high;
    }
    if (confidence >= config.mediumConfidenceThreshold) {
      return IntentConfidenceTier.medium;
    }
    return IntentConfidenceTier.low;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _detectFutureWindow(String normalized) {
    for (final p in _kFutureWindowPhrases) {
      if (normalized.contains(p)) return true;
    }
    return false;
  }

  /// Word-boundary check — avoids 'max' matching inside 'maximize' or similar.
  bool _containsAsWord(String text, String word) {
    final idx = text.indexOf(word);
    if (idx < 0) return false;
    final before = idx == 0 ? ' ' : text[idx - 1];
    final afterIdx = idx + word.length;
    final after = afterIdx >= text.length ? ' ' : text[afterIdx];
    return !_isWordChar(before) && !_isWordChar(after);
  }

  bool _isWordChar(String c) {
    if (c.isEmpty) return false;
    final code = c.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x41 && code <= 0x5A) || // A-Z
        (code >= 0x61 && code <= 0x7A) || // a-z
        code == 0x5F; // _
  }

  HealthKitIntent _unresolvedIntent({
    required String traceId,
    required String variantId,
    required String raw,
    required String normalized,
    required IntentDiagnostic diagnostic,
    bool isFutureWindow = false,
  }) =>
      HealthKitIntent(
        traceId: traceId,
        rawQuery: raw,
        normalizedQuery: normalized,
        metricDbName: null,
        additionalMetricDbNames: const [],
        window: null,
        comparisonWindow: null,
        aggregation: AggregationMethod.defaultForMetric,
        confidence: 0.0,
        confidenceTier: IntentConfidenceTier.none,
        diagnostics: [diagnostic],
        variantId: variantId,
        isFutureWindow: isFutureWindow,
      );

  Future<void> _logIntent(
    HealthKitIntent intent, {
    required int latencyMs,
  }) async {
    _telemetry?.recordClassification(intent: intent, latencyMs: latencyMs);
    if (_experiments != null) {
      try {
        await _experiments!.logExposure(
          experimentKey: kHealthKitClassifierExperiment,
          eventName: 'classify_complete',
          metadata: intent.toTelemetryAttributes(),
        );
      } catch (_) {
        // Telemetry failures must never propagate to the caller.
      }
    }
  }

  int _elapsedMs(DateTime start) =>
      _clock().difference(start).inMilliseconds.abs();

  // ── Phrase index ──────────────────────────────────────────────────────────

  List<_PhraseEntry> _buildPhraseIndex() {
    final list = <_PhraseEntry>[];
    for (final entry in _agg.allPhrases.entries) {
      final phrase = entry.key;
      list.add(_PhraseEntry(
        phrase: phrase,
        phraseTokens: phrase.split(' '),
        dbName: entry.value.dbName,
      ));
    }
    // Longest phrases first — guarantees longest-match wins in linear scan.
    list.sort((a, b) => b.phrase.length.compareTo(a.phrase.length));
    return List.unmodifiable(list);
  }
}

class _PhraseEntry {
  _PhraseEntry({
    required this.phrase,
    required this.phraseTokens,
    required this.dbName,
  });
  final String phrase;
  final List<String> phraseTokens;
  final String dbName;
}

class _MetricMatch {
  _MetricMatch({
    required this.dbName,
    required this.phrase,
    required this.confidence,
    required this.fuzzy,
  });
  final String dbName;
  final String phrase;
  final double confidence;
  final bool fuzzy;
}
