// =============================================================================
// RagIndexService — unified write-side for all RAG data types.
// =============================================================================
// Accepts typed data objects, formats them via RagTextFormatter, embeds via
// EmbeddingService, and stores in VectorStore. Optionally returns a RagWriteResult
// compatible with the existing RagMemoryService tracking contract.
//
// Thread safety: operations are fire-and-forget futures; callers should await
// if they need confirmation. Concurrent calls to different collections are safe.
//
// Production wiring (AppServices):
//   RagIndexService(
//     embedding: LiteRtEmbeddingService(...),
//     store: NativeVectorStore(vectorIndexService),
//   )
//
// Test wiring:
//   RagIndexService(
//     embedding: DeterministicEmbeddingService(),
//     store: InMemoryVectorStore(),
//   )
// =============================================================================

import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show
        SymptomRecord,
        LabValueRecord,
        Pro2SurveyRecord,
        IntakeEventRecord,
        EndoscopyRecord;
import 'package:gemma_flares/core/services/profile_service.dart'
    show UserProfile;
import 'package:gemma_flares/core/services/setup_state_service.dart'
    show SetupStatus;

import 'embedding_service.dart';
import 'food_entry.dart';
import 'rag_store.dart';
import 'rag_text_formatter.dart';

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

enum RagIndexStatus { success, embeddingFailed, storeFailed, skipped }

class RagIndexResult {
  const RagIndexResult({
    required this.chunkId,
    required this.collection,
    required this.status,
    required this.textLength,
    this.error,
  });

  final String chunkId;
  final String collection;
  final RagIndexStatus status;
  final int textLength;
  final Object? error;

  bool get isSuccess => status == RagIndexStatus.success;

  @override
  String toString() =>
      'RagIndexResult(chunk=$chunkId, status=$status, error=$error)';
}

// ---------------------------------------------------------------------------
// RagIndexService
// ---------------------------------------------------------------------------

class RagIndexService {
  RagIndexService({
    required EmbeddingService embedding,
    required VectorStore store,
  })  : _embedding = embedding,
        _store = store;

  final EmbeddingService _embedding;
  final VectorStore _store;

  // ══════════════════════════════════════════════════════════════════════════
  // SYMPTOM
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexSymptom(int id, SymptomRecord s) async {
    final chunkId = RagTextFormatter.symptomChunkId(id);
    final text = RagTextFormatter.formatSymptom(id, s);
    final metadata = RagTextFormatter.symptomMetadata(id, s);
    return _embed(
      collection: RagCollection.symptoms,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: s.loggedAt,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ENDOSCOPY / PROCEDURE RECORD
  // ══════════════════════════════════════════════════════════════════════════

  /// Index a saved endoscopy / procedure record by its database [id].
  /// Signature matches the former [RagCorpusService.indexEndoscopyRecord].
  Future<RagIndexResult> indexEndoscopyRecord({
    required int id,
    required EndoscopyRecord record,
  }) {
    final chunkId = RagTextFormatter.endoscopyChunkId(id);
    final text = RagTextFormatter.formatEndoscopyRecord(id, record);
    final metadata = RagTextFormatter.endoscopyMetadata(id, record);
    DateTime? procedureDt;
    try {
      procedureDt = DateTime.parse(record.procedureDate);
    } catch (_) {}
    return _embed(
      collection: RagCollection.procedures,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: procedureDt ?? DateTime.now().toUtc(),
    );
  }

  /// Index a saved lab value by its database [id].
  /// Signature matches the former [RagCorpusService.indexLabValue].
  Future<RagIndexResult> indexLabValue({
    required int id,
    required LabValueRecord lab,
  }) =>
      indexLabResult(id, lab);

  // ══════════════════════════════════════════════════════════════════════════
  // LAB RESULT
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexLabResult(int id, LabValueRecord r) async {
    final chunkId = RagTextFormatter.labChunkId(id);
    final text = RagTextFormatter.formatLabResult(id, r);
    final metadata = RagTextFormatter.labMetadata(id, r);
    DateTime? drawnDt;
    try {
      drawnDt = DateTime.parse(r.drawnDate);
    } catch (_) {}
    return _embed(
      collection: RagCollection.labs,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: drawnDt ?? DateTime.now().toUtc(),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CHECK-IN SURVEY
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexCheckIn(int id, Pro2SurveyRecord s) async {
    final chunkId = RagTextFormatter.checkinChunkId(id);
    final text = RagTextFormatter.formatCheckIn(id, s);
    final metadata = RagTextFormatter.checkinMetadata(id, s);
    DateTime? surveyDt;
    try {
      surveyDt = DateTime.parse(s.surveyDate);
    } catch (_) {}
    return _embed(
      collection: RagCollection.checkins,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: surveyDt ?? DateTime.now().toUtc(),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MEDICATION / INTAKE EVENT
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexMedication(int id, IntakeEventRecord e) async {
    final chunkId = RagTextFormatter.medicationChunkId(id);
    final text = RagTextFormatter.formatMedication(id, e);
    final metadata = RagTextFormatter.medicationMetadata(id, e);
    return _embed(
      collection: RagCollection.summaries,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: e.loggedAt,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HEALTH SYNC
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexHealthSync({
    required String dateLocal,
    required Map<String, Object?> metrics,
    double? riskScore,
    String? riskBand,
    String? reason,
  }) async {
    final chunkId = RagTextFormatter.healthSyncChunkId(dateLocal);
    final text = RagTextFormatter.formatHealthSync(
      dateLocal: dateLocal,
      metrics: metrics,
      riskScore: riskScore,
      riskBand: riskBand,
      reason: reason,
    );
    final metadata = RagTextFormatter.healthSyncMetadata(
      dateLocal: dateLocal,
      metrics: metrics,
      riskScore: riskScore,
      riskBand: riskBand,
      reason: reason,
    );
    DateTime? dateDt;
    try {
      dateDt = DateTime.parse(dateLocal);
    } catch (_) {}
    return _embed(
      collection: RagCollection.summaries,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: dateDt ?? DateTime.now().toUtc(),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // USER PROFILE
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexProfile(UserProfile p) async {
    const chunkId = RagTextFormatter.profileChunkId;
    final text = RagTextFormatter.formatProfile(p);
    final metadata = RagTextFormatter.profileMetadata(p);
    return _embed(
      collection: RagCollection.profile,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FOOD ENTRY
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexFoodEntry(String id, FoodEntry f) async {
    final chunkId = RagTextFormatter.foodChunkId(id);
    final text = RagTextFormatter.formatFoodEntry(id, f);
    final metadata = RagTextFormatter.foodMetadata(id, f);
    return _embed(
      collection: RagCollection.food,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: f.loggedAt,
    );
  }

  Future<RagIndexResult> indexFoodEntryById(int id, FoodEntry f) =>
      indexFoodEntry(id.toString(), f);

  // ══════════════════════════════════════════════════════════════════════════
  // MODEL INSTALLATION CONFIRMATION
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexModelInstallation({
    required String engineProvider,
    required String modelId,
    required DateTime installedAt,
    required bool validated,
    String? runtimeProfile,
    String? backend,
    Map<String, Object?> extra = const {},
  }) async {
    final chunkId =
        RagTextFormatter.modelInstallChunkId(engineProvider, modelId);
    final text = RagTextFormatter.formatModelInstallation(
      engineProvider: engineProvider,
      modelId: modelId,
      runtimeProfile: runtimeProfile,
      backend: backend,
      installedAt: installedAt,
      validated: validated,
      extra: extra,
    );
    final metadata = RagTextFormatter.modelInstallMetadata(
      engineProvider: engineProvider,
      modelId: modelId,
      installedAt: installedAt,
      validated: validated,
      runtimeProfile: runtimeProfile,
      backend: backend,
    );
    return _embed(
      collection: RagCollection.modelEvents,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
      timestamp: installedAt,
    );
  }

  /// Convenience: index from a SetupStatus object.
  Future<RagIndexResult> indexModelInstallationFromSetup(SetupStatus s) async {
    if (s.modelValidatedAt == null) {
      return const RagIndexResult(
        chunkId: '',
        collection: RagCollection.modelEvents,
        status: RagIndexStatus.skipped,
        textLength: 0,
        error: 'modelValidatedAt is null — model not yet validated',
      );
    }
    return indexModelInstallation(
      engineProvider: 'litert-lm',
      modelId: 'gemma-4-e2b-litert',
      installedAt: s.modelValidatedAt!,
      validated: true,
      runtimeProfile: s.modelRuntimeProfile,
      backend: s.modelBackend,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // STORE DIAGNOSTICS
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns diagnostic stats compatible with the former
  /// [RagCorpusService.getCorpusStats] shape:
  ///   { 'rag_enabled': bool, 'chunk_count': int, 'total_bytes': int,
  ///     'by_collection': string-to-int map }
  Future<Map<String, Object?>> getStoreStats() async {
    final collections = [
      RagCollection.symptoms,
      RagCollection.labs,
      RagCollection.procedures,
      RagCollection.checkins,
      RagCollection.summaries,
      RagCollection.knowledge,
      RagCollection.profile,
      RagCollection.food,
      RagCollection.modelEvents,
      RagCollection.medications,
      RagCollection.healthSync,
      RagCollection.giExports,
      RagCollection.messages,
    ];
    var totalChunks = 0;
    final byCollection = <String, int>{};
    for (final col in collections) {
      try {
        final n = await _store.count(col);
        byCollection[col] = n;
        totalChunks += n;
      } catch (_) {
        byCollection[col] = -1;
      }
    }
    return {
      'rag_enabled': true,
      'chunk_count': totalChunks,
      'total_bytes': 0, // VectorStore does not expose byte size
      'by_collection': byCollection,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RagCorpusService drop-in write wrappers
  // ══════════════════════════════════════════════════════════════════════════
  //
  // These thin wrappers allow write-side services to migrate away from
  // RagCorpusService without changing their call sites.

  Future<RagIndexResult> indexSymptomEvent({
    required int id,
    required DateTime loggedAt,
    required String symptomText,
  }) {
    final chunkId = 'symptom_${_dateKey(loggedAt)}_$id';
    final text =
        'GI symptom event [$id] for ${_dateLabel(loggedAt)}:\n\n$symptomText';
    return indexRawText(
      chunkId: chunkId,
      text: text,
      collection: 'symptoms',
      metadata: {
        'id': id,
        'logged_at': loggedAt.toUtc().toIso8601String(),
      },
    );
  }

  Future<RagIndexResult> indexIntakeEventRaw({
    required int id,
    required IntakeEventRecord event,
  }) {
    final text = [
      'Intake event id: $id',
      'Logged at: ${event.loggedAt.toUtc().toIso8601String()}',
      'Date local: ${event.dateLocal}',
      'Event type: ${event.eventType}',
      'Source: ${event.source}',
      'Confidence: ${event.confidence}',
      if ((event.notes ?? '').trim().isNotEmpty) 'Notes: ${event.notes}',
      if (event.metadataJson.isNotEmpty) 'Metadata: ${event.metadataJson}',
    ].join('\n');
    return indexRawText(
      chunkId: 'med_${event.dateLocal}_${event.eventType}_$id',
      text: 'Medication [$id]:\n\n$text',
      collection: 'medications',
      metadata: {
        'id': id,
        'logged_at': event.loggedAt.toUtc().toIso8601String(),
        'date_local': event.dateLocal,
        'event_type': event.eventType,
      },
    );
  }

  Future<RagIndexResult> indexIntakeEvent({
    required int id,
    required IntakeEventRecord event,
  }) =>
      indexIntakeEventRaw(id: id, event: event);

  Future<RagIndexResult> indexLabText(String labId, String labText) =>
      indexRawText(
        chunkId: 'lab_$labId',
        text: 'Lab result [$labId]:\n\n$labText',
        collection: 'labs',
      );

  Future<RagIndexResult> indexProcedureRecord(
          String recordId, String recordText) =>
      indexRawText(
        chunkId: 'procedure_$recordId',
        text: 'Procedure record [$recordId]:\n\n$recordText',
        collection: 'procedures',
      );

  Future<RagIndexResult> indexGiExport(String exportId, String exportText) =>
      indexRawText(
        chunkId: 'gi_export_$exportId',
        text: 'GI export [$exportId]:\n\n$exportText',
        collection: 'gi_exports',
      );

  Future<RagIndexResult> indexDailySummary(DateTime date, String summaryText) {
    final id = 'daily_${_dateKey(date)}';
    return indexRawText(
      chunkId: id,
      text: 'Daily GI summary for ${_dateLabel(date)}:\n\n$summaryText',
      collection: 'summaries',
      metadata: {'date': _dateLabel(date)},
    );
  }

  Future<RagIndexResult> indexSummary({
    required String level,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String summaryText,
  }) {
    final id = 'summary_${level}_${_dateKey(rangeStart)}_${_dateKey(rangeEnd)}';
    return indexRawText(
      chunkId: id,
      text: 'GutGuard $level memory summary, '
          '${_dateLabel(rangeStart)} through ${_dateLabel(rangeEnd)}:\n\n$summaryText',
      collection: 'summaries',
      metadata: {
        'level': level,
        'range_start': _dateLabel(rangeStart),
        'range_end': _dateLabel(rangeEnd),
      },
    );
  }

  Future<RagIndexResult> indexSymptomBlock(DateTime date, String symptomsText) {
    return indexRawText(
      chunkId: 'symptoms_${_dateKey(date)}',
      text: 'GI symptom log for ${_dateLabel(date)}:\n\n$symptomsText',
      collection: 'symptoms',
      metadata: {'date': _dateLabel(date)},
    );
  }

  // ── Corpus management (clear) ─────────────────────────────────────────────

  /// Clears all chunks from the given [collections], or all collections if null.
  Future<void> clearCorpus({List<String>? collections}) async {
    final cols = collections ?? _store.collections;
    for (final col in cols) {
      await _store.clearCollection(col);
    }
  }

  // ── Date helpers ──────────────────────────────────────────────────────────

  static String _dateKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _dateLabel(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ══════════════════════════════════════════════════════════════════════════
  // RAW TEXT (for arbitrary corpus chunks)
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> indexRawText({
    required String collection,
    required String chunkId,
    required String text,
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  }) =>
      _embed(
        collection: collection,
        chunkId: chunkId,
        text: text,
        metadata: metadata,
        timestamp: timestamp,
      );

  // ══════════════════════════════════════════════════════════════════════════
  // Core embed + store
  // ══════════════════════════════════════════════════════════════════════════

  Future<RagIndexResult> _embed({
    required String collection,
    required String chunkId,
    required String text,
    required Map<String, Object?> metadata,
    DateTime? timestamp,
  }) async {
    if (text.trim().isEmpty) {
      return RagIndexResult(
        chunkId: chunkId,
        collection: collection,
        status: RagIndexStatus.skipped,
        textLength: 0,
        error: 'empty text — nothing to index',
      );
    }

    List<double> vector;
    try {
      vector = await _embedding.embed(text);
    } catch (e) {
      return RagIndexResult(
        chunkId: chunkId,
        collection: collection,
        status: RagIndexStatus.embeddingFailed,
        textLength: text.length,
        error: e,
      );
    }

    try {
      await _store.add(
        collection: collection,
        id: chunkId,
        embedding: vector,
        text: text,
        metadata: metadata,
        timestamp: timestamp ?? DateTime.now().toUtc(),
      );
    } catch (e) {
      return RagIndexResult(
        chunkId: chunkId,
        collection: collection,
        status: RagIndexStatus.storeFailed,
        textLength: text.length,
        error: e,
      );
    }

    return RagIndexResult(
      chunkId: chunkId,
      collection: collection,
      status: RagIndexStatus.success,
      textLength: text.length,
    );
  }
}
