import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';
import 'rag_corpus_service.dart';
import 'local_model_runtime.dart';

class RagMemoryStatus {
  static const pending = 'pending';
  static const writtenToCorpus = 'written_to_corpus';
  static const loadedInRag = 'loaded_in_rag';
  static const verified = 'verified';
  static const failed = 'failed';
  static const deleted = 'deleted';
}

class RagWriteResult {
  const RagWriteResult({
    required this.transactionId,
    required this.chunkId,
    required this.status,
    required this.verified,
    this.message,
  });

  final String transactionId;
  final String chunkId;
  final String status;
  final bool verified;
  final String? message;
}

class RagVerificationResult {
  const RagVerificationResult({
    required this.transactionId,
    required this.status,
    required this.verified,
    required this.corpusFileVerified,
    required this.queryVerified,
    this.message,
  });

  final String transactionId;
  final String status;
  final bool verified;
  final bool corpusFileVerified;
  final bool queryVerified;
  final String? message;
}

class RagExportBundle {
  const RagExportBundle({required this.payload});

  final Map<String, Object?> payload;

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(payload);
}

class RagMemoryService {
  RagMemoryService({
    required WearableSampleRepository repository,
    required RagCorpusService corpusService,
    required LocalModelRuntime runtime,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _corpusService = corpusService,
        _runtime = runtime,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  // Fixed idempotent transaction IDs for setup anchors.
  // Using upsertRagMemoryTransaction means these are never duplicated, even if
  // the user re-runs setup or the wizard reopens for model repair.
  static const setupProfileTransactionId = 'setup_profile_v1';
  static const setupHealthTransactionId = 'setup_health_v1';

  final WearableSampleRepository _repository;
  final RagCorpusService _corpusService;
  final LocalModelRuntime _runtime;
  final DateTime Function() _nowProvider;

  Future<RagWriteResult> writeAndVerify({
    required String transactionId,
    required String sourceType,
    required String sourceId,
    required String text,
    Map<String, Object?> metadata = const {},
  }) async {
    final now = _nowProvider().toUtc();
    final chunkId = _sanitizeChunkId(transactionId);
    final body = _formatChunk(
      transactionId: transactionId,
      sourceType: sourceType,
      sourceId: sourceId,
      text: text,
      metadata: metadata,
    );
    final textHash = _hash(body);
    await _repository.upsertRagMemoryTransaction(
      RagMemoryTransactionRecord(
        transactionId: transactionId,
        sourceType: sourceType,
        sourceId: sourceId,
        chunkId: chunkId,
        status: RagMemoryStatus.pending,
        textHash: textHash,
        createdAt: now,
      ),
    );

    try {
      await _corpusService.writeChunkedForVerification(chunkId, body);
      await _repository.updateRagMemoryTransactionStatus(
        transactionId: transactionId,
        status: RagMemoryStatus.writtenToCorpus,
        indexedAt: _nowProvider().toUtc(),
      );
      final verification = await verifyTransaction(transactionId);
      return RagWriteResult(
        transactionId: transactionId,
        chunkId: chunkId,
        status: verification.status,
        verified: verification.verified,
        message: verification.message,
      );
    } catch (error) {
      await _repository.updateRagMemoryTransactionStatus(
        transactionId: transactionId,
        status: RagMemoryStatus.failed,
        lastError: error.toString(),
        incrementRetry: true,
      );
      return RagWriteResult(
        transactionId: transactionId,
        chunkId: chunkId,
        status: RagMemoryStatus.failed,
        verified: false,
        message: error.toString(),
      );
    }
  }

  Future<RagVerificationResult> verifyTransaction(String transactionId) async {
    final record = await _repository.getRagMemoryTransaction(transactionId);
    if (record == null) {
      return RagVerificationResult(
        transactionId: transactionId,
        status: RagMemoryStatus.failed,
        verified: false,
        corpusFileVerified: false,
        queryVerified: false,
        message: 'transaction_not_found',
      );
    }

    final text = await _corpusService.readChunkedForVerification(
      record.chunkId,
    );
    final corpusFileVerified = text != null &&
        text.contains(transactionId) &&
        _hash(text) == record.textHash;

    var queryVerified = false;
    var ragEnabled = false;
    try {
      final runtimeStatus = await _runtime.getRuntimeStatus();
      final stats = await _corpusService.getCorpusStats();
      ragEnabled = stats['rag_enabled'] == true && runtimeStatus.isModelLoaded;
      if (ragEnabled) {
        queryVerified = await _corpusService.ragContainsTransaction(
          transactionId,
        );
      }
    } catch (_) {
      queryVerified = false;
    }

    final status = queryVerified
        ? RagMemoryStatus.verified
        : corpusFileVerified
            ? RagMemoryStatus.writtenToCorpus
            : RagMemoryStatus.failed;
    await _repository.updateRagMemoryTransactionStatus(
      transactionId: transactionId,
      status: status,
      verifiedAt: queryVerified ? _nowProvider().toUtc() : null,
      lastError: status == RagMemoryStatus.failed
          ? 'corpus_file_missing_or_hash_mismatch'
          : null,
    );

    return RagVerificationResult(
      transactionId: transactionId,
      status: status,
      verified: queryVerified,
      corpusFileVerified: corpusFileVerified,
      queryVerified: queryVerified,
      message: queryVerified
          ? 'verified_in_rag'
          : corpusFileVerified
              ? 'written_to_corpus_reload_required'
              : 'corpus_verification_failed',
    );
  }

  Future<String?> readTransactionText(String transactionId) async {
    final record = await _repository.getRagMemoryTransaction(transactionId);
    if (record == null) return null;
    return _corpusService.readChunkedForVerification(record.chunkId);
  }

  Future<RagExportBundle> exportRagContents() async {
    final transactions = await _repository.getRagMemoryTransactions();
    final chunks = await _corpusService.listCorpusChunks();
    final stats = await _corpusService.getCorpusStats();
    final previews = <Map<String, Object?>>[];
    for (final chunk in chunks.take(200)) {
      final id = chunk['chunk_id']?.toString() ?? '';
      final text = await _corpusService.readCorpusChunk(id) ?? '';
      previews.add({
        ...chunk,
        'preview': text.length <= 240 ? text : '${text.substring(0, 240)}...',
      });
    }
    return RagExportBundle(
      payload: {
        'exported_at': _nowProvider().toUtc().toIso8601String(),
        'privacy_note':
            'Local export. May include sensitive health context saved for retrieval.',
        'corpus_stats': stats,
        'transactions': transactions.map(_transactionToJson).toList(),
        'chunks': previews,
      },
    );
  }

  Future<void> deleteAllRagContents() async {
    await _corpusService.deleteAllCorpusChunks();
    await _repository.markAllRagMemoryTransactionsDeleted();
  }

  Future<void> retryPending() async {
    final rows = await _repository.getRagMemoryTransactions(
      statuses: const [RagMemoryStatus.pending, RagMemoryStatus.failed],
    );
    for (final row in rows) {
      await verifyTransaction(row.transactionId);
    }
  }

  /// Write (or overwrite) a flare-risk snapshot to the RAG corpus so Gemma
  /// can retrieve it during grounding.  Each call upserts a single dated chunk
  /// keyed by `flare_risk_tx_<dateLocal>` — idempotent across re-computes on
  /// the same calendar day.
  ///
  /// [record] is the latest persisted [FlareRiskScoreRecord].
  /// [dateLocal] is the ISO 8601 local-date string (e.g. "2026-05-08").
  Future<RagWriteResult> writeFlareRisk({
    required FlareRiskScoreRecord record,
    required String dateLocal,
  }) {
    // riskScore is stored 0–100 by risk_engine_service; convert back to 0–1
    // for the human-readable text so percentages look right (e.g. "39%").
    final pct = record.riskScore.clamp(0.0, 100.0).round();
    final featureJson = record.featureSnapshotJson;

    double? horizonPct(String key) {
      final v = featureJson[key];
      if (v == null) return null;
      final d = (v as num?)?.toDouble();
      return d == null ? null : (d.clamp(0.0, 1.0) * 100);
    }

    final p7 = horizonPct('logistic_p_flare_7d');
    final p14 = horizonPct('logistic_p_flare_14d');
    final p21 = horizonPct('logistic_p_flare_21d');

    final horizonLines = [
      if (p7 != null) '  • 7-day flare probability: ${p7.round()}%',
      if (p14 != null) '  • 14-day flare probability: ${p14.round()}%',
      if (p21 != null) '  • 21-day flare probability: ${p21.round()}%',
    ].join('\n');

    final text = [
      'Gemma Flares flare risk score for $dateLocal:',
      '  Current risk: $pct% (band: ${record.riskBand})',
      if (horizonLines.isNotEmpty) 'Horizon outlook:\n$horizonLines',
      'Model: ${record.modelVersion}',
      'Data confidence: ${record.confidenceScore.round()}/100',
      'Computed at: ${record.createdAt.toUtc().toIso8601String()}',
    ].join('\n');

    return writeAndVerify(
      transactionId: 'flare_risk_tx_$dateLocal',
      sourceType: 'flare_risk_score',
      sourceId: dateLocal,
      text: text,
      metadata: {
        'date_local': dateLocal,
        'risk_score_pct': pct,
        'risk_band': record.riskBand,
        'confidence_score': record.confidenceScore,
        'model_version': record.modelVersion,
        'horizon_7d_pct': p7?.round(),
        'horizon_14d_pct': p14?.round(),
        'horizon_21d_pct': p21?.round(),
        'computed_at': record.createdAt.toUtc().toIso8601String(),
      },
    );
  }

  Future<RagVerificationResult> runSelfTest() async {
    final id = 'rag_selftest_${_nowProvider().microsecondsSinceEpoch}';
    final result = await writeAndVerify(
      transactionId: id,
      sourceType: 'self_test',
      sourceId: id,
      text: 'Gemma Flares RAG self-test transaction $id.',
    );
    return RagVerificationResult(
      transactionId: id,
      status: result.status,
      verified: result.verified,
      corpusFileVerified: result.status == RagMemoryStatus.writtenToCorpus ||
          result.status == RagMemoryStatus.verified,
      queryVerified: result.verified,
      message: result.message,
    );
  }

  Map<String, Object?> _transactionToJson(RagMemoryTransactionRecord row) {
    return {
      'transaction_id': row.transactionId,
      'source_type': row.sourceType,
      'source_id': row.sourceId,
      'chunk_id': row.chunkId,
      'status': row.status,
      'text_hash': row.textHash,
      'created_at': row.createdAt.toUtc().toIso8601String(),
      'indexed_at': row.indexedAt?.toUtc().toIso8601String(),
      'verified_at': row.verifiedAt?.toUtc().toIso8601String(),
      'retry_count': row.retryCount,
      'last_error': row.lastError,
    };
  }

  String _formatChunk({
    required String transactionId,
    required String sourceType,
    required String sourceId,
    required String text,
    required Map<String, Object?> metadata,
  }) {
    return [
      'Gemma Flares memory transaction: $transactionId',
      'Source type: $sourceType',
      'Source id: $sourceId',
      if (metadata.isNotEmpty) 'Metadata: ${jsonEncode(metadata)}',
      '',
      text.trim(),
    ].join('\n');
  }

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  String _sanitizeChunkId(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9\-_]'), '_');
  }
}
