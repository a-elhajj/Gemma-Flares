import 'dart:convert';

import '../database/wearable_sample_repository.dart';

class ContextAttributionService {
  ContextAttributionService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
    Duration workoutRecoveryBuffer = const Duration(hours: 2),
    Duration mealLeadWindow = const Duration(minutes: 30),
    Duration mealFollowWindow = const Duration(hours: 3),
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        _workoutRecoveryBuffer = workoutRecoveryBuffer,
        _mealLeadWindow = mealLeadWindow,
        _mealFollowWindow = mealFollowWindow;

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;
  final Duration _workoutRecoveryBuffer;
  final Duration _mealLeadWindow;
  final Duration _mealFollowWindow;

  Future<DailyContextFeatureRecord> recomputeDate(String dateLocal) async {
    final now = _nowProvider();
    final rows = await _repository.getSamplesForLocalDate(dateLocal);
    final summary = await _repository.getDailySummaryForDate(dateLocal);
    final start = DateTime.parse(
      '${dateLocal}T00:00:00Z',
    ).subtract(const Duration(days: 1));
    final end = DateTime.parse(
      '${dateLocal}T23:59:59Z',
    ).add(const Duration(days: 1));
    final symptoms = await _repository.getSymptomsBetween(
      start: start,
      end: end,
    );
    final intakeEvents = await _repository.getIntakeEventsBetween(
      start: start,
      end: end,
    );
    final flareLabel = await _repository.getFlareLabel(dateLocal);

    final windows = <ContextWindowRecord>[];

    for (final row in rows.where((row) => row['metric_name'] == 'workout')) {
      final workoutStart = DateTime.parse(row['start_time_utc'] as String);
      final workoutEnd = DateTime.parse(row['end_time_utc'] as String);
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: workoutStart,
          end: workoutEnd,
          contextType: 'exercise',
          source: 'healthkit_workout',
          confidence: 0.95,
          metadata: _metadataFromRow(row),
          now: now,
        ),
      );
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: workoutEnd,
          end: workoutEnd.add(_workoutRecoveryBuffer),
          contextType: 'recovery',
          source: 'healthkit_workout',
          confidence: 0.8,
          metadata: {
            'recovery_buffer_minutes': _workoutRecoveryBuffer.inMinutes,
            ..._metadataFromRow(row),
          },
          now: now,
        ),
      );
    }

    for (final row in rows.where(
      (row) => row['metric_name'] == 'sleep_segment',
    )) {
      final categoryValue = ((row['value_numeric'] as num?) ?? -1).toInt();
      if (!const {1, 3, 4, 5}.contains(categoryValue)) {
        continue;
      }
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: DateTime.parse(row['start_time_utc'] as String),
          end: DateTime.parse(row['end_time_utc'] as String),
          contextType: 'rest',
          source: 'sleep_window',
          confidence: 0.7,
          metadata: {'sleep_category': categoryValue},
          now: now,
        ),
      );
    }

    for (final symptom in symptoms) {
      final relation = symptom.mealRelation ?? '';
      if (!relation.startsWith('after_') && relation != 'before_meal') {
        continue;
      }
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: symptom.loggedAt.subtract(_mealLeadWindow),
          end: symptom.loggedAt.add(_mealFollowWindow),
          contextType: 'meal',
          source: 'symptom_note',
          confidence: symptom.extractionConfidence?.clamp(0.0, 1.0) ?? 0.65,
          metadata: {
            'meal_relation': relation,
            'symptom_type': symptom.symptomType,
          },
          now: now,
        ),
      );
    }

    for (final intake in intakeEvents) {
      final type = intake.eventType;
      final windowHours = switch (type) {
        'caffeine' => 6,
        'alcohol' => 12,
        'water' => 2,
        'medication_taken' || 'medication_skipped' => 24,
        _ => 3,
      };
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: intake.loggedAt.subtract(
            type == 'meal' ? _mealLeadWindow : Duration.zero,
          ),
          end: intake.loggedAt.add(Duration(hours: windowHours)),
          contextType: switch (type) {
            'caffeine' => 'caffeine',
            'alcohol' => 'alcohol',
            'water' => 'hydration',
            'medication_taken' || 'medication_skipped' => 'medication_window',
            _ => 'meal',
          },
          source: intake.source,
          confidence: intake.confidence.clamp(0.0, 1.0),
          metadata: {'event_type': intake.eventType, ...intake.metadataJson},
          now: now,
        ),
      );
    }

    final summaryJson = summary?.summaryJson ?? const <String, Object?>{};
    final sleepMinutes = _asDouble(summaryJson['sleep_total_minutes']);
    if (sleepMinutes != null && sleepMinutes < 360) {
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: DateTime.parse('${dateLocal}T00:00:00Z'),
          end: DateTime.parse('${dateLocal}T23:59:59Z'),
          contextType: 'poor_sleep',
          source: 'daily_summary',
          confidence: 0.7,
          metadata: {'sleep_total_minutes': sleepMinutes.round()},
          now: now,
        ),
      );
    }

    if ((_asDouble(summaryJson['rhythm_reliability_warning_count']) ?? 0) > 0) {
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: DateTime.parse('${dateLocal}T00:00:00Z'),
          end: DateTime.parse('${dateLocal}T23:59:59Z'),
          contextType: 'rhythm_reliability_warning',
          source: 'apple_health_rhythm',
          confidence: 0.8,
          metadata: {
            'event_count': summaryJson['rhythm_reliability_warning_count'],
          },
          now: now,
        ),
      );
    }

    if (flareLabel?.combinedFlare == true) {
      windows.add(
        _window(
          dateLocal: dateLocal,
          start: DateTime.parse('${dateLocal}T00:00:00Z'),
          end: DateTime.parse('${dateLocal}T23:59:59Z'),
          contextType: 'clinical_event',
          source: flareLabel!.labelSource,
          confidence: flareLabel.confidence == 'high' ? 0.95 : 0.75,
          metadata: {
            'inflammatory_flare': flareLabel.inflammatoryFlare,
            'symptomatic_flare': flareLabel.symptomaticFlare,
            'clinical_flare': flareLabel.clinicalFlare,
          },
          now: now,
        ),
      );
    }

    await _repository.upsertContextWindowsForDate(
      dateLocal: dateLocal,
      windows: windows,
    );

    final hrRows = rows
        .where((row) => row['metric_name'] == 'heart_rate')
        .toList(growable: false);
    final exerciseWindows = windows
        .where(
          (window) =>
              window.contextType == 'exercise' ||
              window.contextType == 'recovery',
        )
        .toList(growable: false);
    final mealWindows = windows
        .where(
          (window) =>
              window.contextType == 'meal' ||
              window.contextType == 'caffeine' ||
              window.contextType == 'alcohol',
        )
        .toList(growable: false);

    final exerciseExplainedPct = _overlapPct(hrRows, exerciseWindows);
    final mealExplainedPct = _overlapPct(hrRows, mealWindows);
    final medicationMissed = intakeEvents.any(
      (event) => event.eventType == 'medication_skipped',
    );
    final lowHydration =
        (_asDouble(summaryJson['dietary_water_ml_total']) ?? 0) > 0 &&
            (_asDouble(summaryJson['dietary_water_ml_total']) ?? 0) < 750;

    final featureJson = <String, Object?>{
      'context_exercise_present': _has(windows, 'exercise') ? 1 : 0,
      'context_recovery_present': _has(windows, 'recovery') ? 1 : 0,
      'context_meal_present': _has(windows, 'meal') ? 1 : 0,
      'context_caffeine_present': _has(windows, 'caffeine') ? 1 : 0,
      'context_alcohol_present': _has(windows, 'alcohol') ? 1 : 0,
      'context_low_hydration_possible': lowHydration ? 1 : 0,
      'context_medication_missed_possible': medicationMissed ? 1 : 0,
      'context_clinical_anchor_present':
          _has(windows, 'clinical_event') ? 1 : 0,
      'context_rhythm_reliability_warning':
          _has(windows, 'rhythm_reliability_warning') ? 1 : 0,
      'context_hr_exercise_explained_pct': exerciseExplainedPct,
      'context_hr_meal_explained_pct': mealExplainedPct,
      'context_signal_family_count': 0,
      'context_false_negative_guard_triggered': 0,
      'context_attribution_reason': _reason(
        exercisePct: exerciseExplainedPct,
        mealPct: mealExplainedPct,
        windows: windows,
      ),
      'context_confidence': _contextConfidence(windows),
      'context_window_count': windows.length,
      'context_workout_count':
          rows.where((row) => row['metric_name'] == 'workout').length,
      'context_meal_timed_symptom_count': windows
          .where(
            (window) =>
                window.contextType == 'meal' && window.source == 'symptom_note',
          )
          .length,
    };

    final qualityJson = <String, Object?>{
      'hr_sample_count': hrRows.length,
      'context_window_count': windows.length,
      'has_activity_context':
          _has(windows, 'exercise') || _has(windows, 'recovery'),
      'has_meal_context': _has(windows, 'meal'),
      'has_clinical_anchor': _has(windows, 'clinical_event'),
    };

    final record = DailyContextFeatureRecord(
      dateLocal: dateLocal,
      featureJson: featureJson,
      qualityJson: qualityJson,
      recomputedAt: now,
    );
    await _repository.upsertDailyContextFeature(record);
    return record;
  }

  ContextWindowRecord _window({
    required String dateLocal,
    required DateTime start,
    required DateTime end,
    required String contextType,
    required String source,
    required double confidence,
    required Map<String, Object?> metadata,
    required DateTime now,
  }) {
    return ContextWindowRecord(
      dateLocal: dateLocal,
      startTimeUtc: start.toUtc(),
      endTimeUtc: end.toUtc(),
      contextType: contextType,
      source: source,
      confidence: confidence.clamp(0.0, 1.0),
      metadataJson: metadata,
      createdAt: now,
    );
  }

  Map<String, Object?> _metadataFromRow(Map<String, Object?> row) {
    final raw = row['metadata_json'] as String?;
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      final decoded = row['metadata_json'] as String;
      return Map<String, Object?>.from(
        // ignore: avoid_dynamic_calls
        (const JsonCodec()).decode(decoded) as Map,
      );
    } catch (_) {
      return const {};
    }
  }

  bool _has(List<ContextWindowRecord> windows, String type) {
    return windows.any((window) => window.contextType == type);
  }

  double _overlapPct(
    List<Map<String, Object?>> rows,
    List<ContextWindowRecord> windows,
  ) {
    if (rows.isEmpty || windows.isEmpty) {
      return 0;
    }
    var overlapped = 0;
    for (final row in rows) {
      final start = DateTime.parse(row['start_time_utc'] as String);
      final end = DateTime.parse(row['end_time_utc'] as String);
      final overlaps = windows.any(
        (window) =>
            start.isBefore(window.endTimeUtc) &&
            end.isAfter(window.startTimeUtc),
      );
      if (overlaps) {
        overlapped += 1;
      }
    }
    return overlapped / rows.length;
  }

  String _reason({
    required double exercisePct,
    required double mealPct,
    required List<ContextWindowRecord> windows,
  }) {
    if (exercisePct >= 0.35 || _has(windows, 'recovery')) {
      return 'looks_workout_related';
    }
    if (mealPct >= 0.2 || _has(windows, 'meal')) {
      return 'looks_meal_timed';
    }
    if (_has(windows, 'clinical_event')) {
      return 'clinical_anchor_present';
    }
    if (_has(windows, 'poor_sleep')) {
      return 'sleep_recovery_context';
    }
    return 'less_explained_by_activity';
  }

  double _contextConfidence(List<ContextWindowRecord> windows) {
    if (windows.isEmpty) {
      return 0.35;
    }
    final sum = windows.fold<double>(
      0,
      (total, window) => total + window.confidence,
    );
    return (sum / windows.length).clamp(0.0, 1.0);
  }

  double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
