// RagCorpusService — manages the on-disk corpus that the native RAG layer indexes.
//
// Architecture
// ============
// The native engine reads the corpus directory once at model load time and builds
// an HNSW vector index in memory (persisted to disk when cache_index=true). Every
// chunk written here will be available to the engine the next time the model is
// loaded.
//
// Corpus layout (mirrors the Swift-side corpusDirectory() helper):
//   <AppSupport>/GutGuard/ModelArtifacts/corpus/<chunkId>.txt
// The on-disk path is runtime-neutral and must stay stable across app upgrades.
//
// Chunk format: plain UTF-8 text, one document per file, ≤8 000 characters
// (~2 000 tokens). Longer payloads are split automatically by this service.
//
// Usage
// =====
// Inject via the service locator and call the index* methods from any feature
// that produces health data (symptom logs, lab results, procedure records,
// daily/weekly summaries, etc.). The corpus is rebuilt implicitly on the next
// model load after the write completes.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/wearable_sample_repository.dart';

/// Maximum chars per corpus chunk (~2 000 tokens at 4 chars/token).
const _kMaxChunkChars = 8000;

class RagCorpusService {
  RagCorpusService({
    Directory? rootDirectory,
    MethodChannel? channel,
  })  : _rootDirectory = rootDirectory,
        _channel = channel;

  final Directory? _rootDirectory;
  final MethodChannel? _channel;

  // ---------------------------------------------------------------------------
  // High-level index helpers
  // ---------------------------------------------------------------------------

  /// Index a daily AI-generated summary.
  Future<void> indexDailySummary(DateTime date, String summaryText) {
    final id = 'daily_${_dateKey(date)}';
    final header = 'Daily GI summary for ${_dateLabel(date)}:\n\n';
    return _writeChunked(id, header + summaryText);
  }

  /// Index a generated hierarchical memory summary.
  Future<void> indexSummary({
    required String level,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String summaryText,
  }) {
    final id = 'summary_${level}_${_dateKey(rangeStart)}_${_dateKey(rangeEnd)}';
    final header = 'Gemma Flares $level memory summary, '
        '${_dateLabel(rangeStart)} through ${_dateLabel(rangeEnd)}:\n\n';
    return _writeChunked(id, header + summaryText);
  }

  /// Index a symptom block (JSON serialised externally; pass as a readable
  /// text blob so the LLM can retrieve it naturally).
  Future<void> indexSymptomBlock(DateTime date, String symptomsText) {
    final id = 'symptoms_${_dateKey(date)}';
    final header = 'GI symptom log for ${_dateLabel(date)}:\n\n';
    return _writeChunked(id, header + symptomsText);
  }

  /// Index a single saved symptom event with a stable unique identifier.
  Future<void> indexSymptomEvent({
    required int id,
    required DateTime loggedAt,
    required String symptomText,
  }) {
    final chunkId = 'symptom_${_dateKey(loggedAt)}_$id';
    final header = 'GI symptom event [$id] for ${_dateLabel(loggedAt)}:\n\n';
    return _writeChunked(chunkId, header + symptomText);
  }

  /// Index a saved lab value with its database identifier.
  Future<void> indexLabValue({required int id, required LabValueRecord lab}) {
    final text = [
      'Lab id: $id',
      'Drawn date: ${lab.drawnDate}',
      'Type: ${lab.labType}',
      'Value: ${lab.valueNumeric} ${lab.unit}',
      if (lab.referenceHigh != null) 'Reference high: ${lab.referenceHigh}',
      if ((lab.labName ?? '').trim().isNotEmpty) 'Lab name: ${lab.labName}',
      if ((lab.orderingProvider ?? '').trim().isNotEmpty)
        'Ordering provider: ${lab.orderingProvider}',
      if ((lab.notes ?? '').trim().isNotEmpty) 'Notes: ${lab.notes}',
    ].join('\n');
    return indexLabResult('${lab.drawnDate}_${lab.labType}_$id', text);
  }

  /// Index a saved procedure/endoscopy record with its database identifier.
  Future<void> indexEndoscopyRecord({
    required int id,
    required EndoscopyRecord record,
  }) {
    final text = [
      'Procedure id: $id',
      'Procedure date: ${record.procedureDate}',
      'Procedure type: ${record.procedureType}',
      if (record.mayoEndoscopicScore != null)
        'Mayo endoscopic score: ${record.mayoEndoscopicScore}',
      if (record.sesCdScore != null) 'SES-CD score: ${record.sesCdScore}',
      if ((record.rutgeertsScore ?? '').trim().isNotEmpty)
        'Rutgeerts score: ${record.rutgeertsScore}',
      if ((record.findingsText ?? '').trim().isNotEmpty)
        'Findings: ${record.findingsText}',
      'Biopsies taken: ${record.biopsiesTaken}',
      if ((record.biopsyResult ?? '').trim().isNotEmpty)
        'Biopsy result: ${record.biopsyResult}',
      if ((record.provider ?? '').trim().isNotEmpty)
        'Provider: ${record.provider}',
      if ((record.notes ?? '').trim().isNotEmpty) 'Notes: ${record.notes}',
    ].join('\n');
    return indexProcedureRecord(
      '${record.procedureDate}_${record.procedureType}_$id',
      text,
    );
  }

  /// Index a saved intake/medication context event with its database id.
  Future<void> indexIntakeEvent({
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
    return indexMedication('${event.dateLocal}_${event.eventType}_$id', text);
  }

  /// Index a lab result entry.
  Future<void> indexLabResult(String labId, String labText) {
    return _writeChunked('lab_$labId', 'Lab result [$labId]:\n\n$labText');
  }

  /// Index a procedure or clinical record.
  Future<void> indexProcedureRecord(String recordId, String recordText) {
    return _writeChunked(
      'procedure_$recordId',
      'Procedure record [$recordId]:\n\n$recordText',
    );
  }

  /// Index a medication or treatment entry.
  Future<void> indexMedication(String medId, String medText) {
    return _writeChunked('med_$medId', 'Medication [$medId]:\n\n$medText');
  }

  /// Index a GI export summary document.
  Future<void> indexGiExport(String exportId, String exportText) {
    return _writeChunked(
      'gi_export_$exportId',
      'GI export [$exportId]:\n\n$exportText',
    );
  }

  // ---------------------------------------------------------------------------
  // Retrieval (ad-hoc, outside of normal generation flow)
  // ---------------------------------------------------------------------------

  /// Retrieve the top-k most relevant corpus chunks for [query].
  /// Returns a list of chunk texts. Throws if the model isn't loaded or RAG
  /// isn't enabled.
  Future<List<String>> ragQuery(String query, {int topK = 3}) async {
    final channel = _channel;
    if (channel != null) {
      final result = await channel.invokeMethod<List<dynamic>>('ragQuery', {
        'query': query,
        'topK': topK,
      });
      return (result ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false);
    }

    final queryTerms = _terms(query);
    if (queryTerms.isEmpty || topK <= 0) return const [];
    final scored = <({String text, double score})>[];
    for (final chunk in await listCorpusChunks()) {
      final id = chunk['chunk_id']?.toString() ?? '';
      final text = await readCorpusChunk(id);
      if (text == null) continue;
      final score = _lexicalScore(queryTerms, text);
      if (score > 0) scored.add((text: text, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).map((item) => item.text).toList(growable: false);
  }

  /// Returns diagnostic info about the corpus (chunk count, bytes, RAG state).
  Future<Map<String, dynamic>> getCorpusStats() async {
    final channel = _channel;
    if (channel != null) {
      final result =
          await channel.invokeMethod<Map<dynamic, dynamic>>('getCorpusStats');
      return Map<String, dynamic>.from(result ?? const {});
    }

    final chunks = await listCorpusChunks();
    var bytes = 0;
    for (final chunk in chunks) {
      bytes += (chunk['bytes'] as int?) ?? 0;
    }
    return {
      'rag_enabled': chunks.isNotEmpty,
      'chunk_count': chunks.length,
      'total_bytes': bytes,
      'storage': 'filesystem',
      'root': (await _root()).path,
    };
  }

  Future<List<Map<String, dynamic>>> listCorpusChunks() async {
    final channel = _channel;
    if (channel != null) {
      final result =
          await channel.invokeMethod<List<dynamic>>('listCorpusChunks');
      return (result ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }

    final root = await _root();
    if (!await root.exists()) return const [];
    final chunks = <Map<String, dynamic>>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.txt') continue;
      final stat = await entity.stat();
      chunks.add({
        'chunk_id': _chunkIdFromFile(entity),
        'bytes': stat.size,
        'updated_at': stat.modified.toUtc().toIso8601String(),
      });
    }
    chunks.sort(
        (a, b) => a['chunk_id'].toString().compareTo(b['chunk_id'].toString()));
    return chunks;
  }

  Future<String?> readCorpusChunk(String chunkId) async {
    final channel = _channel;
    if (channel != null) {
      final result = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'readCorpusChunk',
        {'chunkId': chunkId},
      );
      if (result == null || result['ok'] != true) return null;
      return result['text']?.toString();
    }

    final file = await _chunkFile(chunkId, createDir: false);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<String?> readChunkedForVerification(String baseId) async {
    final single = await readCorpusChunk(baseId);
    if (single != null) return single;

    final buffer = StringBuffer();
    var foundAny = false;
    for (var index = 1; index <= 512; index++) {
      final chunk = await readCorpusChunk('${baseId}_p$index');
      if (chunk == null) break;
      foundAny = true;
      buffer.write(chunk);
    }
    return foundAny ? buffer.toString() : null;
  }

  Future<bool> deleteCorpusChunk(String chunkId) async {
    final channel = _channel;
    if (channel != null) {
      return await channel.invokeMethod<bool>(
            'deleteCorpusChunk',
            {'chunkId': chunkId},
          ) ??
          false;
    }

    final file = await _chunkFile(chunkId, createDir: false);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  Future<bool> deleteAllCorpusChunks() async {
    final channel = _channel;
    if (channel != null) {
      return await channel.invokeMethod<bool>('deleteAllCorpusChunks') ?? false;
    }

    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
    return true;
  }

  Future<bool> ragContainsTransaction(
    String transactionId, {
    int topK = 5,
  }) async {
    final channel = _channel;
    if (channel != null) {
      final result = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'ragContainsTransaction',
        {'transactionId': transactionId, 'topK': topK},
      );
      return result?['contains'] == true;
    }

    final chunks = await ragQuery(transactionId, topK: topK);
    return chunks.any((chunk) => chunk.contains(transactionId));
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Splits [text] into ≤[_kMaxChunkChars] pieces and writes each to disk.
  Future<List<String>> writeChunkedForVerification(
    String baseId,
    String text,
  ) async {
    final chunks = _split(text);
    final ids = <String>[];
    for (int i = 0; i < chunks.length; i++) {
      final id = chunks.length == 1 ? baseId : '${baseId}_p${i + 1}';
      await _writeChunk(id, chunks[i]);
      ids.add(id);
    }
    return ids;
  }

  Future<void> _writeChunked(String baseId, String text) async {
    await writeChunkedForVerification(baseId, text);
  }

  /// Writes a single corpus chunk to app-local storage.
  Future<void> _writeChunk(String chunkId, String text) async {
    final channel = _channel;
    if (channel != null) {
      await channel.invokeMethod<void>('writeCorpusChunk', {
        'chunkId': chunkId,
        'text': text,
      });
      return;
    }

    final file = await _chunkFile(chunkId, createDir: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  /// Splits [text] on sentence/paragraph boundaries at ≤[_kMaxChunkChars].
  static List<String> _split(String text) {
    if (text.length <= _kMaxChunkChars) return [text];
    final result = <String>[];
    int start = 0;
    while (start < text.length) {
      int end = start + _kMaxChunkChars;
      if (end >= text.length) {
        result.add(text.substring(start));
        break;
      }
      // Try to break on a newline or period to avoid cutting mid-sentence.
      int breakAt = -1;
      for (final sep in ['\n\n', '\n', '. ', ' ']) {
        final idx = text.lastIndexOf(sep, end);
        if (idx > start) {
          breakAt = idx + sep.length;
          break;
        }
      }
      if (breakAt <= start) breakAt = end; // Hard break as last resort.
      result.add(text.substring(start, breakAt));
      start = breakAt;
    }
    return result;
  }

  static String _dateKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _dateLabel(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<Directory> _root() async {
    final configured = _rootDirectory;
    if (configured != null) {
      await configured.create(recursive: true);
      return configured;
    }
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'GutGuard', 'RagCorpus', 'v1'));
    await root.create(recursive: true);
    return root;
  }

  Future<File> _chunkFile(String chunkId, {required bool createDir}) async {
    _validateChunkId(chunkId);
    final root = await _root();
    if (createDir) await root.create(recursive: true);
    return File(p.join(root.path, '${_safeChunkId(chunkId)}.txt'));
  }

  static String _chunkIdFromFile(File file) {
    final raw = p.basenameWithoutExtension(file.path);
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  static String _safeChunkId(String chunkId) =>
      Uri.encodeComponent(chunkId.trim());

  static void _validateChunkId(String chunkId) {
    if (chunkId.trim().isEmpty) {
      throw ArgumentError.value(chunkId, 'chunkId', 'must not be empty');
    }
    if (chunkId.contains('/') || chunkId.contains('\\')) {
      throw ArgumentError.value(
        chunkId,
        'chunkId',
        'must not contain path separators',
      );
    }
  }

  static Set<String> _terms(String value) => value
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9_:-]+'))
      .where((term) => term.length >= 2)
      .toSet();

  static double _lexicalScore(Set<String> queryTerms, String text) {
    final lower = text.toLowerCase();
    final textTerms = _terms(lower);
    if (textTerms.isEmpty) return 0;
    final hits = queryTerms.intersection(textTerms).length;
    if (hits == 0) return 0;
    final exactBoost = queryTerms.any(lower.contains) ? 1.0 : 0.0;
    return hits / queryTerms.length + exactBoost;
  }
}
