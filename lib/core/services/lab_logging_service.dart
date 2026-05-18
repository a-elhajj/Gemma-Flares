import '../database/wearable_sample_repository.dart';
import 'analytics_refresh_service.dart';
import 'rag_index_service.dart';
import 'gemma_task_service.dart';
import 'rag_memory_service.dart';
import 'tool_audit_service.dart';

class LabLoggingResult {
  const LabLoggingResult({
    required this.savedLabs,
    required this.ragIndexedByLabId,
    this.ragStatusByLabId = const {},
    this.ragTransactionIdByLabId = const {},
    this.ragValidatedByLabId = const {},
    this.ragValidationStatusByLabId = const {},
    this.ragValidationSnippetByLabId = const {},
    required this.updatedRiskScore,
    this.analyticsRefreshStatus = 'not_run',
    this.reviewId,
    this.toolAuditId,
  });

  final List<LabValueRecord> savedLabs;
  final Map<int, bool> ragIndexedByLabId;
  final Map<int, String> ragStatusByLabId;
  final Map<int, String> ragTransactionIdByLabId;
  final Map<int, bool> ragValidatedByLabId;
  final Map<int, String> ragValidationStatusByLabId;
  final Map<int, String> ragValidationSnippetByLabId;
  final FlareRiskScoreRecord? updatedRiskScore;
  final String analyticsRefreshStatus;
  final int? reviewId;
  final int? toolAuditId;
}

class LabLoggingService {
  LabLoggingService({
    required WearableSampleRepository repository,
    AnalyticsRefreshService? analyticsRefreshService,
    RagIndexService? ragIndexService,
    RagMemoryService? ragMemoryService,
    GemmaTaskService? gemmaTaskService,
    ToolAuditService? toolAuditService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _analyticsRefreshService = analyticsRefreshService,
        _ragIndexService = ragIndexService,
        _ragMemoryService = ragMemoryService,
        _gemmaTaskService = gemmaTaskService,
        _toolAuditService = toolAuditService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final AnalyticsRefreshService? _analyticsRefreshService;
  final RagIndexService? _ragIndexService;
  final RagMemoryService? _ragMemoryService;
  final GemmaTaskService? _gemmaTaskService;
  final ToolAuditService? _toolAuditService;
  final DateTime Function() _nowProvider;

  Future<LabLoggingResult> saveCandidates({
    required List<GemmaLabCandidate> candidates,
    int? reviewId,
    String source = 'chat_review',
  }) async {
    final started = _nowProvider();
    final saved = <LabValueRecord>[];
    final ragIndexedByLabId = <int, bool>{};
    final ragStatusByLabId = <int, String>{};
    final ragTransactionIdByLabId = <int, String>{};
    final ragValidatedByLabId = <int, bool>{};
    final ragValidationStatusByLabId = <int, String>{};
    final ragValidationSnippetByLabId = <int, String>{};
    int? auditId;
    Object? auditError;
    try {
      final now = _nowProvider();
      for (final candidate in candidates) {
        final record = candidate.toLabValueRecord(now);
        final id = await _repository.upsertLabValue(record);
        final savedRecord = LabValueRecord(
          id: id,
          drawnDate: record.drawnDate,
          labType: record.labType,
          valueNumeric: record.valueNumeric,
          unit: record.unit,
          referenceHigh: record.referenceHigh,
          labName: record.labName,
          orderingProvider: record.orderingProvider,
          notes: record.notes,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
        );
        saved.add(savedRecord);
        final ragResult = await _indexLabForRag(id, savedRecord);
        ragIndexedByLabId[id] = ragResult.indexed;
        ragStatusByLabId[id] = ragResult.status;
        if (ragResult.transactionId != null) {
          final transactionId = ragResult.transactionId!;
          ragTransactionIdByLabId[id] = transactionId;
          final validation = await _validateRagTransaction(
            transactionId: transactionId,
            record: savedRecord,
          );
          ragValidatedByLabId[id] = validation.validated;
          ragValidationStatusByLabId[id] = validation.status;
          if (validation.snippet != null && validation.snippet!.isNotEmpty) {
            ragValidationSnippetByLabId[id] = validation.snippet!;
          }
        }
      }
      if (reviewId != null) {
        await _gemmaTaskService?.confirmExtractionReview(
          reviewId: reviewId,
          userConfirmedJson: {
            'saved_lab_count': saved.length,
            'lab_ids': saved.map((lab) => lab.id).toList(growable: false),
            'lab_types':
                saved.map((lab) => lab.labType).toList(growable: false),
            'source': source,
          },
        );
      }
      var analyticsStatus = 'not_configured';
      if (_analyticsRefreshService != null && saved.isNotEmpty) {
        try {
          await _analyticsRefreshService.refreshForLabDates(
            drawnDates: saved.map((lab) => lab.drawnDate),
          );
          analyticsStatus = 'refreshed';
        } catch (_) {
          analyticsStatus = 'refresh_failed';
        }
      }
      final updatedRiskScore = await _repository.getLatestFlareRiskScore();
      auditId = await _toolAuditService?.record(
        toolName: 'ingest_lab_panel',
        args: {
          'source': source,
          'candidate_count': candidates.length,
          'review_id': reviewId,
        },
        result: {
          'saved_count': saved.length,
          'lab_ids': saved.map((lab) => lab.id).toList(growable: false),
          'rag_indexed_by_lab_id': _stringKeyedBoolMap(ragIndexedByLabId),
          'rag_status_by_lab_id': _stringKeyedStringMap(ragStatusByLabId),
          'rag_transaction_id_by_lab_id': _stringKeyedStringMap(
            ragTransactionIdByLabId,
          ),
          'rag_validated_by_lab_id': _stringKeyedBoolMap(ragValidatedByLabId),
          'rag_validation_status_by_lab_id': _stringKeyedStringMap(
            ragValidationStatusByLabId,
          ),
          'rag_validation_snippet_by_lab_id': _stringKeyedStringMap(
            ragValidationSnippetByLabId,
          ),
          'analytics_refresh_status': analyticsStatus,
        },
        latencyMs: _nowProvider().difference(started).inMilliseconds,
        modelRole: 'chat_tool_confirmation',
        promptVersion: GemmaTaskService.labPromptVersion,
        validated: true,
      );
      return LabLoggingResult(
        savedLabs: saved,
        ragIndexedByLabId: Map.unmodifiable(ragIndexedByLabId),
        ragStatusByLabId: Map.unmodifiable(ragStatusByLabId),
        ragTransactionIdByLabId: Map.unmodifiable(ragTransactionIdByLabId),
        ragValidatedByLabId: Map.unmodifiable(ragValidatedByLabId),
        ragValidationStatusByLabId: Map.unmodifiable(
          ragValidationStatusByLabId,
        ),
        ragValidationSnippetByLabId: Map.unmodifiable(
          ragValidationSnippetByLabId,
        ),
        updatedRiskScore: updatedRiskScore,
        analyticsRefreshStatus: analyticsStatus,
        reviewId: reviewId,
        toolAuditId: auditId,
      );
    } catch (error) {
      auditError = error;
      rethrow;
    } finally {
      if (auditError != null) {
        await _toolAuditService?.record(
          toolName: 'ingest_lab_panel',
          args: {
            'source': source,
            'candidate_count': candidates.length,
            'review_id': reviewId,
          },
          error: auditError,
          latencyMs: _nowProvider().difference(started).inMilliseconds,
          modelRole: 'chat_tool_confirmation',
          promptVersion: GemmaTaskService.labPromptVersion,
          validated: false,
        );
      }
    }
  }

  Future<_LabRagIndexResult> _indexLabForRag(
      int id, LabValueRecord record) async {
    _LabRagIndexResult? memoryResult;
    final ragMemory = _ragMemoryService;
    if (ragMemory != null) {
      final transactionId = 'lab_tx_$id';
      try {
        final result = await ragMemory.writeAndVerify(
          transactionId: transactionId,
          sourceType: 'lab_value',
          sourceId: '$id',
          text: _labMemoryText(id, record),
          metadata: {
            'drawn_date': record.drawnDate,
            'lab_type': record.labType,
            'source': 'ingest_lab_panel',
          },
        );
        memoryResult = _LabRagIndexResult(
          indexed: result.status == RagMemoryStatus.verified ||
              result.status == RagMemoryStatus.writtenToCorpus,
          status: result.status,
          transactionId: result.transactionId,
        );
      } catch (_) {
        memoryResult = _LabRagIndexResult(
          indexed: false,
          status: RagMemoryStatus.failed,
          transactionId: transactionId,
        );
      }
    }
    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) {
      return memoryResult ??
          const _LabRagIndexResult(indexed: false, status: 'not_configured');
    }
    try {
      final vectorResult = await ragCorpus.indexLabValue(id: id, lab: record);
      return _LabRagIndexResult(
        indexed: (memoryResult?.indexed ?? false) || vectorResult.isSuccess,
        status: memoryResult?.status ?? RagMemoryStatus.writtenToCorpus,
        transactionId: memoryResult?.transactionId,
      );
    } catch (_) {
      return memoryResult ??
          const _LabRagIndexResult(
              indexed: false, status: RagMemoryStatus.failed);
    }
  }

  Future<_LabRagValidationResult> _validateRagTransaction({
    required String transactionId,
    required LabValueRecord record,
  }) async {
    final ragMemory = _ragMemoryService;
    // RagIndexService is write-only; corpus-read verification is handled by
    // RagMemoryService.verifyTransaction. The corpus chunk read path is skipped.

    if (ragMemory == null) {
      return const _LabRagValidationResult(
        validated: false,
        status: 'not_configured',
      );
    }

    var verificationStatus = 'not_checked';
    try {
      final verification = await ragMemory.verifyTransaction(transactionId);
      verificationStatus = verification.status;
    } catch (_) {
      verificationStatus = RagMemoryStatus.failed;
    }

    String? chunkText;
    try {
      chunkText = await ragMemory.readTransactionText(transactionId);
    } catch (_) {
      chunkText = null;
    }

    final status = verificationStatus == 'not_checked'
        ? 'extract_not_found'
        : verificationStatus;
    final validated = verificationStatus == RagMemoryStatus.verified ||
        verificationStatus == RagMemoryStatus.writtenToCorpus ||
        verificationStatus == RagMemoryStatus.loadedInRag;

    return _LabRagValidationResult(
      validated: validated,
      status: status,
      snippet: _validationSnippet(
        chunkText: chunkText,
        transactionId: transactionId,
        record: record,
      ),
    );
  }

  String _labMemoryText(int id, LabValueRecord record) {
    return [
      'Lab id: $id',
      'Drawn date: ${record.drawnDate}',
      'Type: ${record.labType}',
      'Value: ${record.valueNumeric} ${record.unit}',
      if (record.referenceHigh != null)
        'Reference high: ${record.referenceHigh}',
      if ((record.labName ?? '').trim().isNotEmpty)
        'Lab name: ${record.labName}',
      if ((record.orderingProvider ?? '').trim().isNotEmpty)
        'Ordering provider: ${record.orderingProvider}',
      if ((record.notes ?? '').trim().isNotEmpty) 'Notes: ${record.notes}',
    ].join('\n');
  }

  String? _validationSnippet({
    required String? chunkText,
    required String transactionId,
    required LabValueRecord record,
  }) {
    if (chunkText == null || chunkText.isEmpty) return null;
    final lines = chunkText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final valueToken = '${record.valueNumeric} ${record.unit}'.toLowerCase();
    final interesting = lines
        .where((line) {
          final lower = line.toLowerCase();
          return lower.contains(transactionId.toLowerCase()) ||
              lower.contains(record.labType.toLowerCase()) ||
              lower.contains(valueToken);
        })
        .take(3)
        .toList(growable: false);
    if (interesting.isEmpty) return null;
    return interesting.join(' | ');
  }

  Map<String, bool> _stringKeyedBoolMap(Map<int, bool> value) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  Map<String, String> _stringKeyedStringMap(Map<int, String> value) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
}

class _LabRagIndexResult {
  const _LabRagIndexResult({
    required this.indexed,
    required this.status,
    this.transactionId,
  });

  final bool indexed;
  final String status;
  final String? transactionId;
}

class _LabRagValidationResult {
  const _LabRagValidationResult({
    required this.validated,
    required this.status,
    this.snippet,
  });

  final bool validated;
  final String status;
  final String? snippet;
}
