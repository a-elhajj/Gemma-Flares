import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../services/wearable_normalization_service.dart';
import '../services/food_entry.dart';
import 'app_database.dart';
import 'wearable_metric_names.dart';

class PersistSamplesResult {
  const PersistSamplesResult({
    required this.inserted,
    required this.updated,
    required this.ignored,
    required this.touchedDates,
  });

  final int inserted;
  final int updated;
  final int ignored;
  final List<String> touchedDates;
}

class DailySummaryRecord {
  const DailySummaryRecord({
    required this.dateLocal,
    required this.summaryJson,
    required this.syncQualityScore,
    required this.recomputedAt,
  });

  final String dateLocal;
  final Map<String, Object?> summaryJson;
  final double syncQualityScore;
  final DateTime recomputedAt;
}

class BaselineSnapshotRecord {
  const BaselineSnapshotRecord({
    required this.snapshotDateLocal,
    required this.readinessState,
    required this.baselineJson,
    required this.validDays,
    required this.createdAt,
  });

  final String snapshotDateLocal;
  final String readinessState;
  final Map<String, Object?> baselineJson;
  final int validDays;
  final DateTime createdAt;
}

class DailyFeatureRecord {
  const DailyFeatureRecord({
    required this.featureDateLocal,
    required this.featureJson,
    required this.missingnessJson,
    required this.recomputedAt,
  });

  final String featureDateLocal;
  final Map<String, Object?> featureJson;
  final Map<String, Object?> missingnessJson;
  final DateTime recomputedAt;
}

class FlareRiskScoreRecord {
  const FlareRiskScoreRecord({
    required this.dateLocal,
    required this.riskScore,
    required this.riskBand,
    required this.confidenceScore,
    required this.contributionJson,
    required this.featureSnapshotJson,
    required this.modelVersion,
    required this.createdAt,
  });

  final String dateLocal;
  final double riskScore;
  final String riskBand;
  final double confidenceScore;
  final Map<String, Object?> contributionJson;
  final Map<String, Object?> featureSnapshotJson;
  final String modelVersion;
  final DateTime createdAt;
}

class SyncStateRecord {
  const SyncStateRecord({
    required this.sourceName,
    this.lastSyncAt,
    this.lastBackfillStart,
    this.lastBackfillEnd,
    this.syncCursorJson,
    this.lastError,
    required this.updatedAt,
  });

  final String sourceName;
  final DateTime? lastSyncAt;
  final DateTime? lastBackfillStart;
  final DateTime? lastBackfillEnd;
  final String? syncCursorJson;
  final String? lastError;
  final DateTime updatedAt;
}

class ConversationRecord {
  const ConversationRecord({
    this.id,
    required this.createdAt,
    required this.userMessage,
    required this.assistantMessage,
    required this.toolTraceJson,
    required this.groundedSummaryJson,
    this.sessionId,
    this.isProactiveOpen = false,
  });

  final int? id;
  final DateTime createdAt;
  final String userMessage;
  final String assistantMessage;
  final Map<String, Object?> toolTraceJson;
  final Map<String, Object?> groundedSummaryJson;
  final String? sessionId;
  final bool isProactiveOpen;
}

const _messagesTable = 'messages';

class SymptomRecord {
  const SymptomRecord({
    this.id,
    required this.loggedAt,
    required this.symptomType,
    required this.severity,
    this.durationMinutes,
    this.mealRelation,
    this.notes,
    this.sourceTranscript,
    required this.extractionMethod,
    required this.extractionConfidence,
    required this.createdAt,
  });

  final int? id;
  final DateTime loggedAt;
  final String symptomType;
  final int? severity;
  final int? durationMinutes;
  final String? mealRelation;
  final String? notes;
  final String? sourceTranscript;
  final String extractionMethod;
  final double? extractionConfidence;
  final DateTime createdAt;
}

class RagMemoryTransactionRecord {
  const RagMemoryTransactionRecord({
    required this.transactionId,
    required this.sourceType,
    required this.sourceId,
    required this.chunkId,
    required this.status,
    required this.textHash,
    required this.createdAt,
    this.indexedAt,
    this.verifiedAt,
    this.retryCount = 0,
    this.lastError,
  });

  final String transactionId;
  final String sourceType;
  final String sourceId;
  final String chunkId;
  final String status;
  final String textHash;
  final DateTime createdAt;
  final DateTime? indexedAt;
  final DateTime? verifiedAt;
  final int retryCount;
  final String? lastError;
}

class RagMemoryTransactionSummary {
  const RagMemoryTransactionSummary({
    required this.totalCount,
    required this.bySourceType,
    required this.byStatus,
  });

  final int totalCount;
  final Map<String, int> bySourceType;
  final Map<String, int> byStatus;
}

// ─────────────────────────────────────────────────────────────────────────────
// Paper Replication Record Classes (Migration 004)
// ─────────────────────────────────────────────────────────────────────────────

class LabValueRecord {
  const LabValueRecord({
    this.id,
    required this.drawnDate,
    required this.labType,
    required this.valueNumeric,
    required this.unit,
    this.referenceHigh,
    this.labName,
    this.orderingProvider,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
    // v20: unit normalization + contribution tracking
    this.unitNormalizedValue,
    this.unitNormalizedUnit,
    this.isPaperBiomarker = false,
    this.labScoreContribution,
    this.labScoreDecayFactor,
    this.conflictResolution,
  });

  final int? id;
  final String drawnDate; // YYYY-MM-DD
  final String labType; // 'crp' | 'esr' | 'fc' | 'albumin' | etc.
  final double valueNumeric;
  final String unit; // raw unit as entered
  final double? referenceHigh;
  final String? labName;
  final String? orderingProvider;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;
  // v20 fields — nullable so existing records and tests remain valid
  final double? unitNormalizedValue;
  final String? unitNormalizedUnit;
  final bool isPaperBiomarker;
  final double? labScoreContribution;
  final double? labScoreDecayFactor;
  final String? conflictResolution; // 'used' | 'discarded_duplicate'
}

class EndoscopyRecord {
  const EndoscopyRecord({
    this.id,
    required this.procedureDate,
    required this.procedureType,
    this.mayoEndoscopicScore,
    this.sesCdScore,
    this.rutgeertsScore,
    this.findingsText,
    required this.biopsiesTaken,
    this.biopsyResult,
    this.provider,
    this.notes,
    required this.createdAt,
  });

  final int? id;
  final String procedureDate;
  final String procedureType;
  final int? mayoEndoscopicScore;
  final int? sesCdScore;
  final String? rutgeertsScore;
  final String? findingsText;
  final bool biopsiesTaken;
  final String? biopsyResult;
  final String? provider;
  final String? notes;
  final DateTime createdAt;
}

class Pro2SurveyRecord {
  static const cdV1Pain7Stool1 = 'cd_pro2_v1_pain7_stool1';
  static const cdV2Pain2Stool1 = 'cd_pro2_v2_pain2_stool1';
  static const ucV1BleedingStool = 'uc_pro2_v1_bleeding_stool';
  // IBS-SSS (Francis et al. 1997 / Rome IV): total 0–500, flare threshold ≥175.
  // Components stored in notes JSON; pro2Score holds the total.
  static const ibsSssV1 = 'ibs_sss_v1';

  const Pro2SurveyRecord({
    this.id,
    required this.surveyDate,
    required this.diseaseType,
    this.cdAbdominalPain,
    this.cdStoolFrequency,
    this.ucRectalBleeding,
    this.ucStoolFrequency,
    required this.pro2Score,
    required this.isFlare,
    this.scoreVersion = cdV1Pain7Stool1,
    this.notes,
    required this.createdAt,
  });

  final int? id;
  final String surveyDate; // YYYY-MM-DD
  final String diseaseType; // 'CD' | 'UC' | 'IBS' | 'IC'
  final int? cdAbdominalPain; // 0–3
  final int? cdStoolFrequency; // 0–4
  final int? ucRectalBleeding; // 0–3
  final int? ucStoolFrequency; // 0–3
  // For IBS: pro2Score holds the IBS-SSS total (0–500); components in notes.
  final double pro2Score;
  final bool isFlare;
  final String scoreVersion;
  final String? notes;
  final DateTime createdAt;

  // IBS-SSS flare threshold (Rome IV-aligned): active symptoms ≥175.
  static const ibsSssFlareThreshold = 175;

  // Compute IBS-SSS total from component scores (each 0–100 except painDays 0–4→×25).
  static double ibsSssTotal({
    required int painSeverity, // VAS 0–100
    required int painDays, // number of days with pain in past 10 days (0–10)
    required int bowelSatisfaction, // 0–100 dissatisfaction
    required int lifeInterference, // 0–100
    required int bloatingSeverity, // 0–100
  }) {
    final painDaysClamped = painDays.clamp(0, 10);
    return (painSeverity.clamp(0, 100) +
            painDaysClamped * 10 +
            bowelSatisfaction.clamp(0, 100) +
            lifeInterference.clamp(0, 100) +
            bloatingSeverity.clamp(0, 100))
        .toDouble();
  }
}

class FlareLabelRecord {
  const FlareLabelRecord({
    required this.labelDate,
    required this.inflammatoryFlare,
    required this.symptomaticFlare,
    this.clinicalFlare = false,
    required this.combinedFlare,
    required this.labelSource,
    required this.confidence,
    required this.recomputedAt,
  });

  final String labelDate; // YYYY-MM-DD
  final bool inflammatoryFlare;
  final bool symptomaticFlare;
  final bool clinicalFlare;
  final bool combinedFlare;
  final String labelSource; // 'lab' | 'pro2' | 'combined' | 'none'
  final String confidence; // 'high' | 'medium' | 'low'
  final DateTime recomputedAt;
}

class CosinorFeatureRecord {
  const CosinorFeatureRecord({
    required this.featureDate,
    this.mesor,
    this.amplitude,
    this.acrophaseRad,
    this.peakTimeHours,
    this.rSquared,
    this.sampleCount,
    this.timeSpanHours,
    required this.fitValid,
    required this.recomputedAt,
  });

  final String featureDate; // YYYY-MM-DD
  final double? mesor; // ms
  final double? amplitude; // ms
  final double? acrophaseRad; // radians
  final double? peakTimeHours; // 0.0–24.0
  final double? rSquared; // 0.0–1.0
  final int? sampleCount;
  final double? timeSpanHours;
  final bool fitValid;
  final DateTime recomputedAt;
}

class LogisticModelStateRecord {
  const LogisticModelStateRecord({
    required this.modelKey,
    required this.horizonDays,
    required this.flareType,
    required this.coefficientsJson,
    required this.intercept,
    required this.trainingSamples,
    this.lastAuc,
    this.lastF1,
    required this.updatedAt,
  });

  final String modelKey; // e.g. 'logistic_v1_inflammatory_7d'
  final int horizonDays;
  final String flareType; // 'inflammatory' | 'symptomatic'
  final Map<String, double> coefficientsJson;
  final double intercept;
  final int trainingSamples;
  final double? lastAuc;
  final double? lastF1;
  final DateTime updatedAt;
}

class LogisticTrainingHistoryRecord {
  const LogisticTrainingHistoryRecord({
    this.id,
    required this.modelKey,
    required this.sampleDate,
    required this.predictedProb,
    required this.actualLabel,
    required this.trainingN,
    required this.recordedAt,
  });

  final int? id;
  final String modelKey; // e.g. 'logistic_v1_inflammatory_7d'
  final String sampleDate; // YYYY-MM-DD
  final double predictedProb; // probability before SGD update
  final int actualLabel; // 0 or 1
  final int trainingN; // trainingSamples at observation time
  final DateTime recordedAt;
}

class ExperimentAssignmentRecord {
  const ExperimentAssignmentRecord({
    required this.experimentKey,
    required this.variant,
    required this.assignedAt,
  });

  final String experimentKey;
  final String variant;
  final DateTime assignedAt;
}

class ExperimentEventRecord {
  const ExperimentEventRecord({
    this.id,
    required this.eventName,
    required this.experimentKey,
    required this.variant,
    this.sessionId,
    required this.metadataJson,
    required this.createdAt,
  });

  final int? id;
  final String eventName;
  final String experimentKey;
  final String variant;
  final String? sessionId;
  final Map<String, Object?> metadataJson;
  final DateTime createdAt;
}

class DiagnosticLogRecord {
  const DiagnosticLogRecord({
    this.id,
    required this.createdAt,
    required this.sessionId,
    required this.level,
    required this.category,
    required this.eventName,
    required this.message,
    required this.metadataJson,
    this.source = 'app',
  });

  final int? id;
  final DateTime createdAt;
  final String sessionId;
  final String level;
  final String category;
  final String eventName;
  final String message;
  final Map<String, Object?> metadataJson;
  final String source;
}

class RuntimeEventRecord {
  const RuntimeEventRecord({
    this.id,
    required this.createdAt,
    required this.sessionId,
    required this.eventKind,
    this.modelRole = 'unknown',
    this.profile = 'unknown',
    this.availableMb = -1,
    this.residentMb = -1,
    this.durationMs = 0,
    this.metadataJson = const {},
  });

  final int? id;
  final DateTime createdAt;
  final String sessionId;
  final String eventKind;
  final String modelRole;
  final String profile;
  final int availableMb;
  final int residentMb;
  final int durationMs;
  final Map<String, Object?> metadataJson;
}

class ContextWindowRecord {
  const ContextWindowRecord({
    this.id,
    required this.dateLocal,
    required this.startTimeUtc,
    required this.endTimeUtc,
    required this.contextType,
    required this.source,
    required this.confidence,
    required this.metadataJson,
    required this.createdAt,
  });

  final int? id;
  final String dateLocal;
  final DateTime startTimeUtc;
  final DateTime endTimeUtc;
  final String contextType;
  final String source;
  final double confidence;
  final Map<String, Object?> metadataJson;
  final DateTime createdAt;
}

class DailyContextFeatureRecord {
  const DailyContextFeatureRecord({
    required this.dateLocal,
    required this.featureJson,
    required this.qualityJson,
    required this.recomputedAt,
  });

  final String dateLocal;
  final Map<String, Object?> featureJson;
  final Map<String, Object?> qualityJson;
  final DateTime recomputedAt;
}

class IntakeEventRecord {
  const IntakeEventRecord({
    this.id,
    required this.eventType,
    required this.loggedAt,
    required this.dateLocal,
    required this.source,
    required this.confidence,
    this.notes,
    required this.metadataJson,
    required this.createdAt,
  });

  final int? id;
  final String eventType;
  final DateTime loggedAt;
  final String dateLocal;
  final String source;
  final double confidence;
  final String? notes;
  final Map<String, Object?> metadataJson;
  final DateTime createdAt;
}

class HealthKitMetricRegistryRecord {
  const HealthKitMetricRegistryRecord({
    required this.metricKey,
    required this.healthkitIdentifier,
    required this.normalizedMetricName,
    required this.metricFamily,
    required this.availability,
    required this.permissionStatus,
    this.lastSuccessfulImportAt,
    this.lastErrorKind,
    required this.requiredForCoreScore,
    required this.usedForContextOnly,
    required this.updatedAt,
  });

  final String metricKey;
  final String healthkitIdentifier;
  final String normalizedMetricName;
  final String metricFamily;
  final String availability;
  final String permissionStatus;
  final DateTime? lastSuccessfulImportAt;
  final String? lastErrorKind;
  final bool requiredForCoreScore;
  final bool usedForContextOnly;
  final DateTime updatedAt;
}

class ClinicalRecordImportRecord {
  const ClinicalRecordImportRecord({
    this.id,
    required this.recordType,
    required this.source,
    this.effectiveDate,
    this.fhirResourceType,
    this.fhirId,
    required this.extractedJson,
    this.rawResourceJson,
    required this.importStatus,
    required this.createdAt,
  });

  final int? id;
  final String recordType;
  final String source;
  final String? effectiveDate;
  final String? fhirResourceType;
  final String? fhirId;
  final Map<String, Object?> extractedJson;
  final Map<String, Object?>? rawResourceJson;
  final String importStatus;
  final DateTime createdAt;
}

class ModelValidationRunRecord {
  const ModelValidationRunRecord({
    this.id,
    required this.runKey,
    required this.startedAt,
    this.completedAt,
    required this.status,
    required this.datasetSummaryJson,
    this.notes,
  });

  final int? id;
  final String runKey;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String status;
  final Map<String, Object?> datasetSummaryJson;
  final String? notes;
}

class ModelValidationMetricRecord {
  const ModelValidationMetricRecord({
    this.id,
    required this.runKey,
    required this.modelVersion,
    required this.labelType,
    this.horizonDays,
    required this.metricName,
    this.metricValue,
    required this.metadataJson,
    required this.createdAt,
  });

  final int? id;
  final String runKey;
  final String modelVersion;
  final String labelType;
  final int? horizonDays;
  final String metricName;
  final double? metricValue;
  final Map<String, Object?> metadataJson;
  final DateTime createdAt;
}

class GemmaTaskRunRecord {
  const GemmaTaskRunRecord({
    this.id,
    required this.taskType,
    required this.promptVersion,
    required this.schemaVersion,
    required this.modelId,
    required this.runtimeName,
    required this.status,
    required this.usedModelOutput,
    required this.validationStatus,
    required this.validationErrorsJson,
    required this.inputSummaryJson,
    required this.outputSummaryJson,
    this.outputHash,
    required this.latencyMs,
    required this.createdAt,
  });

  final int? id;
  final String taskType;
  final String promptVersion;
  final String schemaVersion;
  final String modelId;
  final String runtimeName;
  final String status;
  final bool usedModelOutput;
  final String validationStatus;
  final List<String> validationErrorsJson;
  final Map<String, Object?> inputSummaryJson;
  final Map<String, Object?> outputSummaryJson;
  final String? outputHash;
  final int latencyMs;
  final DateTime createdAt;
}

class GemmaExtractionReviewRecord {
  const GemmaExtractionReviewRecord({
    this.id,
    this.taskRunId,
    required this.reviewType,
    required this.sourceKind,
    this.sourceHash,
    required this.extractedJson,
    required this.userConfirmedJson,
    required this.reviewStatus,
    required this.createdAt,
    this.confirmedAt,
  });

  final int? id;
  final int? taskRunId;
  final String reviewType;
  final String sourceKind;
  final String? sourceHash;
  final Map<String, Object?> extractedJson;
  final Map<String, Object?> userConfirmedJson;
  final String reviewStatus;
  final DateTime createdAt;
  final DateTime? confirmedAt;
}

class DoctorSummaryRecord {
  const DoctorSummaryRecord({
    this.id,
    this.taskRunId,
    required this.summaryRangeDays,
    required this.summaryText,
    required this.contextSummaryJson,
    required this.createdAt,
  });

  final int? id;
  final int? taskRunId;
  final int summaryRangeDays;
  final String summaryText;
  final Map<String, Object?> contextSummaryJson;
  final DateTime createdAt;
}

class WearableSampleRepository {
  WearableSampleRepository({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;

  Future<PersistSamplesResult> upsertSamples(
    List<NormalizedWearableSample> samples,
  ) async {
    if (samples.isEmpty) {
      return const PersistSamplesResult(
        inserted: 0,
        updated: 0,
        ignored: 0,
        touchedDates: [],
      );
    }

    final database = await _database.open();
    var inserted = 0;
    var updated = 0;
    var ignored = 0;
    final touchedDates = <String>{};

    await database.transaction((txn) async {
      for (final sample in samples) {
        final existingRows = await txn.query(
          'wearable_samples',
          where: 'sample_key = ?',
          whereArgs: [sample.sampleKey],
          limit: 1,
        );

        if (existingRows.isEmpty) {
          await txn.insert('wearable_samples', sample.toRow());
          touchedDates.add(sample.localDate);
          inserted += 1;
          continue;
        }

        final existingRow = existingRows.single;
        if (_rowMatches(existingRow, sample)) {
          ignored += 1;
          continue;
        }

        await txn.update(
          'wearable_samples',
          sample.toRow(),
          where: 'sample_key = ?',
          whereArgs: [sample.sampleKey],
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        touchedDates.add(sample.localDate);
        final previousLocalDate = existingRow['local_date'];
        if (previousLocalDate is String && previousLocalDate.isNotEmpty) {
          touchedDates.add(previousLocalDate);
        }
        updated += 1;
      }
    });

    return PersistSamplesResult(
      inserted: inserted,
      updated: updated,
      ignored: ignored,
      touchedDates: touchedDates.toList()..sort(),
    );
  }

  Future<void> updateSyncState({
    required String sourceName,
    DateTime? lastSyncAt,
    DateTime? lastBackfillStart,
    DateTime? lastBackfillEnd,
    String? syncCursorJson,
    String? lastError,
  }) async {
    final database = await _database.open();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    await database.insert(
        'sync_state',
        {
          'source_name': sourceName,
          'last_sync_at': lastSyncAt?.toUtc().toIso8601String(),
          'last_backfill_start': lastBackfillStart?.toUtc().toIso8601String(),
          'last_backfill_end': lastBackfillEnd?.toUtc().toIso8601String(),
          'sync_cursor_json': syncCursorJson,
          'last_error': lastError,
          'updated_at': nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> countWearableSamples() async {
    final database = await _database.open();
    final result = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM wearable_samples',
    );
    return (result.single['count'] as int?) ?? 0;
  }

  Future<List<Map<String, Object?>>> getSamplesForLocalDate(
    String localDate,
  ) async {
    final database = await _database.open();
    return database.query(
      'wearable_samples',
      where: 'local_date = ? AND is_deleted = 0',
      whereArgs: [localDate],
      orderBy: 'start_time_utc ASC',
    );
  }

  Future<List<String>> getDistinctLocalDates() async {
    final database = await _database.open();
    final rows = await database.rawQuery(
      "SELECT DISTINCT local_date FROM wearable_samples WHERE local_date IS NOT NULL AND local_date != '' ORDER BY local_date ASC",
    );
    return rows
        .map((row) => row['local_date'] as String)
        .toList(growable: false);
  }

  // BUG-065 fix: IN-list now uses normalized snake_case names that
  // WearableNormalizationService writes into wearable_samples.metric_name.
  // The previous wireName IN-list ('stepCount', 'heartRateVariabilitySDNN', …)
  // never matched any row because the normalization service stores 'steps',
  // 'hrv_sdnn', … instead.
  Future<List<Map<String, Object?>>> getWearableMetricAggregates({
    int days = 14,
    DateTime? now,
  }) async {
    final database = await _database.open();
    final referenceTime = (now ?? DateTime.now()).toUtc();
    final cutoffDate = referenceTime.subtract(Duration(days: days));
    final cutoff = '${cutoffDate.year.toString().padLeft(4, '0')}-'
        '${cutoffDate.month.toString().padLeft(2, '0')}-'
        '${cutoffDate.day.toString().padLeft(2, '0')}';
    // Placeholders built dynamically from the registry so adding a metric
    // requires no SQL edit here.
    final names = kWearableMetricDbNames;
    final placeholders = List.filled(names.length, '?').join(', ');
    return database.rawQuery(
      '''
      SELECT
        metric_name,
        local_date,
        SUM(value_numeric)  AS total_value,
        AVG(value_numeric)  AS avg_value,
        MIN(value_numeric)  AS min_value,
        MAX(value_numeric)  AS max_value,
        COUNT(*)            AS sample_count,
        MAX(unit)           AS unit
      FROM wearable_samples
      WHERE is_deleted = 0
        AND local_date >= ?
        AND metric_name IN ($placeholders)
      GROUP BY metric_name, local_date
      ORDER BY local_date DESC, metric_name ASC
      ''',
      [cutoff, ...names],
    );
  }

  /// Targeted single-metric query for [WearableAggregationService].
  /// Returns one row per (metric_name, local_date) within [startDate]..[endDate].
  /// Rows are ordered by local_date DESC so callers can take the first for
  /// "latest" semantics.
  Future<List<Map<String, Object?>>> getMetricRowsForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async {
    final database = await _database.open();
    return database.rawQuery(
      '''
      SELECT
        metric_name,
        local_date,
        SUM(value_numeric)  AS total_value,
        AVG(value_numeric)  AS avg_value,
        MIN(value_numeric)  AS min_value,
        MAX(value_numeric)  AS max_value,
        COUNT(*)            AS sample_count,
        MAX(unit)           AS unit
      FROM wearable_samples
      WHERE is_deleted = 0
        AND metric_name = ?
        AND local_date >= ?
        AND local_date <= ?
      GROUP BY metric_name, local_date
      ORDER BY local_date DESC
      ''',
      [dbName, startDate, endDate],
    );
  }

  Future<List<String>> getDistinctSourcesForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async {
    final database = await _database.open();
    final rows = await database.rawQuery(
      '''
      SELECT DISTINCT source_name
      FROM wearable_samples
      WHERE is_deleted = 0
        AND metric_name = ?
        AND local_date >= ?
        AND local_date <= ?
        AND source_name IS NOT NULL
        AND source_name != ''
      ORDER BY source_name
      ''',
      [dbName, startDate, endDate],
    );
    return rows.map((r) => r['source_name'] as String).toList();
  }

  Future<void> upsertDailySummary(DailySummaryRecord record) async {
    final database = await _database.open();
    await database.insert(
        'daily_summaries',
        {
          'date_local': record.dateLocal,
          'summary_json': jsonEncode(record.summaryJson),
          'sync_quality_score': record.syncQualityScore,
          'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertBaselineSnapshot(BaselineSnapshotRecord record) async {
    final database = await _database.open();
    await database.insert(
        'baseline_snapshots',
        {
          'snapshot_date_local': record.snapshotDateLocal,
          'readiness_state': record.readinessState,
          'baseline_json': jsonEncode(record.baselineJson),
          'valid_days': record.validDays,
          'created_at': record.createdAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertDailyFeature(DailyFeatureRecord record) async {
    final database = await _database.open();
    await database.insert(
        'daily_features',
        {
          'feature_date_local': record.featureDateLocal,
          'feature_json': jsonEncode(record.featureJson),
          'missingness_json': jsonEncode(record.missingnessJson),
          'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DailyFeatureRecord?> getDailyFeatureForDate(String dateLocal) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_features',
      where: 'feature_date_local = ?',
      whereArgs: [dateLocal],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DailyFeatureRecord(
      featureDateLocal: row['feature_date_local'] as String,
      featureJson: Map<String, Object?>.from(
        jsonDecode(row['feature_json'] as String) as Map,
      ),
      missingnessJson: Map<String, Object?>.from(
        jsonDecode(row['missingness_json'] as String) as Map,
      ),
      recomputedAt: DateTime.parse(row['recomputed_at'] as String),
    );
  }

  Future<List<DailyFeatureRecord>> getDailyFeatures({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_features',
      orderBy: 'feature_date_local ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => DailyFeatureRecord(
            featureDateLocal: row['feature_date_local'] as String,
            featureJson: Map<String, Object?>.from(
              jsonDecode(row['feature_json'] as String) as Map,
            ),
            missingnessJson: Map<String, Object?>.from(
              jsonDecode(row['missingness_json'] as String) as Map,
            ),
            recomputedAt: DateTime.parse(row['recomputed_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<void> upsertFlareRiskScore(FlareRiskScoreRecord record) async {
    final database = await _database.open();
    await database.insert(
        'flare_risk_scores',
        {
          'date_local': record.dateLocal,
          'risk_score': record.riskScore,
          'risk_band': record.riskBand,
          'confidence_score': record.confidenceScore,
          'contribution_json': jsonEncode(record.contributionJson),
          'feature_snapshot_json': jsonEncode(record.featureSnapshotJson),
          'model_version': record.modelVersion,
          'created_at': record.createdAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DailySummaryRecord?> getLatestDailySummary() async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_summaries',
      orderBy: 'date_local DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final row = rows.single;
    return DailySummaryRecord(
      dateLocal: row['date_local'] as String,
      summaryJson:
          jsonDecode(row['summary_json'] as String) as Map<String, Object?>,
      syncQualityScore: ((row['sync_quality_score'] as num?) ?? 0).toDouble(),
      recomputedAt: DateTime.parse(row['recomputed_at'] as String),
    );
  }

  Future<DailySummaryRecord?> getDailySummaryForDate(String dateLocal) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_summaries',
      where: 'date_local = ?',
      whereArgs: [dateLocal],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return DailySummaryRecord(
      dateLocal: row['date_local'] as String,
      summaryJson: Map<String, Object?>.from(
        jsonDecode(row['summary_json'] as String) as Map,
      ),
      syncQualityScore: ((row['sync_quality_score'] as num?) ?? 0).toDouble(),
      recomputedAt: DateTime.parse(row['recomputed_at'] as String),
    );
  }

  Future<BaselineSnapshotRecord?> getLatestBaselineSnapshot() async {
    final database = await _database.open();
    final rows = await database.query(
      'baseline_snapshots',
      orderBy: 'snapshot_date_local DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final row = rows.single;
    return BaselineSnapshotRecord(
      snapshotDateLocal: row['snapshot_date_local'] as String,
      readinessState: row['readiness_state'] as String,
      baselineJson:
          jsonDecode(row['baseline_json'] as String) as Map<String, Object?>,
      validDays: (row['valid_days'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  Future<List<BaselineSnapshotRecord>> getBaselineSnapshots({
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'baseline_snapshots',
      orderBy: 'snapshot_date_local ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => BaselineSnapshotRecord(
            snapshotDateLocal: row['snapshot_date_local'] as String,
            readinessState: row['readiness_state'] as String,
            baselineJson: jsonDecode(row['baseline_json'] as String)
                as Map<String, Object?>,
            validDays: (row['valid_days'] as num?)?.toInt() ?? 0,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<FlareRiskScoreRecord?> getLatestFlareRiskScore({
    String modelVersion = 'risk_v1',
    String? dateLocal,
  }) async {
    final database = await _database.open();
    final whereParts = ['model_version = ?'];
    final whereArgs = <Object?>[modelVersion];
    if (dateLocal != null) {
      whereParts.add('date_local = ?');
      whereArgs.add(dateLocal);
    }
    final rows = await database.query(
      'flare_risk_scores',
      where: whereParts.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'date_local DESC, created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    return _rowToFlareRiskScore(rows.single);
  }

  Future<SyncStateRecord?> getSyncState(String sourceName) async {
    final database = await _database.open();
    final rows = await database.query(
      'sync_state',
      where: 'source_name = ?',
      whereArgs: [sourceName],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final row = rows.single;
    return SyncStateRecord(
      sourceName: row['source_name'] as String,
      lastSyncAt: _parseOptionalDateTime(row['last_sync_at'] as String?),
      lastBackfillStart: _parseOptionalDateTime(
        row['last_backfill_start'] as String?,
      ),
      lastBackfillEnd: _parseOptionalDateTime(
        row['last_backfill_end'] as String?,
      ),
      syncCursorJson: row['sync_cursor_json'] as String?,
      lastError: row['last_error'] as String?,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  Future<void> upsertAppSettingJson({
    required String key,
    required Object? value,
  }) async {
    final database = await _database.open();
    await database.insert(
        'app_settings',
        {
          'key': key,
          'value_json': jsonEncode(value),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Object?> getAppSettingJson(String key) async {
    final database = await _database.open();
    final rows = await database.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    return jsonDecode(rows.single['value_json'] as String);
  }

  Future<Map<String, Object?>?> getAppSettingMap(String key) async {
    final value = await getAppSettingJson(key);
    if (value is! Map) {
      return null;
    }

    return Map<String, Object?>.from(value);
  }

  Future<void> deleteAppSetting(String key) async {
    final database = await _database.open();
    await database.delete('app_settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<List<SymptomRecord>> getSymptomsBetween({
    required DateTime start,
    required DateTime end,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'symptoms',
      where: 'logged_at >= ? AND logged_at <= ?',
      whereArgs: [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
      orderBy: 'logged_at ASC',
    );
    return rows
        .map(
          (row) => SymptomRecord(
            id: (row['id'] as num?)?.toInt(),
            loggedAt: DateTime.parse(row['logged_at'] as String),
            symptomType: row['symptom_type'] as String,
            severity: (row['severity'] as num?)?.toInt(),
            durationMinutes: (row['duration_minutes'] as num?)?.toInt(),
            mealRelation: row['meal_relation'] as String?,
            notes: row['notes'] as String?,
            sourceTranscript: row['source_transcript'] as String?,
            extractionMethod: row['extraction_method'] as String? ?? 'unknown',
            extractionConfidence:
                (row['extraction_confidence'] as num?)?.toDouble(),
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<int> insertSymptom(SymptomRecord record) async {
    final database = await _database.open();
    return database.insert('symptoms', {
      'logged_at': record.loggedAt.toUtc().toIso8601String(),
      'symptom_type': record.symptomType,
      'severity': record.severity,
      'duration_minutes': record.durationMinutes,
      'meal_relation': record.mealRelation,
      'notes': record.notes,
      'source_transcript': record.sourceTranscript,
      'extraction_method': record.extractionMethod,
      'extraction_confidence': record.extractionConfidence,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<int> updateSymptom(SymptomRecord record) async {
    final id = record.id;
    if (id == null) {
      throw ArgumentError('Cannot update a symptom without an id.');
    }
    final database = await _database.open();
    return database.update(
      'symptoms',
      {
        'logged_at': record.loggedAt.toUtc().toIso8601String(),
        'symptom_type': record.symptomType,
        'severity': record.severity,
        'duration_minutes': record.durationMinutes,
        'meal_relation': record.mealRelation,
        'notes': record.notes,
        'source_transcript': record.sourceTranscript,
        'extraction_method': record.extractionMethod,
        'extraction_confidence': record.extractionConfidence,
        'created_at': record.createdAt.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteSymptom(int id) async {
    final database = await _database.open();
    return database.delete('symptoms', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<SymptomRecord>> getRecentSymptoms({int? limit = 10}) async {
    final database = await _database.open();
    final rows = await database.query(
      'symptoms',
      orderBy: 'logged_at DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => SymptomRecord(
            id: (row['id'] as num?)?.toInt(),
            loggedAt: DateTime.parse(row['logged_at'] as String),
            symptomType: row['symptom_type'] as String,
            severity: (row['severity'] as num?)?.toInt(),
            durationMinutes: (row['duration_minutes'] as num?)?.toInt(),
            mealRelation: row['meal_relation'] as String?,
            notes: row['notes'] as String?,
            sourceTranscript: row['source_transcript'] as String?,
            extractionMethod: row['extraction_method'] as String? ?? 'unknown',
            extractionConfidence:
                (row['extraction_confidence'] as num?)?.toDouble(),
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<int> insertConversation(ConversationRecord record) async {
    final database = await _database.open();
    return database.insert(_messagesTable, {
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'user_message': record.userMessage,
      'assistant_message': record.assistantMessage,
      'tool_trace_json': jsonEncode(record.toolTraceJson),
      'grounded_summary_json': jsonEncode(record.groundedSummaryJson),
      'session_id': record.sessionId,
      'is_proactive_open': record.isProactiveOpen ? 1 : 0,
    });
  }

  Future<List<ConversationRecord>> getRecentConversations({
    int? limit = 10,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      _messagesTable,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => ConversationRecord(
            id: (row['id'] as num?)?.toInt(),
            createdAt: DateTime.parse(row['created_at'] as String),
            userMessage: row['user_message'] as String,
            assistantMessage: row['assistant_message'] as String,
            toolTraceJson: jsonDecode(row['tool_trace_json'] as String)
                as Map<String, Object?>,
            groundedSummaryJson:
                jsonDecode(row['grounded_summary_json'] as String)
                    as Map<String, Object?>,
            sessionId: row['session_id'] as String?,
            isProactiveOpen:
                ((row['is_proactive_open'] as num?)?.toInt() ?? 0) == 1,
          ),
        )
        .toList(growable: false);
  }

  Future<int> clearConversations() async {
    final database = await _database.open();
    return database.delete(_messagesTable);
  }

  Future<void> upsertRagMemoryTransaction(
    RagMemoryTransactionRecord record,
  ) async {
    final database = await _database.open();
    await database.insert(
      'rag_memory_transactions',
      _ragMemoryTransactionToRow(record),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateRagMemoryTransactionStatus({
    required String transactionId,
    required String status,
    DateTime? indexedAt,
    DateTime? verifiedAt,
    String? lastError,
    bool incrementRetry = false,
  }) async {
    final database = await _database.open();
    final values = <String, Object?>{'status': status, 'last_error': lastError};
    if (indexedAt != null) {
      values['indexed_at'] = indexedAt.toUtc().toIso8601String();
    }
    if (verifiedAt != null) {
      values['verified_at'] = verifiedAt.toUtc().toIso8601String();
    }
    if (incrementRetry) {
      await database.rawUpdate(
        '''
        UPDATE rag_memory_transactions
        SET status = ?,
            last_error = ?,
            retry_count = retry_count + 1
        WHERE transaction_id = ?
        ''',
        [status, lastError, transactionId],
      );
      return;
    }
    await database.update(
      'rag_memory_transactions',
      values,
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
    );
  }

  Future<RagMemoryTransactionRecord?> getRagMemoryTransaction(
    String transactionId,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'rag_memory_transactions',
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToRagMemoryTransaction(rows.single);
  }

  Future<List<RagMemoryTransactionRecord>> getRagMemoryTransactions({
    List<String>? statuses,
    int? limit,
  }) async {
    final database = await _database.open();
    String? where;
    List<Object?>? whereArgs;
    if (statuses != null && statuses.isNotEmpty) {
      where = 'status IN (${List.filled(statuses.length, '?').join(',')})';
      whereArgs = statuses;
    }
    final rows = await database.query(
      'rag_memory_transactions',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_rowToRagMemoryTransaction).toList(growable: false);
  }

  Future<RagMemoryTransactionSummary> getRagMemoryTransactionSummary({
    List<String>? statuses,
  }) async {
    final database = await _database.open();
    String? where;
    List<Object?>? whereArgs;
    if (statuses != null && statuses.isNotEmpty) {
      where = 'status IN (${List.filled(statuses.length, '?').join(',')})';
      whereArgs = statuses;
    }

    final totalRows = await database.query(
      'rag_memory_transactions',
      columns: const ['COUNT(*) AS count'],
      where: where,
      whereArgs: whereArgs,
      limit: 1,
    );
    final sourceRows = await database.query(
      'rag_memory_transactions',
      columns: const ['source_type', 'COUNT(*) AS count'],
      where: where,
      whereArgs: whereArgs,
      groupBy: 'source_type',
      orderBy: 'count DESC, source_type ASC',
    );
    final statusRows = await database.query(
      'rag_memory_transactions',
      columns: const ['status', 'COUNT(*) AS count'],
      where: where,
      whereArgs: whereArgs,
      groupBy: 'status',
      orderBy: 'count DESC, status ASC',
    );

    Map<String, int> countsBy(String key, List<Map<String, Object?>> rows) {
      return {
        for (final row in rows)
          '${row[key] ?? 'unknown'}': ((row['count'] as num?) ?? 0).toInt(),
      };
    }

    return RagMemoryTransactionSummary(
      totalCount: ((totalRows.single['count'] as num?) ?? 0).toInt(),
      bySourceType: countsBy('source_type', sourceRows),
      byStatus: countsBy('status', statusRows),
    );
  }

  Future<void> markAllRagMemoryTransactionsDeleted() async {
    final database = await _database.open();
    await database.update('rag_memory_transactions', {
      'status': 'deleted',
      'last_error': null,
    });
  }

  Future<void> clearLocalUserData() async {
    final database = await _database.open();
    await database.transaction((txn) async {
      for (final table in const [
        // v2 memory and local-agent tables
        'rag_memory_transactions',
        'tool_audit',
        'scheduled_notifications',
        'bg_jobs',
        'tombstones',
        'vector_index_meta',
        'summaries',
        'pinned_fact_history',
        'pinned_facts',
        'unrelated_symptoms',
        'notification_preferences',
        // Paper replication tables (child-first order)
        'doctor_summaries',
        'gemma_extraction_reviews',
        'gemma_task_runs',
        'model_validation_metrics',
        'model_validation_runs',
        'clinical_record_imports',
        'healthkit_metric_registry',
        'healthkit_capability_status',
        'intake_events',
        'daily_context_features',
        'context_windows',
        'diagnostic_logs',
        'runtime_events',
        'experiment_events',
        'experiment_assignments',
        'logistic_training_history',
        'logistic_model_state',
        'endoscopy_records',
        'cosinor_features',
        'flare_labels',
        'pro2_surveys',
        'lab_values',
        'app_settings',
        // Original tables
        'flare_risk_scores',
        'displayed_score_snapshots',
        'daily_features',
        'baseline_snapshots',
        'daily_summaries',
        'symptoms',
        _messagesTable,
        'timeline_events',
        'sync_state',
        'wearable_samples',
      ]) {
        await txn.delete(table);
      }
      // Reset AUTOINCREMENT counters so display IDs restart at 1 after a clear.
      // sqlite_sequence only contains rows for tables that have had at least one
      // INSERT — the DELETE is a no-op for tables that were never written to.
      await txn.rawDelete(
        "DELETE FROM sqlite_sequence WHERE name IN ("
        "  'symptoms', 'lab_values', 'endoscopy_records', 'pro2_surveys',"
        "  'conversations', 'diagnostic_logs', 'gemma_task_runs',"
        "  'gemma_extraction_reviews', 'cosinor_features',"
        "  'logistic_training_history', 'logistic_model_state',"
        "  'doctor_summaries'"
        ")",
      );
    });
  }

  Future<List<DailySummaryRecord>> getDailySummaries({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_summaries',
      orderBy: 'date_local ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => DailySummaryRecord(
            dateLocal: row['date_local'] as String,
            summaryJson: jsonDecode(row['summary_json'] as String)
                as Map<String, Object?>,
            syncQualityScore:
                ((row['sync_quality_score'] as num?) ?? 0).toDouble(),
            recomputedAt: DateTime.parse(row['recomputed_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<List<FlareRiskScoreRecord>> getFlareRiskScores({
    int? limit,
    String? modelVersion,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'flare_risk_scores',
      where: modelVersion != null ? 'model_version = ?' : null,
      whereArgs: modelVersion != null ? [modelVersion] : null,
      orderBy: 'date_local ASC, model_version ASC',
      limit: limit,
    );
    return rows.map(_rowToFlareRiskScore).toList(growable: false);
  }

  Future<int> deleteFlareRiskScores({
    List<String>? dateLocals,
    List<String>? modelVersions,
  }) async {
    final database = await _database.open();
    final whereParts = <String>[];
    final whereArgs = <Object?>[];

    if (dateLocals != null && dateLocals.isNotEmpty) {
      whereParts.add(
        'date_local IN (${List.filled(dateLocals.length, '?').join(',')})',
      );
      whereArgs.addAll(dateLocals);
    }
    if (modelVersions != null && modelVersions.isNotEmpty) {
      whereParts.add(
        'model_version IN (${List.filled(modelVersions.length, '?').join(',')})',
      );
      whereArgs.addAll(modelVersions);
    }

    return database.delete(
      'flare_risk_scores',
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
    );
  }

  FlareRiskScoreRecord _rowToFlareRiskScore(Map<String, Object?> row) =>
      FlareRiskScoreRecord(
        dateLocal: row['date_local'] as String,
        riskScore: ((row['risk_score'] as num?) ?? 0).toDouble(),
        riskBand: row['risk_band'] as String,
        confidenceScore: ((row['confidence_score'] as num?) ?? 0).toDouble(),
        contributionJson: jsonDecode(row['contribution_json'] as String)
            as Map<String, Object?>,
        featureSnapshotJson: jsonDecode(row['feature_snapshot_json'] as String)
            as Map<String, Object?>,
        modelVersion: row['model_version'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  // ── Hourly HRV query for Cosinor ──────────────────────────────────────────

  Future<List<Map<String, Object?>>> getHrvSamplesForDate(
    String localDate,
  ) async {
    final database = await _database.open();
    return database.query(
      'wearable_samples',
      where: 'metric_name = ? AND local_date = ? AND is_deleted = 0',
      whereArgs: ['hrv_sdnn', localDate],
      orderBy: 'start_time_utc ASC',
    );
  }

  // ── Lab Values ─────────────────────────────────────────────────────────────

  Future<int> upsertLabValue(LabValueRecord record) async {
    final database = await _database.open();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    if (record.id != null) {
      await database.update(
        'lab_values',
        {
          'drawn_date': record.drawnDate,
          'lab_type': record.labType,
          'value_numeric': record.valueNumeric,
          'unit': record.unit,
          'reference_high': record.referenceHigh,
          'lab_name': record.labName,
          'ordering_provider': record.orderingProvider,
          'notes': record.notes,
          'updated_at': nowIso,
        },
        where: 'id = ?',
        whereArgs: [record.id],
      );
      return record.id!;
    }
    return database.insert('lab_values', {
      'drawn_date': record.drawnDate,
      'lab_type': record.labType,
      'value_numeric': record.valueNumeric,
      'unit': record.unit,
      'reference_high': record.referenceHigh,
      'lab_name': record.labName,
      'ordering_provider': record.orderingProvider,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': nowIso,
    });
  }

  Future<void> deleteLabValue(int id) async {
    final database = await _database.open();
    await database.delete('lab_values', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<LabValueRecord>> getLabValues({String? labType}) async {
    final database = await _database.open();
    final rows = await database.query(
      'lab_values',
      where: labType != null ? 'lab_type = ?' : null,
      whereArgs: labType != null ? [labType] : null,
      orderBy: 'drawn_date DESC',
    );
    return rows.map(_rowToLabValue).toList(growable: false);
  }

  Future<List<LabValueRecord>> getLabValuesInRange(
    String startDate,
    String endDate,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'lab_values',
      where: 'drawn_date >= ? AND drawn_date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'drawn_date ASC',
    );
    return rows.map(_rowToLabValue).toList(growable: false);
  }

  LabValueRecord _rowToLabValue(Map<String, Object?> row) => LabValueRecord(
        id: (row['id'] as num?)?.toInt(),
        drawnDate: row['drawn_date'] as String,
        labType: row['lab_type'] as String,
        valueNumeric: ((row['value_numeric'] as num?) ?? 0).toDouble(),
        unit: row['unit'] as String,
        referenceHigh: (row['reference_high'] as num?)?.toDouble(),
        labName: row['lab_name'] as String?,
        orderingProvider: row['ordering_provider'] as String?,
        notes: row['notes'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        unitNormalizedValue: (row['unit_normalized_value'] as num?)?.toDouble(),
        unitNormalizedUnit: row['unit_normalized_unit'] as String?,
        isPaperBiomarker: ((row['is_paper_biomarker'] as num?) ?? 0) != 0,
        labScoreContribution:
            (row['lab_score_contribution'] as num?)?.toDouble(),
        labScoreDecayFactor:
            (row['lab_score_decay_factor'] as num?)?.toDouble(),
        conflictResolution: row['conflict_resolution'] as String?,
      );

  // ── PRO-2 Surveys ──────────────────────────────────────────────────────────

  Future<int> insertEndoscopyRecord(EndoscopyRecord record) async {
    final database = await _database.open();
    return database.insert('endoscopy_records', {
      'procedure_date': record.procedureDate,
      'procedure_type': record.procedureType,
      'mayo_endoscopic_score': record.mayoEndoscopicScore,
      'ses_cd_score': record.sesCdScore,
      'rutgeerts_score': record.rutgeertsScore,
      'findings_text': record.findingsText,
      'biopsies_taken': record.biopsiesTaken ? 1 : 0,
      'biopsy_result': record.biopsyResult,
      'provider': record.provider,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<void> deleteEndoscopyRecord(int id) async {
    final database = await _database.open();
    await database.delete(
      'endoscopy_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<EndoscopyRecord>> getEndoscopyRecords() async {
    final database = await _database.open();
    final rows = await database.query(
      'endoscopy_records',
      orderBy: 'procedure_date DESC, created_at DESC',
    );
    return rows.map(_rowToEndoscopyRecord).toList(growable: false);
  }

  Future<List<EndoscopyRecord>> getEndoscopyRecordsInRange(
    String startDate,
    String endDate,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'endoscopy_records',
      where: 'procedure_date >= ? AND procedure_date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'procedure_date ASC, created_at ASC',
    );
    return rows.map(_rowToEndoscopyRecord).toList(growable: false);
  }

  EndoscopyRecord _rowToEndoscopyRecord(Map<String, Object?> row) =>
      EndoscopyRecord(
        id: (row['id'] as num?)?.toInt(),
        procedureDate: row['procedure_date'] as String,
        procedureType: row['procedure_type'] as String,
        mayoEndoscopicScore: (row['mayo_endoscopic_score'] as num?)?.toInt(),
        sesCdScore: (row['ses_cd_score'] as num?)?.toInt(),
        rutgeertsScore: row['rutgeerts_score'] as String?,
        findingsText: row['findings_text'] as String?,
        biopsiesTaken: ((row['biopsies_taken'] as num?)?.toInt() ?? 0) == 1,
        biopsyResult: row['biopsy_result'] as String?,
        provider: row['provider'] as String?,
        notes: row['notes'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  // ── PRO-2 Surveys ──────────────────────────────────────────────────────────

  Future<int> insertPro2Survey(Pro2SurveyRecord record) async {
    final database = await _database.open();
    return database.insert('pro2_surveys', {
      'survey_date': record.surveyDate,
      'disease_type': record.diseaseType,
      'cd_abdominal_pain': record.cdAbdominalPain,
      'cd_stool_frequency': record.cdStoolFrequency,
      'uc_rectal_bleeding': record.ucRectalBleeding,
      'uc_stool_frequency': record.ucStoolFrequency,
      'pro2_score': record.pro2Score,
      'is_flare': record.isFlare ? 1 : 0,
      'score_version': record.scoreVersion,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<Pro2SurveyRecord?> getPro2SurveyForDate(String date) async {
    final database = await _database.open();
    final rows = await database.query(
      'pro2_surveys',
      where: 'survey_date = ?',
      whereArgs: [date],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToPro2Survey(rows.single);
  }

  Future<List<Pro2SurveyRecord>> getPro2SurveysInRange(
    String startDate,
    String endDate,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'pro2_surveys',
      where: 'survey_date >= ? AND survey_date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'survey_date ASC',
    );
    return rows.map(_rowToPro2Survey).toList(growable: false);
  }

  Future<List<Pro2SurveyRecord>> getRecentPro2Surveys({int limit = 7}) async {
    final database = await _database.open();
    final rows = await database.query(
      'pro2_surveys',
      orderBy: 'survey_date DESC',
      limit: limit,
    );
    return rows.map(_rowToPro2Survey).toList(growable: false);
  }

  Future<List<Pro2SurveyRecord>> getPro2Surveys({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'pro2_surveys',
      orderBy: 'survey_date ASC, created_at ASC',
      limit: limit,
    );
    return rows.map(_rowToPro2Survey).toList(growable: false);
  }

  Pro2SurveyRecord _rowToPro2Survey(Map<String, Object?> row) =>
      Pro2SurveyRecord(
        id: (row['id'] as num?)?.toInt(),
        surveyDate: row['survey_date'] as String,
        diseaseType: row['disease_type'] as String,
        cdAbdominalPain: (row['cd_abdominal_pain'] as num?)?.toInt(),
        cdStoolFrequency: (row['cd_stool_frequency'] as num?)?.toInt(),
        ucRectalBleeding: (row['uc_rectal_bleeding'] as num?)?.toInt(),
        ucStoolFrequency: (row['uc_stool_frequency'] as num?)?.toInt(),
        pro2Score: ((row['pro2_score'] as num?) ?? 0).toDouble(),
        isFlare: ((row['is_flare'] as num?)?.toInt() ?? 0) == 1,
        scoreVersion: row['score_version'] as String? ??
            switch (row['disease_type'] as String?) {
              'UC' => Pro2SurveyRecord.ucV1BleedingStool,
              'IBS' => Pro2SurveyRecord.ibsSssV1,
              _ => Pro2SurveyRecord.cdV1Pain7Stool1,
            },
        notes: row['notes'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  // ── Flare Labels ───────────────────────────────────────────────────────────

  Future<void> upsertFlareLabel(FlareLabelRecord record) async {
    final database = await _database.open();
    await database.insert(
        'flare_labels',
        {
          'label_date': record.labelDate,
          'inflammatory_flare': record.inflammatoryFlare ? 1 : 0,
          'symptomatic_flare': record.symptomaticFlare ? 1 : 0,
          'clinical_flare': record.clinicalFlare ? 1 : 0,
          'combined_flare': record.combinedFlare ? 1 : 0,
          'label_source': record.labelSource,
          'confidence': record.confidence,
          'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<FlareLabelRecord?> getFlareLabel(String date) async {
    final database = await _database.open();
    final rows = await database.query(
      'flare_labels',
      where: 'label_date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToFlareLabel(rows.single);
  }

  Future<List<FlareLabelRecord>> getFlareLabelsInRange(
    String startDate,
    String endDate,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'flare_labels',
      where: 'label_date >= ? AND label_date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'label_date ASC',
    );
    return rows.map(_rowToFlareLabel).toList(growable: false);
  }

  Future<List<FlareLabelRecord>> getAllFlareLabels() async {
    final database = await _database.open();
    final rows = await database.query(
      'flare_labels',
      orderBy: 'label_date ASC',
    );
    return rows.map(_rowToFlareLabel).toList(growable: false);
  }

  FlareLabelRecord _rowToFlareLabel(
    Map<String, Object?> row,
  ) =>
      FlareLabelRecord(
        labelDate: row['label_date'] as String,
        inflammatoryFlare:
            ((row['inflammatory_flare'] as num?)?.toInt() ?? 0) == 1,
        symptomaticFlare:
            ((row['symptomatic_flare'] as num?)?.toInt() ?? 0) == 1,
        clinicalFlare: ((row['clinical_flare'] as num?)?.toInt() ?? 0) == 1,
        combinedFlare: ((row['combined_flare'] as num?)?.toInt() ?? 0) == 1,
        labelSource: row['label_source'] as String,
        confidence: row['confidence'] as String,
        recomputedAt: DateTime.parse(row['recomputed_at'] as String),
      );

  // ── Cosinor Features ───────────────────────────────────────────────────────

  Future<void> upsertCosinorFeature(CosinorFeatureRecord record) async {
    final database = await _database.open();
    await database.insert(
        'cosinor_features',
        {
          'feature_date': record.featureDate,
          'mesor': record.mesor,
          'amplitude': record.amplitude,
          'acrophase_rad': record.acrophaseRad,
          'peak_time_hours': record.peakTimeHours,
          'r_squared': record.rSquared,
          'sample_count': record.sampleCount,
          'time_span_hours': record.timeSpanHours,
          'fit_valid': record.fitValid ? 1 : 0,
          'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<CosinorFeatureRecord?> getCosinorFeature(String date) async {
    final database = await _database.open();
    final rows = await database.query(
      'cosinor_features',
      where: 'feature_date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToCosinorFeature(rows.single);
  }

  Future<List<CosinorFeatureRecord>> getCosinorFeaturesInRange(
    String startDate,
    String endDate,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'cosinor_features',
      where: 'feature_date >= ? AND feature_date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'feature_date ASC',
    );
    return rows.map(_rowToCosinorFeature).toList(growable: false);
  }

  Future<List<CosinorFeatureRecord>> getCosinorFeatures({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'cosinor_features',
      orderBy: 'feature_date ASC',
      limit: limit,
    );
    return rows.map(_rowToCosinorFeature).toList(growable: false);
  }

  CosinorFeatureRecord _rowToCosinorFeature(Map<String, Object?> row) =>
      CosinorFeatureRecord(
        featureDate: row['feature_date'] as String,
        mesor: (row['mesor'] as num?)?.toDouble(),
        amplitude: (row['amplitude'] as num?)?.toDouble(),
        acrophaseRad: (row['acrophase_rad'] as num?)?.toDouble(),
        peakTimeHours: (row['peak_time_hours'] as num?)?.toDouble(),
        rSquared: (row['r_squared'] as num?)?.toDouble(),
        sampleCount: (row['sample_count'] as num?)?.toInt(),
        timeSpanHours: (row['time_span_hours'] as num?)?.toDouble(),
        fitValid: ((row['fit_valid'] as num?)?.toInt() ?? 0) == 1,
        recomputedAt: DateTime.parse(row['recomputed_at'] as String),
      );

  // ── Logistic Model State ───────────────────────────────────────────────────

  Future<void> upsertLogisticModelState(LogisticModelStateRecord record) async {
    final database = await _database.open();
    await database.insert(
        'logistic_model_state',
        {
          'model_key': record.modelKey,
          'horizon_days': record.horizonDays,
          'flare_type': record.flareType,
          'coefficients_json': jsonEncode(record.coefficientsJson),
          'intercept': record.intercept,
          'training_samples': record.trainingSamples,
          'last_auc': record.lastAuc,
          'last_f1': record.lastF1,
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<LogisticModelStateRecord?> getLogisticModelState(
    String modelKey,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'logistic_model_state',
      where: 'model_key = ?',
      whereArgs: [modelKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToLogisticModelState(rows.single);
  }

  Future<List<LogisticModelStateRecord>> getAllLogisticModelStates() async {
    final database = await _database.open();
    final rows = await database.query(
      'logistic_model_state',
      orderBy: 'model_key ASC',
    );
    return rows.map(_rowToLogisticModelState).toList(growable: false);
  }

  LogisticModelStateRecord _rowToLogisticModelState(Map<String, Object?> row) =>
      LogisticModelStateRecord(
        modelKey: row['model_key'] as String,
        horizonDays: (row['horizon_days'] as num).toInt(),
        flareType: row['flare_type'] as String,
        coefficientsJson: (jsonDecode(row['coefficients_json'] as String)
                as Map<String, Object?>)
            .map(
          (key, value) => MapEntry(key, ((value as num?) ?? 0).toDouble()),
        ),
        intercept: ((row['intercept'] as num?) ?? 0).toDouble(),
        trainingSamples: (row['training_samples'] as num?)?.toInt() ?? 0,
        lastAuc: (row['last_auc'] as num?)?.toDouble(),
        lastF1: (row['last_f1'] as num?)?.toDouble(),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  // ── Logistic training history ─────────────────────────────────────────────

  Future<void> insertTrainingHistoryRecord(
    LogisticTrainingHistoryRecord record,
  ) async {
    await insertTrainingHistoryRecordIfAbsent(record);
  }

  Future<bool> insertTrainingHistoryRecordIfAbsent(
    LogisticTrainingHistoryRecord record,
  ) async {
    final database = await _database.open();
    final id = await database.insert(
        'logistic_training_history',
        {
          'model_key': record.modelKey,
          'sample_date': record.sampleDate,
          'predicted_prob': record.predictedProb,
          'actual_label': record.actualLabel,
          'training_n': record.trainingN,
          'recorded_at': record.recordedAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id != 0;
  }

  Future<bool> hasTrainingHistoryRecord({
    required String modelKey,
    required String sampleDate,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'logistic_training_history',
      columns: const ['id'],
      where: 'model_key = ? AND sample_date = ?',
      whereArgs: [modelKey, sampleDate],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<LogisticTrainingHistoryRecord>> getTrainingHistory(
    String modelKey, {
    int limit = 200,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'logistic_training_history',
      where: 'model_key = ?',
      whereArgs: [modelKey],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => LogisticTrainingHistoryRecord(
            id: row['id'] as int?,
            modelKey: row['model_key'] as String,
            sampleDate: row['sample_date'] as String,
            predictedProb: (row['predicted_prob'] as num).toDouble(),
            actualLabel: (row['actual_label'] as num).toInt(),
            trainingN: (row['training_n'] as num).toInt(),
            recordedAt: DateTime.parse(row['recorded_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  /// Deletes oldest rows for [modelKey] so at most [keepLast] rows remain.
  Future<void> pruneTrainingHistory(
    String modelKey, {
    int keepLast = 200,
  }) async {
    final database = await _database.open();
    await database.rawDelete(
      '''
      DELETE FROM logistic_training_history
      WHERE model_key = ?
        AND id NOT IN (
          SELECT id FROM logistic_training_history
          WHERE model_key = ?
          ORDER BY id DESC
          LIMIT ?
        )
    ''',
      [modelKey, modelKey, keepLast],
    );
  }

  Future<ExperimentAssignmentRecord?> getExperimentAssignment(
    String experimentKey,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'experiment_assignments',
      where: 'experiment_key = ?',
      whereArgs: [experimentKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return ExperimentAssignmentRecord(
      experimentKey: row['experiment_key'] as String,
      variant: row['variant'] as String,
      assignedAt: DateTime.parse(row['assigned_at'] as String),
    );
  }

  Future<void> upsertExperimentAssignment(
    ExperimentAssignmentRecord record,
  ) async {
    final database = await _database.open();
    await database.insert(
        'experiment_assignments',
        {
          'experiment_key': record.experimentKey,
          'variant': record.variant,
          'assigned_at': record.assignedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ExperimentAssignmentRecord>> getExperimentAssignments({
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'experiment_assignments',
      orderBy: 'experiment_key ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => ExperimentAssignmentRecord(
            experimentKey: row['experiment_key'] as String,
            variant: row['variant'] as String,
            assignedAt: DateTime.parse(row['assigned_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<int> insertExperimentEvent(ExperimentEventRecord record) async {
    final database = await _database.open();
    return database.insert('experiment_events', {
      'event_name': record.eventName,
      'experiment_key': record.experimentKey,
      'variant': record.variant,
      'session_id': record.sessionId,
      'metadata_json': jsonEncode(record.metadataJson),
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<ExperimentEventRecord>> getExperimentEvents({
    String? experimentKey,
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'experiment_events',
      where: experimentKey != null ? 'experiment_key = ?' : null,
      whereArgs: experimentKey != null ? [experimentKey] : null,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => ExperimentEventRecord(
            id: (row['id'] as num?)?.toInt(),
            eventName: row['event_name'] as String,
            experimentKey: row['experiment_key'] as String,
            variant: row['variant'] as String,
            sessionId: row['session_id'] as String?,
            metadataJson: Map<String, Object?>.from(
              jsonDecode(row['metadata_json'] as String) as Map,
            ),
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<int> insertDiagnosticLog(DiagnosticLogRecord record) async {
    final database = await _database.open();
    return database.insert('diagnostic_logs', {
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'session_id': record.sessionId,
      'level': record.level,
      'category': record.category,
      'event_name': record.eventName,
      'message': record.message,
      'metadata_json': jsonEncode(record.metadataJson),
      'source': record.source,
    });
  }

  Future<List<DiagnosticLogRecord>> getDiagnosticLogs({
    String? level,
    String? category,
    int? limit,
  }) async {
    final database = await _database.open();
    final where = <String>[];
    final args = <Object?>[];
    if (level != null) {
      where.add('level = ?');
      args.add(level);
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category);
    }
    final rows = await database.query(
      'diagnostic_logs',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToDiagnosticLog).toList(growable: false);
  }

  Future<int> insertRuntimeEvent(RuntimeEventRecord record) async {
    final database = await _database.open();
    return database.insert('runtime_events', {
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'session_id': record.sessionId,
      'event_kind': record.eventKind,
      'model_role': record.modelRole,
      'profile': record.profile,
      'available_mb': record.availableMb,
      'resident_mb': record.residentMb,
      'duration_ms': record.durationMs,
      'metadata_json': jsonEncode(record.metadataJson),
    });
  }

  Future<List<RuntimeEventRecord>> getRuntimeEvents({
    String? eventKind,
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'runtime_events',
      where: eventKind == null ? null : 'event_kind = ?',
      whereArgs: eventKind == null ? null : [eventKind],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToRuntimeEvent).toList(growable: false);
  }

  Map<String, Object?> _ragMemoryTransactionToRow(
    RagMemoryTransactionRecord record,
  ) {
    return {
      'transaction_id': record.transactionId,
      'source_type': record.sourceType,
      'source_id': record.sourceId,
      'chunk_id': record.chunkId,
      'status': record.status,
      'text_hash': record.textHash,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'indexed_at': record.indexedAt?.toUtc().toIso8601String(),
      'verified_at': record.verifiedAt?.toUtc().toIso8601String(),
      'retry_count': record.retryCount,
      'last_error': record.lastError,
    };
  }

  RagMemoryTransactionRecord _rowToRagMemoryTransaction(
    Map<String, Object?> row,
  ) {
    return RagMemoryTransactionRecord(
      transactionId: row['transaction_id'] as String,
      sourceType: row['source_type'] as String,
      sourceId: row['source_id'] as String,
      chunkId: row['chunk_id'] as String,
      status: row['status'] as String,
      textHash: row['text_hash'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      indexedAt: _parseOptionalDateTime(row['indexed_at'] as String?),
      verifiedAt: _parseOptionalDateTime(row['verified_at'] as String?),
      retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
      lastError: row['last_error'] as String?,
    );
  }

  Future<int> deleteDiagnosticLogsOlderThan(DateTime cutoff) async {
    final database = await _database.open();
    return database.delete(
      'diagnostic_logs',
      where: 'created_at < ?',
      whereArgs: [cutoff.toUtc().toIso8601String()],
    );
  }

  Future<int> trimDiagnosticLogs({required int maxRows}) async {
    if (maxRows < 1) {
      throw ArgumentError.value(maxRows, 'maxRows', 'Must be positive.');
    }
    final database = await _database.open();
    return database.rawDelete(
      '''
      DELETE FROM diagnostic_logs
      WHERE id NOT IN (
        SELECT id FROM diagnostic_logs
        ORDER BY created_at DESC, id DESC
        LIMIT ?
      )
      ''',
      [maxRows],
    );
  }

  DiagnosticLogRecord _rowToDiagnosticLog(Map<String, Object?> row) =>
      DiagnosticLogRecord(
        id: (row['id'] as num?)?.toInt(),
        createdAt: DateTime.parse(row['created_at'] as String),
        sessionId: row['session_id'] as String,
        level: row['level'] as String,
        category: row['category'] as String,
        eventName: row['event_name'] as String,
        message: row['message'] as String,
        metadataJson: Map<String, Object?>.from(
          jsonDecode(row['metadata_json'] as String) as Map,
        ),
        source: row['source'] as String? ?? 'app',
      );

  RuntimeEventRecord _rowToRuntimeEvent(Map<String, Object?> row) =>
      RuntimeEventRecord(
        id: (row['id'] as num?)?.toInt(),
        createdAt: DateTime.parse(row['created_at'] as String),
        sessionId: row['session_id'] as String,
        eventKind: row['event_kind'] as String,
        modelRole: row['model_role'] as String? ?? 'unknown',
        profile: row['profile'] as String? ?? 'unknown',
        availableMb: (row['available_mb'] as num?)?.toInt() ?? -1,
        residentMb: (row['resident_mb'] as num?)?.toInt() ?? -1,
        durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
        metadataJson: Map<String, Object?>.from(
          jsonDecode(row['metadata_json'] as String) as Map,
        ),
      );

  Future<void> upsertContextWindowsForDate({
    required String dateLocal,
    required List<ContextWindowRecord> windows,
  }) async {
    final database = await _database.open();
    await database.transaction((txn) async {
      await txn.delete(
        'context_windows',
        where: 'date_local = ?',
        whereArgs: [dateLocal],
      );
      for (final window in windows) {
        await txn.insert('context_windows', {
          'date_local': window.dateLocal,
          'start_time_utc': window.startTimeUtc.toUtc().toIso8601String(),
          'end_time_utc': window.endTimeUtc.toUtc().toIso8601String(),
          'context_type': window.contextType,
          'source': window.source,
          'confidence': window.confidence,
          'metadata_json': jsonEncode(window.metadataJson),
          'created_at': window.createdAt.toUtc().toIso8601String(),
        });
      }
    });
  }

  Future<List<ContextWindowRecord>> getContextWindows({
    String? dateLocal,
    String? contextType,
  }) async {
    final database = await _database.open();
    final where = <String>[];
    final args = <Object?>[];
    if (dateLocal != null) {
      where.add('date_local = ?');
      args.add(dateLocal);
    }
    if (contextType != null) {
      where.add('context_type = ?');
      args.add(contextType);
    }
    final rows = await database.query(
      'context_windows',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'start_time_utc ASC, id ASC',
    );
    return rows.map(_rowToContextWindow).toList(growable: false);
  }

  Future<void> upsertDailyContextFeature(
    DailyContextFeatureRecord record,
  ) async {
    final database = await _database.open();
    await database.insert(
        'daily_context_features',
        {
          'date_local': record.dateLocal,
          'feature_json': jsonEncode(record.featureJson),
          'quality_json': jsonEncode(record.qualityJson),
          'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DailyContextFeatureRecord?> getDailyContextFeatureForDate(
    String dateLocal,
  ) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_context_features',
      where: 'date_local = ?',
      whereArgs: [dateLocal],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToDailyContextFeature(rows.single);
  }

  Future<List<DailyContextFeatureRecord>> getDailyContextFeatures({
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'daily_context_features',
      orderBy: 'date_local ASC',
      limit: limit,
    );
    return rows.map(_rowToDailyContextFeature).toList(growable: false);
  }

  Future<int> upsertIntakeEvent(IntakeEventRecord record) async {
    final database = await _database.open();
    final row = {
      'event_type': record.eventType,
      'logged_at': record.loggedAt.toUtc().toIso8601String(),
      'date_local': record.dateLocal,
      'source': record.source,
      'confidence': record.confidence,
      'notes': record.notes,
      'metadata_json': jsonEncode(record.metadataJson),
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
    if (record.id != null) {
      await database.update(
        'intake_events',
        row,
        where: 'id = ?',
        whereArgs: [record.id],
      );
      return record.id!;
    }
    return database.insert('intake_events', row);
  }

  Future<void> deleteIntakeEvent(int id) async {
    final database = await _database.open();
    await database.delete('intake_events', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<IntakeEventRecord>> getIntakeEventsBetween({
    required DateTime start,
    required DateTime end,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'intake_events',
      where: 'logged_at >= ? AND logged_at <= ?',
      whereArgs: [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
      orderBy: 'logged_at ASC, id ASC',
    );
    return rows.map(_rowToIntakeEvent).toList(growable: false);
  }

  Future<int> upsertFoodEntry(FoodEntry entry) async {
    final database = await _database.open();
    final now = DateTime.now().toUtc();
    final row = _foodEntryToRow(entry, updatedAt: now);
    if (entry.id != null) {
      await database.update(
        'food_entries',
        row,
        where: 'id = ?',
        whereArgs: [entry.id],
      );
      return entry.id!;
    }
    return database.insert('food_entries', row);
  }

  Future<FoodEntry?> getFoodEntry(int id) async {
    final database = await _database.open();
    final rows = await database.query(
      'food_entries',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToFoodEntry(rows.single);
  }

  Future<void> deleteFoodEntry(int id) async {
    final database = await _database.open();
    await database.delete('food_entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<FoodEntry>> getFoodEntriesBetween({
    required DateTime start,
    required DateTime end,
    bool? triggerSuspected,
  }) async {
    final database = await _database.open();
    final where = <String>['logged_at >= ?', 'logged_at <= ?'];
    final args = <Object?>[
      start.toUtc().toIso8601String(),
      end.toUtc().toIso8601String(),
    ];
    if (triggerSuspected != null) {
      where.add('trigger_suspected = ?');
      args.add(triggerSuspected ? 1 : 0);
    }
    final rows = await database.query(
      'food_entries',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'logged_at ASC, id ASC',
    );
    return rows.map(_rowToFoodEntry).toList(growable: false);
  }

  Future<void> upsertHealthKitMetricRegistry(
    HealthKitMetricRegistryRecord record,
  ) async {
    final database = await _database.open();
    final row = {
      'metric_key': record.metricKey,
      'healthkit_identifier': record.healthkitIdentifier,
      'normalized_metric_name': record.normalizedMetricName,
      'metric_family': record.metricFamily,
      'availability': record.availability,
      'permission_status': record.permissionStatus,
      'last_successful_import_at':
          record.lastSuccessfulImportAt?.toUtc().toIso8601String(),
      'last_error_kind': record.lastErrorKind,
      'required_for_core_score': record.requiredForCoreScore ? 1 : 0,
      'used_for_context_only': record.usedForContextOnly ? 1 : 0,
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
    await database.insert(
      'healthkit_metric_registry',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await database.insert(
        'healthkit_capability_status',
        {
          'metric_key': record.metricKey,
          'healthkit_identifier': record.healthkitIdentifier,
          'availability': record.availability,
          'permission_status': record.permissionStatus,
          'last_successful_import_at':
              record.lastSuccessfulImportAt?.toUtc().toIso8601String(),
          'last_error_kind': record.lastErrorKind,
          'required_for_core_score': record.requiredForCoreScore ? 1 : 0,
          'used_for_context_only': record.usedForContextOnly ? 1 : 0,
          'updated_at': record.updatedAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<HealthKitMetricRegistryRecord>> getHealthKitMetricRegistry({
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'healthkit_metric_registry',
      orderBy: 'metric_key ASC',
      limit: limit,
    );
    return rows.map(_rowToHealthKitMetricRegistry).toList(growable: false);
  }

  Future<int> insertClinicalRecordImport(
    ClinicalRecordImportRecord record,
  ) async {
    final database = await _database.open();
    return database.insert('clinical_record_imports', {
      'record_type': record.recordType,
      'source': record.source,
      'effective_date': record.effectiveDate,
      'fhir_resource_type': record.fhirResourceType,
      'fhir_id': record.fhirId,
      'extracted_json': jsonEncode(record.extractedJson),
      'raw_resource_json': record.rawResourceJson == null
          ? null
          : jsonEncode(record.rawResourceJson),
      'import_status': record.importStatus,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<ClinicalRecordImportRecord>> getClinicalRecordImports({
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'clinical_record_imports',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToClinicalRecordImport).toList(growable: false);
  }

  Future<void> createValidationRun(ModelValidationRunRecord record) async {
    final database = await _database.open();
    await database.insert(
        'model_validation_runs',
        {
          'run_key': record.runKey,
          'started_at': record.startedAt.toUtc().toIso8601String(),
          'completed_at': record.completedAt?.toUtc().toIso8601String(),
          'status': record.status,
          'dataset_summary_json': jsonEncode(record.datasetSummaryJson),
          'notes': record.notes,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> upsertValidationMetric(ModelValidationMetricRecord record) async {
    final database = await _database.open();
    return database.insert('model_validation_metrics', {
      'run_key': record.runKey,
      'model_version': record.modelVersion,
      'label_type': record.labelType,
      'horizon_days': record.horizonDays,
      'metric_name': record.metricName,
      'metric_value': record.metricValue,
      'metadata_json': jsonEncode(record.metadataJson),
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<ModelValidationRunRecord>> getValidationRuns({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'model_validation_runs',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(_rowToModelValidationRun).toList(growable: false);
  }

  Future<List<ModelValidationMetricRecord>> getValidationMetrics({
    String? runKey,
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'model_validation_metrics',
      where: runKey != null ? 'run_key = ?' : null,
      whereArgs: runKey != null ? [runKey] : null,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToModelValidationMetric).toList(growable: false);
  }

  /// Returns the session-anchored displayed score for [sessionId].
  /// Falls back to [getLatestUserFacingFlareRiskScore] if no snapshot exists.
  Future<FlareRiskScoreRecord?> getDisplayedSessionScore({
    required String sessionId,
    String? dateLocal,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'displayed_score_snapshots',
      where: dateLocal != null
          ? 'session_id = ? AND date_local = ? AND superseded_at IS NULL'
          : 'session_id = ? AND superseded_at IS NULL',
      whereArgs: dateLocal != null ? [sessionId, dateLocal] : [sessionId],
      orderBy: 'displayed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return getLatestUserFacingFlareRiskScore(dateLocal: dateLocal);
    }
    final row = rows.first;
    final persisted = await getLatestFlareRiskScore(
      modelVersion: row['model_version'] as String,
      dateLocal: row['date_local'] as String,
    );
    return FlareRiskScoreRecord(
      dateLocal: row['date_local'] as String,
      riskScore: (row['risk_score'] as num).toDouble(),
      riskBand: row['risk_band'] as String,
      confidenceScore: (row['confidence_score'] as num).toDouble(),
      contributionJson: persisted?.contributionJson ?? const {},
      featureSnapshotJson: persisted?.featureSnapshotJson ?? const {},
      modelVersion: row['model_version'] as String,
      createdAt: DateTime.parse(row['displayed_at'] as String),
    );
  }

  /// Writes a new displayed score snapshot. Sets superseded_at on the prior
  /// record for this session, making it a stable session-scoped audit trail.
  Future<void> upsertDisplayedScoreSnapshot({
    required String sessionId,
    required FlareRiskScoreRecord score,
    required String triggerReason,
    String? userActionType,
    required DateTime displayedAt,
  }) async {
    final database = await _database.open();
    final now = displayedAt.toUtc().toIso8601String();
    await database.transaction((txn) async {
      // Supersede any non-superseded snapshot for this session + date
      await txn.update(
        'displayed_score_snapshots',
        {'superseded_at': now},
        where: 'session_id = ? AND date_local = ? AND superseded_at IS NULL',
        whereArgs: [sessionId, score.dateLocal],
      );
      await txn.insert('displayed_score_snapshots', {
        'session_id': sessionId,
        'date_local': score.dateLocal,
        'model_version': score.modelVersion,
        'risk_score': score.riskScore,
        'risk_band': score.riskBand,
        'confidence_score': score.confidenceScore,
        'trigger_reason': triggerReason,
        'user_action_type': userActionType,
        'displayed_at': now,
        'superseded_at': null,
      });
    });
  }

  Future<FlareRiskScoreRecord?> getLatestUserFacingFlareRiskScore({
    String? dateLocal,
  }) async {
    for (final version in const [
      'risk_v2_context_adjusted',
      'risk_v1',
    ]) {
      final score = await getLatestFlareRiskScore(
        modelVersion: version,
        dateLocal: dateLocal,
      );
      if (score != null) return score;
    }
    return null;
  }

  ContextWindowRecord _rowToContextWindow(Map<String, Object?> row) =>
      ContextWindowRecord(
        id: (row['id'] as num?)?.toInt(),
        dateLocal: row['date_local'] as String,
        startTimeUtc: DateTime.parse(row['start_time_utc'] as String),
        endTimeUtc: DateTime.parse(row['end_time_utc'] as String),
        contextType: row['context_type'] as String,
        source: row['source'] as String,
        confidence: ((row['confidence'] as num?) ?? 0).toDouble(),
        metadataJson: Map<String, Object?>.from(
          jsonDecode(row['metadata_json'] as String) as Map,
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  DailyContextFeatureRecord _rowToDailyContextFeature(
    Map<String, Object?> row,
  ) =>
      DailyContextFeatureRecord(
        dateLocal: row['date_local'] as String,
        featureJson: Map<String, Object?>.from(
          jsonDecode(row['feature_json'] as String) as Map,
        ),
        qualityJson: Map<String, Object?>.from(
          jsonDecode(row['quality_json'] as String) as Map,
        ),
        recomputedAt: DateTime.parse(row['recomputed_at'] as String),
      );

  IntakeEventRecord _rowToIntakeEvent(Map<String, Object?> row) =>
      IntakeEventRecord(
        id: (row['id'] as num?)?.toInt(),
        eventType: row['event_type'] as String,
        loggedAt: DateTime.parse(row['logged_at'] as String),
        dateLocal: row['date_local'] as String,
        source: row['source'] as String,
        confidence: ((row['confidence'] as num?) ?? 0).toDouble(),
        notes: row['notes'] as String?,
        metadataJson: Map<String, Object?>.from(
          jsonDecode(row['metadata_json'] as String) as Map,
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  Map<String, Object?> _foodEntryToRow(
    FoodEntry entry, {
    required DateTime updatedAt,
  }) {
    final loggedAt = entry.loggedAt.toUtc();
    return {
      'logged_at': loggedAt.toIso8601String(),
      'date_local': _dateKey(loggedAt),
      'food_name': entry.foodName.trim(),
      'description': _trimOrNull(entry.description),
      'meal_type': _trimOrNull(entry.mealType),
      'calories': entry.calories,
      'portion_grams': entry.portionGrams,
      'portion_unit': _trimOrNull(entry.portionUnit),
      'is_gluten_free': _boolToInt(entry.isGlutenFree),
      'is_lactose_free': _boolToInt(entry.isLactoseFree),
      'is_dairy_free': _boolToInt(entry.isDairyFree),
      'is_high_fiber': _boolToInt(entry.isHighFiber),
      'is_high_fat': _boolToInt(entry.isHighFat),
      'is_spicy': _boolToInt(entry.isSpicy),
      'fiber_grams': entry.fiberGrams,
      'protein_grams': entry.proteinGrams,
      'fat_grams': entry.fatGrams,
      'carb_grams': entry.carbGrams,
      'sugar_grams': entry.sugarGrams,
      'sodium_mg': entry.sodiumMg,
      'allergens_json': jsonEncode(
        entry.allergens
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList(growable: false),
      ),
      'notes': _trimOrNull(entry.notes),
      'trigger_suspected': entry.triggerSuspected ? 1 : 0,
      'source': entry.source.trim().isEmpty ? 'manual' : entry.source.trim(),
      'created_at': entry.createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  FoodEntry _rowToFoodEntry(Map<String, Object?> row) => FoodEntry(
        id: (row['id'] as num?)?.toInt(),
        loggedAt: DateTime.parse(row['logged_at'] as String),
        foodName: row['food_name'] as String,
        description: row['description'] as String?,
        mealType: row['meal_type'] as String?,
        calories: (row['calories'] as num?)?.toDouble(),
        portionGrams: (row['portion_grams'] as num?)?.toDouble(),
        portionUnit: row['portion_unit'] as String?,
        isGlutenFree: _intToNullableBool(row['is_gluten_free']),
        isLactoseFree: _intToNullableBool(row['is_lactose_free']),
        isDairyFree: _intToNullableBool(row['is_dairy_free']),
        isHighFiber: _intToNullableBool(row['is_high_fiber']),
        isHighFat: _intToNullableBool(row['is_high_fat']),
        isSpicy: _intToNullableBool(row['is_spicy']),
        fiberGrams: (row['fiber_grams'] as num?)?.toDouble(),
        proteinGrams: (row['protein_grams'] as num?)?.toDouble(),
        fatGrams: (row['fat_grams'] as num?)?.toDouble(),
        carbGrams: (row['carb_grams'] as num?)?.toDouble(),
        sugarGrams: (row['sugar_grams'] as num?)?.toDouble(),
        sodiumMg: (row['sodium_mg'] as num?)?.toDouble(),
        allergens: (jsonDecode(row['allergens_json'] as String) as List)
            .whereType<String>()
            .toList(growable: false),
        notes: row['notes'] as String?,
        triggerSuspected:
            ((row['trigger_suspected'] as num?)?.toInt() ?? 0) == 1,
        source: row['source'] as String? ?? 'manual',
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  int? _boolToInt(bool? value) => value == null ? null : (value ? 1 : 0);

  bool? _intToNullableBool(Object? value) {
    if (value == null) return null;
    return ((value as num?)?.toInt() ?? 0) == 1;
  }

  String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String _dateKey(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  HealthKitMetricRegistryRecord _rowToHealthKitMetricRegistry(
    Map<String, Object?> row,
  ) =>
      HealthKitMetricRegistryRecord(
        metricKey: row['metric_key'] as String,
        healthkitIdentifier: row['healthkit_identifier'] as String,
        normalizedMetricName: row['normalized_metric_name'] as String,
        metricFamily: row['metric_family'] as String,
        availability: row['availability'] as String,
        permissionStatus: row['permission_status'] as String,
        lastSuccessfulImportAt: _parseOptionalDateTime(
          row['last_successful_import_at'] as String?,
        ),
        lastErrorKind: row['last_error_kind'] as String?,
        requiredForCoreScore:
            ((row['required_for_core_score'] as num?)?.toInt() ?? 0) == 1,
        usedForContextOnly:
            ((row['used_for_context_only'] as num?)?.toInt() ?? 0) == 1,
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  ClinicalRecordImportRecord _rowToClinicalRecordImport(
    Map<String, Object?> row,
  ) =>
      ClinicalRecordImportRecord(
        id: (row['id'] as num?)?.toInt(),
        recordType: row['record_type'] as String,
        source: row['source'] as String,
        effectiveDate: row['effective_date'] as String?,
        fhirResourceType: row['fhir_resource_type'] as String?,
        fhirId: row['fhir_id'] as String?,
        extractedJson: Map<String, Object?>.from(
          jsonDecode(row['extracted_json'] as String) as Map,
        ),
        rawResourceJson: row['raw_resource_json'] == null
            ? null
            : Map<String, Object?>.from(
                jsonDecode(row['raw_resource_json'] as String) as Map,
              ),
        importStatus: row['import_status'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  ModelValidationRunRecord _rowToModelValidationRun(Map<String, Object?> row) =>
      ModelValidationRunRecord(
        id: (row['id'] as num?)?.toInt(),
        runKey: row['run_key'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        completedAt: _parseOptionalDateTime(row['completed_at'] as String?),
        status: row['status'] as String,
        datasetSummaryJson: Map<String, Object?>.from(
          jsonDecode(row['dataset_summary_json'] as String) as Map,
        ),
        notes: row['notes'] as String?,
      );

  ModelValidationMetricRecord _rowToModelValidationMetric(
    Map<String, Object?> row,
  ) =>
      ModelValidationMetricRecord(
        id: (row['id'] as num?)?.toInt(),
        runKey: row['run_key'] as String,
        modelVersion: row['model_version'] as String,
        labelType: row['label_type'] as String,
        horizonDays: (row['horizon_days'] as num?)?.toInt(),
        metricName: row['metric_name'] as String,
        metricValue: (row['metric_value'] as num?)?.toDouble(),
        metadataJson: Map<String, Object?>.from(
          jsonDecode(row['metadata_json'] as String) as Map,
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  Future<int> insertGemmaTaskRun(GemmaTaskRunRecord record) async {
    final database = await _database.open();
    return database.insert('gemma_task_runs', {
      'task_type': record.taskType,
      'prompt_version': record.promptVersion,
      'schema_version': record.schemaVersion,
      'model_id': record.modelId,
      'runtime_name': record.runtimeName,
      'status': record.status,
      'used_model_output': record.usedModelOutput ? 1 : 0,
      'validation_status': record.validationStatus,
      'validation_errors_json': jsonEncode(record.validationErrorsJson),
      'input_summary_json': jsonEncode(record.inputSummaryJson),
      'output_summary_json': jsonEncode(record.outputSummaryJson),
      'output_hash': record.outputHash,
      'latency_ms': record.latencyMs,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<GemmaTaskRunRecord>> getGemmaTaskRuns({
    String? taskType,
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'gemma_task_runs',
      where: taskType == null ? null : 'task_type = ?',
      whereArgs: taskType == null ? null : [taskType],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToGemmaTaskRun).toList(growable: false);
  }

  Future<int> insertGemmaExtractionReview(
    GemmaExtractionReviewRecord record,
  ) async {
    final database = await _database.open();
    return database.insert('gemma_extraction_reviews', {
      'task_run_id': record.taskRunId,
      'review_type': record.reviewType,
      'source_kind': record.sourceKind,
      'source_hash': record.sourceHash,
      'extracted_json': jsonEncode(record.extractedJson),
      'user_confirmed_json': jsonEncode(record.userConfirmedJson),
      'review_status': record.reviewStatus,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'confirmed_at': record.confirmedAt?.toUtc().toIso8601String(),
    });
  }

  Future<void> updateGemmaExtractionReviewConfirmation({
    required int id,
    required Map<String, Object?> userConfirmedJson,
    required String reviewStatus,
    required DateTime confirmedAt,
  }) async {
    final database = await _database.open();
    await database.update(
      'gemma_extraction_reviews',
      {
        'user_confirmed_json': jsonEncode(userConfirmedJson),
        'review_status': reviewStatus,
        'confirmed_at': confirmedAt.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<GemmaExtractionReviewRecord>> getGemmaExtractionReviews({
    String? reviewType,
    int? limit,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'gemma_extraction_reviews',
      where: reviewType == null ? null : 'review_type = ?',
      whereArgs: reviewType == null ? null : [reviewType],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToGemmaExtractionReview).toList(growable: false);
  }

  Future<int> insertDoctorSummary(DoctorSummaryRecord record) async {
    final database = await _database.open();
    return database.insert('doctor_summaries', {
      'task_run_id': record.taskRunId,
      'summary_range_days': record.summaryRangeDays,
      'summary_text': record.summaryText,
      'context_summary_json': jsonEncode(record.contextSummaryJson),
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<DoctorSummaryRecord>> getDoctorSummaries({int? limit}) async {
    final database = await _database.open();
    final rows = await database.query(
      'doctor_summaries',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_rowToDoctorSummary).toList(growable: false);
  }

  GemmaTaskRunRecord _rowToGemmaTaskRun(Map<String, Object?> row) =>
      GemmaTaskRunRecord(
        id: (row['id'] as num?)?.toInt(),
        taskType: row['task_type'] as String,
        promptVersion: row['prompt_version'] as String,
        schemaVersion: row['schema_version'] as String,
        modelId: row['model_id'] as String,
        runtimeName: row['runtime_name'] as String,
        status: row['status'] as String,
        usedModelOutput:
            ((row['used_model_output'] as num?)?.toInt() ?? 0) == 1,
        validationStatus: row['validation_status'] as String,
        validationErrorsJson:
            (jsonDecode(row['validation_errors_json'] as String) as List)
                .map((item) => item.toString())
                .toList(growable: false),
        inputSummaryJson: Map<String, Object?>.from(
          jsonDecode(row['input_summary_json'] as String) as Map,
        ),
        outputSummaryJson: Map<String, Object?>.from(
          jsonDecode(row['output_summary_json'] as String) as Map,
        ),
        outputHash: row['output_hash'] as String?,
        latencyMs: (row['latency_ms'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  GemmaExtractionReviewRecord _rowToGemmaExtractionReview(
    Map<String, Object?> row,
  ) =>
      GemmaExtractionReviewRecord(
        id: (row['id'] as num?)?.toInt(),
        taskRunId: (row['task_run_id'] as num?)?.toInt(),
        reviewType: row['review_type'] as String,
        sourceKind: row['source_kind'] as String,
        sourceHash: row['source_hash'] as String?,
        extractedJson: Map<String, Object?>.from(
          jsonDecode(row['extracted_json'] as String) as Map,
        ),
        userConfirmedJson: Map<String, Object?>.from(
          jsonDecode(row['user_confirmed_json'] as String) as Map,
        ),
        reviewStatus: row['review_status'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        confirmedAt: _parseOptionalDateTime(row['confirmed_at'] as String?),
      );

  DoctorSummaryRecord _rowToDoctorSummary(Map<String, Object?> row) =>
      DoctorSummaryRecord(
        id: (row['id'] as num?)?.toInt(),
        taskRunId: (row['task_run_id'] as num?)?.toInt(),
        summaryRangeDays: (row['summary_range_days'] as num?)?.toInt() ?? 0,
        summaryText: row['summary_text'] as String,
        contextSummaryJson: Map<String, Object?>.from(
          jsonDecode(row['context_summary_json'] as String) as Map,
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  DateTime? _parseOptionalDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.parse(value);
  }

  bool _rowMatches(Map<String, Object?> row, NormalizedWearableSample sample) {
    return row['local_date'] == sample.localDate &&
        row['vendor_sample_id'] == sample.vendorSampleId &&
        row['source_name'] == sample.sourceName &&
        row['source_device'] == sample.sourceDevice &&
        row['metric_name'] == sample.metricName &&
        row['metric_family'] == sample.metricFamily &&
        row['value_numeric'] == sample.valueNumeric &&
        row['unit'] == sample.unit &&
        row['start_time_utc'] == sample.startTimeUtc.toIso8601String() &&
        row['end_time_utc'] == sample.endTimeUtc.toIso8601String() &&
        row['timezone'] == sample.timezone &&
        row['aggregation_level'] == sample.aggregationLevel &&
        row['is_estimated'] == (sample.isEstimated ? 1 : 0) &&
        row['is_deleted'] == (sample.isDeleted ? 1 : 0) &&
        row['metadata_json'] == jsonEncode(sample.metadata) &&
        row['source_payload_json'] == jsonEncode(sample.sourcePayload);
  }
}
