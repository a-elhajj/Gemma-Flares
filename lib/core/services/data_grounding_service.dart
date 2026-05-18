// =============================================================================
// DATA GROUNDING SERVICE — Production-Grade RAG Robustness
// =============================================================================
// Comprehensive data quality and grounding for RAG-based responses.
// Handles 400+ edge cases across data grounding categories:
//   - Missing data handlers with intelligent defaults
//   - Stale data detection and refresh triggers
//   - Conflicting data resolution algorithms
//   - Partial data completion strategies
//   - Data quality scoring and trust metrics
//   - Temporal coherence validation
//
// Design principles:
//   - Data quality first: Never ground on questionable data
//   - Explainable decisions: Every default has a reason
//   - Temporal awareness: Recent data weighted higher
//   - Conflict resolution: Deterministic tie-breakers
//   - User transparency: Show data gaps and confidence
// =============================================================================

library;

import 'dart:math' as math;

/// Result of data grounding operation.
class GroundingResult<T> {
  const GroundingResult({
    required this.value,
    required this.confidence,
    required this.dataQuality,
    this.isDefault = false,
    this.isSynthesized = false,
    this.dataGaps = const [],
    this.conflicts = const [],
    this.metadata = const {},
  });

  final T value;
  final double confidence; // 0.0-1.0
  final DataQuality dataQuality;
  final bool isDefault;
  final bool isSynthesized;
  final List<String> dataGaps;
  final List<DataConflict> conflicts;
  final Map<String, Object?> metadata;

  bool get isHighConfidence => confidence >= 0.8;
  bool get isMediumConfidence => confidence >= 0.5 && confidence < 0.8;
  bool get isLowConfidence => confidence < 0.5;
  bool get hasGaps => dataGaps.isNotEmpty;
  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Data quality assessment.
enum DataQuality {
  high, // Complete, fresh, consistent
  medium, // Mostly complete, reasonably fresh
  low, // Incomplete, stale, or conflicts
  unreliable, // Too many issues to trust
}

/// Data conflict details.
class DataConflict {
  const DataConflict({
    required this.source1,
    required this.source2,
    required this.field,
    required this.value1,
    required this.value2,
    required this.resolution,
    this.reason,
  });

  final String source1;
  final String source2;
  final String field;
  final Object? value1;
  final Object? value2;
  final String
      resolution; // 'used_source1', 'used_source2', 'averaged', 'most_recent'
  final String? reason;
}

/// Temporal data point with timestamp.
class TemporalData<T> {
  const TemporalData({
    required this.value,
    required this.timestamp,
    required this.source,
    this.confidence = 1.0,
  });

  final T value;
  final DateTime timestamp;
  final String source;
  final double confidence;

  /// Age of data in days.
  double ageInDays(DateTime now) {
    return now.difference(timestamp).inDays.toDouble();
  }

  /// Freshness score (1.0 = today, 0.0 = very old).
  double freshnessScore(DateTime now) {
    final age = ageInDays(now);
    if (age == 0) return 1.0;
    if (age <= 1) return 0.9;
    if (age <= 7) return 0.7;
    if (age <= 30) return 0.5;
    if (age <= 90) return 0.3;
    return 0.1;
  }
}

/// Data grounding service.
class DataGroundingService {
  const DataGroundingService._();

  // ---------------------------------------------------------------------------
  // Missing Data Handlers
  // ---------------------------------------------------------------------------

  /// Edge case 143: No symptom data available - use intelligent default
  static GroundingResult<String> handleMissingSymptomData({
    required DateTime queryDate,
    String defaultMessage = 'No symptoms logged yet',
  }) {
    return GroundingResult(
      value: defaultMessage,
      confidence: 0.0, // No data = zero confidence
      dataQuality: DataQuality.unreliable,
      isDefault: true,
      dataGaps: ['symptom_data'],
      metadata: {
        'queryDate': queryDate.toIso8601String(),
        'reason': 'No symptom logs found for query period',
      },
    );
  }

  /// Edge case 144: Partial symptom data (some days missing)
  static GroundingResult<Map<String, Object?>> handlePartialSymptomData({
    required List<TemporalData<Map<String, Object?>>> availableData,
    required DateTime startDate,
    required DateTime endDate,
    required DateTime now,
  }) {
    if (availableData.isEmpty) {
      return GroundingResult(
        value: {},
        confidence: 0.0,
        dataQuality: DataQuality.unreliable,
        dataGaps: ['all_symptom_data'],
        metadata: {'coverage': 0.0},
      );
    }

    final totalDays = endDate.difference(startDate).inDays + 1;
    final coverage = availableData.length / totalDays;

    // Edge case 145: Low coverage (<50%) - warn about data gaps
    final dataGaps = <String>[];
    if (coverage < 0.5) {
      dataGaps.add('symptom_coverage_low');
    }

    // Synthesize: use most recent pattern for missing days
    final synthesized = <String, Object?>{
      'available_days': availableData.length,
      'total_days': totalDays,
      'coverage': coverage,
      'pattern': _extractSymptomPattern(availableData, now),
    };

    return GroundingResult(
      value: synthesized,
      confidence: coverage,
      dataQuality: coverage >= 0.8
          ? DataQuality.high
          : coverage >= 0.5
              ? DataQuality.medium
              : DataQuality.low,
      isSynthesized: coverage < 1.0,
      dataGaps: dataGaps,
      metadata: {
        'coverage': coverage,
        'missing_days': totalDays - availableData.length,
      },
    );
  }

  /// Edge case 146: No lab data available
  static GroundingResult<String> handleMissingLabData({
    required String labType,
  }) {
    return GroundingResult(
      value: 'No $labType results available',
      confidence: 0.0,
      dataQuality: DataQuality.unreliable,
      isDefault: true,
      dataGaps: ['lab_$labType'],
      metadata: {
        'labType': labType,
        'recommendation': 'Ask user to upload lab results or enter manually',
      },
    );
  }

  /// Edge case 147: Missing baseline data (first-time user)
  static GroundingResult<Map<String, Object?>> handleMissingBaseline({
    required String metric,
  }) {
    return GroundingResult(
      value: {
        'hasBaseline': false,
        'message': 'Building your baseline - log a few more data points',
      },
      confidence: 0.0,
      dataQuality: DataQuality.low,
      isDefault: true,
      dataGaps: ['baseline_$metric'],
      metadata: {
        'metric': metric,
        'minDataPoints': 7, // Need 7 days for baseline
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Stale Data Detection
  // ---------------------------------------------------------------------------

  /// Edge case 148: Detect stale lab results (>6 months old)
  static bool isLabResultStale(DateTime labDate, DateTime now) {
    final age = now.difference(labDate).inDays;
    return age > 180; // 6 months
  }

  /// Edge case 149: Detect stale symptom data (>30 days old)
  static bool isSymptomDataStale(DateTime symptomDate, DateTime now) {
    final age = now.difference(symptomDate).inDays;
    return age > 30;
  }

  /// Edge case 150: Detect stale medication data (>90 days old)
  static bool isMedicationDataStale(DateTime medDate, DateTime now) {
    final age = now.difference(medDate).inDays;
    return age > 90;
  }

  /// Edge case 151: Stale data warning with refresh suggestion
  static GroundingResult<T> wrapWithStalenessWarning<T>({
    required T value,
    required DateTime dataDate,
    required DateTime now,
    required String dataType,
    required double baseConfidence,
  }) {
    final age = now.difference(dataDate).inDays;
    final isStale = age > 30;

    final warnings = <String>[];
    var confidence = baseConfidence;

    // Edge case 152: Very stale data (>90 days) - reduce confidence significantly
    if (age > 90) {
      warnings.add('$dataType is over 3 months old - please update');
      confidence *= 0.3; // Reduce confidence by 70%
    } else if (age > 30) {
      warnings.add('$dataType is over 1 month old - consider updating');
      confidence *= 0.7; // Reduce confidence by 30%
    }

    return GroundingResult(
      value: value,
      confidence: confidence,
      dataQuality: age > 90
          ? DataQuality.low
          : age > 30
              ? DataQuality.medium
              : DataQuality.high,
      dataGaps: warnings,
      metadata: {
        'age_days': age,
        'data_date': dataDate.toIso8601String(),
        'is_stale': isStale,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Conflicting Data Resolution
  // ---------------------------------------------------------------------------

  /// Edge case 153: Resolve conflicting symptom severity (user vs auto-detected)
  static GroundingResult<double> resolveSymptomSeverityConflict({
    required double userReported,
    required double autoDetected,
    required DateTime userTimestamp,
    required DateTime autoTimestamp,
  }) {
    // Edge case 154: User-reported takes precedence if recent
    final timeDiff = userTimestamp.difference(autoTimestamp).abs().inMinutes;

    if (timeDiff < 60) {
      // Within 1 hour - use user-reported (they know their body best)
      return GroundingResult(
        value: userReported,
        confidence: 0.9,
        dataQuality: DataQuality.high,
        conflicts: [
          DataConflict(
            source1: 'user_reported',
            source2: 'auto_detected',
            field: 'severity',
            value1: userReported,
            value2: autoDetected,
            resolution: 'used_source1',
            reason: 'User self-report within 1 hour takes precedence',
          ),
        ],
        metadata: {
          'time_diff_minutes': timeDiff,
          'discrepancy': (userReported - autoDetected).abs(),
        },
      );
    }

    // Edge case 155: If timestamps far apart, use most recent
    final useUser = userTimestamp.isAfter(autoTimestamp);
    return GroundingResult(
      value: useUser ? userReported : autoDetected,
      confidence: 0.7,
      dataQuality: DataQuality.medium,
      conflicts: [
        DataConflict(
          source1: 'user_reported',
          source2: 'auto_detected',
          field: 'severity',
          value1: userReported,
          value2: autoDetected,
          resolution: useUser ? 'used_source1' : 'used_source2',
          reason: 'Used most recent data point',
        ),
      ],
    );
  }

  /// Edge case 156: Resolve conflicting lab values (multiple sources)
  static GroundingResult<double> resolveLabValueConflict({
    required List<TemporalData<double>> values,
    required DateTime now,
  }) {
    if (values.isEmpty) {
      return GroundingResult(
        value: 0.0,
        confidence: 0.0,
        dataQuality: DataQuality.unreliable,
        dataGaps: ['no_lab_values'],
      );
    }

    if (values.length == 1) {
      return GroundingResult(
        value: values.first.value,
        confidence: values.first.confidence,
        dataQuality: DataQuality.high,
      );
    }

    // Edge case 157: Multiple values - use weighted average by freshness
    var weightedSum = 0.0;
    var weightSum = 0.0;
    final conflicts = <DataConflict>[];

    for (final data in values) {
      final freshness = data.freshnessScore(now);
      final weight = freshness * data.confidence;
      weightedSum += data.value * weight;
      weightSum += weight;
    }

    // Edge case 158: High variance (>20%) - flag as conflicting
    final mean = weightedSum / weightSum;
    final variance = values.fold<double>(0.0, (sum, data) {
          final diff = data.value - mean;
          return sum + (diff * diff);
        }) /
        values.length;
    final stdDev = math.sqrt(variance);
    final coefficientOfVariation = stdDev / mean;

    if (coefficientOfVariation > 0.2) {
      // High variance - add conflict details
      for (var i = 0; i < values.length - 1; i++) {
        conflicts.add(
          DataConflict(
            source1: values[i].source,
            source2: values[i + 1].source,
            field: 'lab_value',
            value1: values[i].value,
            value2: values[i + 1].value,
            resolution: 'averaged',
            reason:
                'High variance (CV=${(coefficientOfVariation * 100).toStringAsFixed(1)}%) - used weighted average',
          ),
        );
      }
    }

    return GroundingResult(
      value: mean,
      confidence: math.max(0.5, 1.0 - coefficientOfVariation),
      dataQuality: coefficientOfVariation < 0.1
          ? DataQuality.high
          : coefficientOfVariation < 0.2
              ? DataQuality.medium
              : DataQuality.low,
      conflicts: conflicts,
      metadata: {
        'sources': values.length,
        'variance': variance,
        'stdDev': stdDev,
        'cv': coefficientOfVariation,
      },
    );
  }

  /// Edge case 159: Resolve temporal inconsistency (future timestamps)
  static GroundingResult<DateTime> resolveTemporalInconsistency({
    required DateTime reported,
    required DateTime now,
  }) {
    // Edge case 160: Future timestamp - clamp to now
    if (reported.isAfter(now)) {
      return GroundingResult(
        value: now,
        confidence: 0.5,
        dataQuality: DataQuality.low,
        conflicts: [
          DataConflict(
            source1: 'reported',
            source2: 'system_time',
            field: 'timestamp',
            value1: reported.toIso8601String(),
            value2: now.toIso8601String(),
            resolution: 'used_source2',
            reason:
                'Reported timestamp is in the future - clamped to current time',
          ),
        ],
        metadata: {'future_offset_minutes': reported.difference(now).inMinutes},
      );
    }

    // Edge case 161: Very old timestamp (>1 year) - flag as suspicious
    final age = now.difference(reported).inDays;
    if (age > 365) {
      return GroundingResult(
        value: reported,
        confidence: 0.3,
        dataQuality: DataQuality.low,
        dataGaps: ['timestamp_very_old'],
        metadata: {
          'age_days': age,
          'warning': 'Timestamp is over 1 year old - verify accuracy',
        },
      );
    }

    return GroundingResult(
      value: reported,
      confidence: 1.0,
      dataQuality: DataQuality.high,
    );
  }

  // ---------------------------------------------------------------------------
  // Partial Data Completion
  // ---------------------------------------------------------------------------

  /// Edge case 162: Complete missing symptom fields with reasonable defaults
  static Map<String, Object?> completeSymptomData({
    required Map<String, Object?> partial,
    required DateTime timestamp,
  }) {
    final completed = Map<String, Object?>.from(partial);

    // Edge case 163: Missing severity - default to moderate (5/10)
    if (!completed.containsKey('severity') || completed['severity'] == null) {
      completed['severity'] = 5.0;
      completed['severity_defaulted'] = true;
    }

    // Edge case 164: Missing duration - default to "unknown"
    if (!completed.containsKey('duration') || completed['duration'] == null) {
      completed['duration'] = 'unknown';
      completed['duration_defaulted'] = true;
    }

    // Edge case 165: Missing frequency - default to "once"
    if (!completed.containsKey('frequency') || completed['frequency'] == null) {
      completed['frequency'] = 'once';
      completed['frequency_defaulted'] = true;
    }

    // Edge case 166: Missing timestamp - use provided timestamp
    if (!completed.containsKey('timestamp') || completed['timestamp'] == null) {
      completed['timestamp'] = timestamp.toIso8601String();
      completed['timestamp_defaulted'] = true;
    }

    return completed;
  }

  /// Edge case 167: Interpolate missing data points in time series
  static List<TemporalData<double>> interpolateMissingPoints({
    required List<TemporalData<double>> existing,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    if (existing.isEmpty) return [];
    if (existing.length == 1) return existing;

    // Edge case 168: Sort by timestamp
    final sorted = List<TemporalData<double>>.from(existing)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final result = <TemporalData<double>>[];
    result.add(sorted.first);

    // Edge case 169: Find gaps >1 day and interpolate
    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1];
      final curr = sorted[i];
      final gapDays = curr.timestamp.difference(prev.timestamp).inDays;

      if (gapDays > 1) {
        // Interpolate missing days
        for (var day = 1; day < gapDays; day++) {
          final interpolatedDate = prev.timestamp.add(Duration(days: day));
          final ratio = day / gapDays;
          final interpolatedValue =
              prev.value + (curr.value - prev.value) * ratio;

          result.add(
            TemporalData(
              value: interpolatedValue,
              timestamp: interpolatedDate,
              source: 'interpolated',
              confidence: 0.5, // Interpolated data has lower confidence
            ),
          );
        }
      }

      result.add(curr);
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Data Quality Scoring
  // ---------------------------------------------------------------------------

  /// Edge case 170: Calculate overall data quality score
  static GroundingResult<double> calculateDataQualityScore({
    required int totalDataPoints,
    required int expectedDataPoints,
    required double avgFreshness,
    required int conflictCount,
    required int gapCount,
  }) {
    // Edge case 171: Completeness score (0.0-1.0)
    final completeness = totalDataPoints / math.max(1, expectedDataPoints);

    // Edge case 173: Conflict penalty (each conflict reduces score by 5%)
    final conflictPenalty = math.min(0.5, conflictCount * 0.05);

    // Edge case 174: Gap penalty (each gap reduces score by 3%)
    final gapPenalty = math.min(0.3, gapCount * 0.03);

    // Weighted quality score
    var quality = completeness * 0.4 +
        avgFreshness * 0.3 +
        (1.0 - conflictPenalty) * 0.2 +
        (1.0 - gapPenalty) * 0.1;

    quality = quality.clamp(0.0, 1.0);

    final dataQuality = quality >= 0.8
        ? DataQuality.high
        : quality >= 0.5
            ? DataQuality.medium
            : quality >= 0.3
                ? DataQuality.low
                : DataQuality.unreliable;

    return GroundingResult(
      value: quality,
      confidence: quality,
      dataQuality: dataQuality,
      metadata: {
        'completeness': completeness,
        'avgFreshness': avgFreshness,
        'conflictCount': conflictCount,
        'gapCount': gapCount,
        'component_scores': {
          'completeness_contribution': completeness * 0.4,
          'freshness_contribution': avgFreshness * 0.3,
          'conflict_penalty': conflictPenalty,
          'gap_penalty': gapPenalty,
        },
      },
    );
  }

  /// Edge case 175: Assess individual data point quality
  static DataQuality assessDataPointQuality({
    required DateTime timestamp,
    required DateTime now,
    required String source,
    bool hasConflicts = false,
  }) {
    final age = now.difference(timestamp).inDays;

    // Edge case 176: Recent + trusted source = high quality
    if (age <= 7 && source == 'user_reported' && !hasConflicts) {
      return DataQuality.high;
    }

    // Edge case 177: Recent but conflicts = medium quality
    if (age <= 7 && hasConflicts) {
      return DataQuality.medium;
    }

    // Edge case 178: Older data (>30 days) = low quality
    if (age > 30) {
      return DataQuality.low;
    }

    // Edge case 179: Auto-detected source = medium quality
    if (source == 'auto_detected') {
      return DataQuality.medium;
    }

    // Default: medium quality
    return DataQuality.medium;
  }

  // ---------------------------------------------------------------------------
  // Temporal Coherence Validation
  // ---------------------------------------------------------------------------

  /// Edge case 180: Validate temporal sequence (no time travel)
  static List<String> validateTemporalSequence<T>({
    required List<TemporalData<T>> sequence,
  }) {
    final violations = <String>[];

    if (sequence.isEmpty) return violations;

    // Edge case 181: Check for duplicate timestamps
    final timestamps =
        sequence.map((d) => d.timestamp.millisecondsSinceEpoch).toSet();
    if (timestamps.length < sequence.length) {
      violations.add('duplicate_timestamps');
    }

    // Edge case 182: Check for out-of-order timestamps
    for (var i = 1; i < sequence.length; i++) {
      if (sequence[i].timestamp.isBefore(sequence[i - 1].timestamp)) {
        violations.add('out_of_order_at_index_$i');
      }
    }

    // Edge case 183: Check for unreasonably large gaps (>90 days)
    for (var i = 1; i < sequence.length; i++) {
      final gap =
          sequence[i].timestamp.difference(sequence[i - 1].timestamp).inDays;
      if (gap > 90) {
        violations.add('large_gap_${gap}_days_at_index_$i');
      }
    }

    return violations;
  }

  /// Edge case 184: Detect anomalous temporal patterns
  static List<String> detectTemporalAnomalies({
    required List<TemporalData<double>> timeSeries,
  }) {
    final anomalies = <String>[];

    if (timeSeries.length < 3) return anomalies;

    // Edge case 185: Calculate typical gap duration
    final gaps = <int>[];
    for (var i = 1; i < timeSeries.length; i++) {
      gaps.add(
        timeSeries[i].timestamp.difference(timeSeries[i - 1].timestamp).inDays,
      );
    }

    final avgGap = gaps.fold<int>(0, (sum, gap) => sum + gap) / gaps.length;

    // Edge case 186: Flag gaps >3x average
    for (var i = 1; i < timeSeries.length; i++) {
      final gap = timeSeries[i]
          .timestamp
          .difference(timeSeries[i - 1].timestamp)
          .inDays;
      if (gap > avgGap * 3) {
        anomalies.add(
          'unusual_gap_${gap}_days_avg_${avgGap.toInt()}_at_index_$i',
        );
      }
    }

    // Edge case 187: Flag sudden value spikes (>2 std dev)
    if (timeSeries.length >= 5) {
      final values = timeSeries.map((d) => d.value).toList();
      final mean =
          values.fold<double>(0.0, (sum, v) => sum + v) / values.length;
      final variance = values.fold<double>(0.0, (sum, v) {
            final diff = v - mean;
            return sum + (diff * diff);
          }) /
          values.length;
      final stdDev = math.sqrt(variance);

      for (var i = 0; i < timeSeries.length; i++) {
        final deviation = (timeSeries[i].value - mean).abs() / stdDev;
        if (deviation > 2.0) {
          anomalies.add(
            'value_spike_${deviation.toStringAsFixed(1)}_stddev_at_index_$i',
          );
        }
      }
    }

    return anomalies;
  }

  // ---------------------------------------------------------------------------
  // Helper Methods
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _extractSymptomPattern(
    List<TemporalData<Map<String, Object?>>> data,
    DateTime now,
  ) {
    if (data.isEmpty) {
      return {'pattern': 'none', 'confidence': 0.0};
    }

    // Edge case 188: Find most common symptoms
    final symptomCounts = <String, int>{};
    for (final point in data) {
      final symptoms = point.value['symptoms'] as List<String>? ?? [];
      for (final symptom in symptoms) {
        symptomCounts[symptom] = (symptomCounts[symptom] ?? 0) + 1;
      }
    }

    // Edge case 189: Identify time-of-day patterns (morning vs evening)
    var morningCount = 0;
    var eveningCount = 0;
    for (final point in data) {
      final hour = point.timestamp.hour;
      if (hour >= 6 && hour < 12) {
        morningCount++;
      } else if (hour >= 18 && hour < 24) {
        eveningCount++;
      }
    }

    return {
      'most_common_symptoms': (symptomCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(3)
          .map((e) => e.key)
          .toList(),
      'time_pattern': morningCount > eveningCount
          ? 'morning'
          : eveningCount > morningCount
              ? 'evening'
              : 'no_pattern',
      'confidence': math.min(
        1.0,
        data.length / 7.0,
      ), // Full confidence with 7+ days
    };
  }
}
