import 'dart:convert';

import '../contracts/health_bridge_contracts.dart';
import '../database/wearable_sample_repository.dart';
import 'health_sync_service.dart';
import 'rag_index_service.dart';
import 'rag_memory_service.dart';

class HealthRagSyncService {
  HealthRagSyncService({
    required WearableSampleRepository repository,
    required RagMemoryService ragMemoryService,
    RagIndexService? ragIndexService,
  })  : _repository = repository,
        _ragMemoryService = ragMemoryService,
        _ragIndexService = ragIndexService;

  final WearableSampleRepository _repository;
  final RagMemoryService _ragMemoryService;
  final RagIndexService? _ragIndexService;

  Future<List<RagWriteResult>> indexSyncRun({
    required HealthSyncRunResult result,
    required String reason,
  }) async {
    final touchedDates = result.metricResults
        .expand((item) => item.touchedDates)
        .toSet()
        .toList()
      ..sort();
    if (touchedDates.isEmpty) return const [];

    final writes = <RagWriteResult>[];
    for (final dateLocal in touchedDates) {
      final text = await _healthMemoryTextForDate(
        dateLocal: dateLocal,
        result: result,
        reason: reason,
      );
      writes.add(
        await _ragMemoryService.writeAndVerify(
          transactionId: _transactionId(dateLocal),
          sourceType: 'apple_health_sync',
          sourceId: dateLocal,
          text: text,
          metadata: {
            'date_local': dateLocal,
            'reason': reason,
            'started_at': result.startedAt.toUtc().toIso8601String(),
            'ended_at': result.endedAt.toUtc().toIso8601String(),
            'metric_count': result.metricResults.length,
            'inserted': result.inserted,
            'updated': result.updated,
            'ignored': result.ignored,
            'invalid': result.invalid,
            'has_failures': result.hasFailures,
          },
        ),
      );

      await _indexVectorHealthSync(
        dateLocal: dateLocal,
        result: result,
        reason: reason,
      );

      // Write the latest flare risk score for this date into RAG so Gemma can
      // retrieve it by date.  getLatestFlareRiskScore uses the production model
      // if available, falling back to risk_v1.  Failures are non-fatal — health
      // data still lands in RAG regardless of whether risk is ready.
      try {
        final riskRecord = await _repository.getLatestUserFacingFlareRiskScore(
          dateLocal: dateLocal,
        );
        if (riskRecord != null) {
          final riskWrite = await _ragMemoryService.writeFlareRisk(
            record: riskRecord,
            dateLocal: dateLocal,
          );
          writes.add(riskWrite);
        }
      } catch (_) {
        // Best-effort — do not block health RAG indexing on risk failures.
      }
    }
    return writes;
  }

  Future<void> _indexVectorHealthSync({
    required String dateLocal,
    required HealthSyncRunResult result,
    required String reason,
  }) async {
    final ragIndex = _ragIndexService;
    if (ragIndex == null) return;

    try {
      final summary = await _repository.getDailySummaryForDate(dateLocal);
      final features = await _repository.getDailyFeatureForDate(dateLocal);
      final samples = await _repository.getSamplesForLocalDate(dateLocal);
      final metrics = <String, Object?>{
        'reason': reason,
        'started_at': result.startedAt.toUtc().toIso8601String(),
        'ended_at': result.endedAt.toUtc().toIso8601String(),
        'metric_count': result.metricResults.length,
        'inserted': result.inserted,
        'updated': result.updated,
        'ignored': result.ignored,
        'invalid': result.invalid,
        'has_failures': result.hasFailures,
        if (summary != null) ...summary.summaryJson,
        if (features != null) ...features.featureJson,
      };

      final metricCounts = <String, int>{};
      for (final sample in samples) {
        final metricType = sample['metric_name']?.toString() ?? 'unknown';
        metricCounts[metricType] = (metricCounts[metricType] ?? 0) + 1;
      }
      for (final entry in metricCounts.entries) {
        metrics['sample_count_${entry.key}'] = entry.value;
      }

      await ragIndex.indexHealthSync(
        dateLocal: dateLocal,
        metrics: metrics,
        reason: reason,
      );
    } catch (_) {
      // Durable vector indexing is best-effort beside the audited corpus write.
    }
  }

  Future<String> _healthMemoryTextForDate({
    required String dateLocal,
    required HealthSyncRunResult result,
    required String reason,
  }) async {
    final summary = await _repository.getDailySummaryForDate(dateLocal);
    final features = await _repository.getDailyFeatureForDate(dateLocal);
    final samples = await _repository.getSamplesForLocalDate(dateLocal);
    final metricCounts = <String, int>{};
    for (final sample in samples) {
      final metricType = sample['metric_name']?.toString() ?? 'unknown';
      metricCounts[metricType] = (metricCounts[metricType] ?? 0) + 1;
    }
    final runMetrics = result.metricResults
        .where((item) => item.touchedDates.contains(dateLocal))
        .map(
          (item) => {
            'metric': item.metricType.wireName,
            'status': item.status,
            'fetched': item.fetched,
            'inserted': item.inserted,
            'updated': item.updated,
            'ignored': item.ignored,
            'invalid': item.invalid,
            if (item.error != null) 'error': item.error,
          },
        )
        .toList(growable: false);

    return const JsonEncoder.withIndent('  ').convert({
      'kind': 'apple_health_synced_day',
      'date_local': dateLocal,
      'transaction_id': _transactionId(dateLocal),
      'reason': reason,
      'sync_window': {
        'started_at': result.startedAt.toUtc().toIso8601String(),
        'ended_at': result.endedAt.toUtc().toIso8601String(),
      },
      'sync_totals': {
        'inserted': result.inserted,
        'updated': result.updated,
        'ignored': result.ignored,
        'invalid': result.invalid,
        'has_failures': result.hasFailures,
      },
      'touched_metrics': runMetrics,
      'stored_sample_count': samples.length,
      'stored_sample_counts_by_metric': metricCounts,
      if (summary != null)
        'daily_summary': {
          'sync_quality_score': summary.syncQualityScore,
          'recomputed_at': summary.recomputedAt.toUtc().toIso8601String(),
          'summary_json': summary.summaryJson,
        },
      if (features != null)
        'daily_features': {
          'recomputed_at': features.recomputedAt.toUtc().toIso8601String(),
          'feature_json': features.featureJson,
          'missingness_json': features.missingnessJson,
        },
    });
  }

  String _transactionId(String dateLocal) {
    return 'health_sync_tx_$dateLocal';
  }
}
