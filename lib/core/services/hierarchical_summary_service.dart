import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/app_database.dart';
import 'gemma_router_service.dart';
import 'rag_corpus_service.dart';
import 'local_model_runtime.dart';
import 'vector_index_service.dart';

typedef SummaryTextGenerator = Future<LocalModelResponse> Function(
  String userMessage, {
  required String taskType,
  required String systemPrompt,
  required Map<String, Object?> groundedContext,
  String? conversationId,
});

typedef SummaryIndexer = Future<void> Function({
  required int rowId,
  required String level,
  required String content,
  required DateTime rangeStart,
  required DateTime rangeEnd,
});

class HierarchicalSummaryRecord {
  const HierarchicalSummaryRecord({
    required this.id,
    required this.level,
    required this.dateRangeStart,
    required this.dateRangeEnd,
    required this.sourceEventIds,
    required this.content,
    required this.promptVersion,
    required this.modelVersion,
    required this.generatedAt,
    required this.needsRegeneration,
  });

  final int id;
  final String level;
  final DateTime dateRangeStart;
  final DateTime dateRangeEnd;
  final Map<String, Object?> sourceEventIds;
  final String content;
  final String? promptVersion;
  final String? modelVersion;
  final DateTime generatedAt;
  final bool needsRegeneration;
}

class HierarchicalSummaryResult {
  const HierarchicalSummaryResult({
    required this.record,
    required this.generated,
    required this.sourceEventCount,
    required this.sourceHash,
  });

  final HierarchicalSummaryRecord record;
  final bool generated;
  final int sourceEventCount;
  final String sourceHash;
}

/// Generates Tier 2 long-term memory summaries over existing local events.
class HierarchicalSummaryService {
  HierarchicalSummaryService({
    required AppDatabase database,
    required GemmaRouterService router,
    required VectorIndexService vectorIndex,
    RagCorpusService? ragCorpus,
    DateTime Function()? nowProvider,
    SummaryTextGenerator? generatorOverride,
    SummaryIndexer? indexerOverride,
  })  : _database = database,
        _ragCorpus = ragCorpus,
        _nowProvider = nowProvider ?? DateTime.now,
        _generator = generatorOverride ??
            ((
              userMessage, {
              required taskType,
              required systemPrompt,
              required groundedContext,
              conversationId,
            }) =>
                router.generateOnce(
                  userMessage,
                  taskType: taskType,
                  systemPrompt: systemPrompt,
                  groundedContext: groundedContext,
                  conversationId: conversationId,
                )),
        _indexer = indexerOverride ??
            (({
              required rowId,
              required level,
              required content,
              required rangeStart,
              required rangeEnd,
            }) =>
                vectorIndex.addToIndex(
                  collection: 'summaries',
                  id: rowId.toString(),
                  text: content,
                  metadata: {
                    'table': 'summaries',
                    'row_id': rowId,
                    'level': level,
                    'timestamp': rangeEnd.toUtc().toIso8601String(),
                    'date_range_start': _dateKey(rangeStart),
                    'date_range_end': _dateKey(rangeEnd),
                  },
                ));

  static const promptVersion = 'hierarchical_summary_v1';
  static const _taskTypes = <String, String>{
    'daily': 'daily_summary',
    'weekly': 'weekly_summary',
    'monthly': 'monthly_summary',
    'quarterly': 'quarterly_summary',
    'yearly': 'yearly_summary',
  };

  final AppDatabase _database;
  final RagCorpusService? _ragCorpus;
  final DateTime Function() _nowProvider;
  final SummaryTextGenerator _generator;
  final SummaryIndexer _indexer;

  Future<HierarchicalSummaryResult?> generateForRange({
    required String level,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    bool forceRegenerate = false,
  }) async {
    final normalizedLevel = level.toLowerCase().trim();
    final taskType = _taskTypes[normalizedLevel];
    if (taskType == null) {
      throw ArgumentError.value(level, 'level', 'Unsupported summary level');
    }

    final sources = await _loadSourceEvents(rangeStart, rangeEnd);
    if (sources.isEmpty) return null;

    final sourceHash = _sourceHash(sources);
    final existing = await loadSummary(
      level: normalizedLevel,
      rangeStart: rangeStart,
    );
    if (!forceRegenerate &&
        existing != null &&
        existing.sourceEventIds['source_hash'] == sourceHash &&
        !existing.needsRegeneration) {
      return HierarchicalSummaryResult(
        record: existing,
        generated: false,
        sourceEventCount: sources.length,
        sourceHash: sourceHash,
      );
    }

    final response = await _generator(
      _summaryInstruction(normalizedLevel, rangeStart, rangeEnd),
      taskType: taskType,
      systemPrompt: _systemPrompt(normalizedLevel),
      groundedContext: {
        'summary_level': normalizedLevel,
        'date_range_start': _dateKey(rangeStart),
        'date_range_end': _dateKey(rangeEnd),
        'source_events': sources,
      },
      conversationId:
          'summary:$normalizedLevel:${_dateKey(rangeStart)}:${_dateKey(rangeEnd)}',
    );
    if (response.status != 'ok' && response.status != 'success') {
      throw StateError(
        'Gemma summary generation failed: ${response.reason ?? response.status}',
      );
    }

    final content = response.outputText.trim();
    if (content.isEmpty) {
      throw StateError('Gemma summary generation returned empty content.');
    }

    final sourceManifest = {
      'source_hash': sourceHash,
      'events': sources
          .map((event) => '${event['table']}:${event['id']}')
          .toList(growable: false),
    };
    final rowId = await _upsertSummary(
      existingId: existing?.id,
      level: normalizedLevel,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      sourceEventIds: sourceManifest,
      content: content,
      modelVersion: response.modelIdUsed,
    );
    await _indexer(
      rowId: rowId,
      level: normalizedLevel,
      content: content,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
    await _indexSummaryForRag(
      level: normalizedLevel,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      content: content,
    );
    final record = await loadSummary(
      level: normalizedLevel,
      rangeStart: rangeStart,
    );
    if (record == null) {
      throw StateError('Summary was written but could not be reloaded.');
    }
    return HierarchicalSummaryResult(
      record: record,
      generated: true,
      sourceEventCount: sources.length,
      sourceHash: sourceHash,
    );
  }

  Future<List<HierarchicalSummaryResult>> generateDueDaily({
    DateTime? throughDate,
    int lookbackDays = 7,
  }) async {
    final end = throughDate ?? _nowProvider();
    final results = <HierarchicalSummaryResult>[];
    for (var offset = lookbackDays - 1; offset >= 0; offset--) {
      final day = DateTime.utc(
        end.year,
        end.month,
        end.day,
      ).subtract(Duration(days: offset));
      final result = await generateForRange(
        level: 'daily',
        rangeStart: day,
        rangeEnd: day,
      );
      if (result != null) results.add(result);
    }
    return results;
  }

  Future<HierarchicalSummaryRecord?> loadSummary({
    required String level,
    required DateTime rangeStart,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'summaries',
      where: 'level = ? AND date_range_start = ?',
      whereArgs: [level.toLowerCase().trim(), _dateKey(rangeStart)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _recordFromRow(rows.single);
  }

  Future<List<HierarchicalSummaryRecord>> latest({int limit = 5}) async {
    final database = await _database.open();
    final rows = await database.query(
      'summaries',
      orderBy: 'date_range_end DESC, generated_at DESC',
      limit: limit,
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _loadSourceEvents(
    DateTime rangeStart,
    DateTime rangeEnd,
  ) async {
    final database = await _database.open();
    final start = _startOfDayUtc(rangeStart).toIso8601String();
    final end = _endOfDayUtc(rangeEnd).toIso8601String();
    final dateStart = _dateKey(rangeStart);
    final dateEnd = _dateKey(rangeEnd);
    final events = <Map<String, Object?>>[];

    final messages = await database.query(
      'messages',
      columns: ['id', 'created_at', 'user_message', 'assistant_message'],
      where: 'created_at >= ? AND created_at <= ?',
      whereArgs: [start, end],
      orderBy: 'created_at ASC',
    );
    for (final row in messages) {
      events.add({
        'table': 'messages',
        'id': row['id'],
        'timestamp': row['created_at'],
        'text':
            'User: ${row['user_message']}\nGemmaFlares: ${row['assistant_message']}',
      });
    }

    final symptoms = await database.query(
      'symptoms',
      columns: ['id', 'logged_at', 'symptom_type', 'severity', 'notes'],
      where: 'logged_at >= ? AND logged_at <= ?',
      whereArgs: [start, end],
      orderBy: 'logged_at ASC',
    );
    for (final row in symptoms) {
      events.add({
        'table': 'symptoms',
        'id': row['id'],
        'timestamp': row['logged_at'],
        'text': [
          'Symptom: ${row['symptom_type']}',
          if (row['severity'] != null) 'severity ${row['severity']}',
          if ((row['notes'] as String?)?.trim().isNotEmpty == true)
            'notes: ${row['notes']}',
        ].join('; '),
      });
    }

    final labs = await database.query(
      'lab_values',
      columns: [
        'id',
        'drawn_date',
        'lab_type',
        'value_numeric',
        'unit',
        'notes',
      ],
      where: 'drawn_date >= ? AND drawn_date <= ?',
      whereArgs: [dateStart, dateEnd],
      orderBy: 'drawn_date ASC',
    );
    for (final row in labs) {
      events.add({
        'table': 'lab_values',
        'id': row['id'],
        'timestamp': row['drawn_date'],
        'text': [
          'Lab: ${row['lab_type']} ${row['value_numeric']} ${row['unit']}',
          if ((row['notes'] as String?)?.trim().isNotEmpty == true)
            'notes: ${row['notes']}',
        ].join('; '),
      });
    }

    final pro2 = await database.query(
      'pro2_surveys',
      columns: [
        'id',
        'survey_date',
        'disease_type',
        'pro2_score',
        'is_flare',
        'notes',
      ],
      where: 'survey_date >= ? AND survey_date <= ?',
      whereArgs: [dateStart, dateEnd],
      orderBy: 'survey_date ASC',
    );
    for (final row in pro2) {
      events.add({
        'table': 'pro2_surveys',
        'id': row['id'],
        'timestamp': row['survey_date'],
        'text': [
          'PRO2 ${row['disease_type']}: score ${row['pro2_score']}',
          if ((row['is_flare'] as num?)?.toInt() == 1) 'flare-labeled',
          if ((row['notes'] as String?)?.trim().isNotEmpty == true)
            'notes: ${row['notes']}',
        ].join('; '),
      });
    }

    // Apple Health daily aggregates: steps, HR, sleep, HRV, SpO2, wrist temp.
    // Rows are keyed by date_local (YYYY-MM-DD); skip rows with no wearable data.
    final dailySummaries = await database.query(
      'daily_summaries',
      columns: ['date_local', 'summary_json'],
      where: 'date_local >= ? AND date_local <= ?',
      whereArgs: [dateStart, dateEnd],
      orderBy: 'date_local ASC',
    );
    for (final row in dailySummaries) {
      final raw = row['summary_json'];
      if (raw == null) continue;
      final Map<String, Object?> json;
      try {
        json = jsonDecode(raw as String) as Map<String, Object?>;
      } catch (_) {
        continue;
      }
      final parts = <String>[];
      final steps = json['step_count_total'];
      if (steps != null) parts.add('steps ${steps.toString()}');
      final hr = json['resting_hr_mean'];
      if (hr != null) {
        parts.add('resting HR ${(hr as num).toStringAsFixed(1)} bpm');
      }
      final sleep = json['sleep_total_minutes'];
      if (sleep != null) {
        final h = (sleep as num).toInt() ~/ 60;
        final m = (sleep).toInt() % 60;
        parts.add('sleep ${h}h${m}m');
      }
      final hrv = json['hrv_sdnn_mean'];
      if (hrv != null) parts.add('HRV ${(hrv as num).toStringAsFixed(1)} ms');
      final spo2 = json['spo2_mean'];
      if (spo2 != null) parts.add('SpO2 ${(spo2 as num).toStringAsFixed(1)}%');
      final temp = json['wrist_temp_mean'];
      if (temp != null) {
        parts.add('wrist temp ${(temp as num).toStringAsFixed(2)}°C');
      }
      if (parts.isEmpty) continue;
      events.add({
        'table': 'daily_summaries',
        'id': row['date_local'],
        'timestamp': '${row['date_local']}T00:00:00.000Z',
        'text': 'Health data ${row['date_local']}: ${parts.join(', ')}',
      });
    }

    // Endoscopy / procedure records in range.
    final endoscopies = await database.query(
      'endoscopy_records',
      columns: [
        'id',
        'procedure_date',
        'procedure_type',
        'mayo_endoscopic_score',
        'ses_cd_score',
        'rutgeerts_score',
        'findings_text',
        'notes',
      ],
      where: 'procedure_date >= ? AND procedure_date <= ?',
      whereArgs: [dateStart, dateEnd],
      orderBy: 'procedure_date ASC',
    );
    for (final row in endoscopies) {
      events.add({
        'table': 'endoscopy_records',
        'id': row['id'],
        'timestamp': '${row['procedure_date']}T00:00:00.000Z',
        'text': [
          'Procedure: ${row['procedure_type']}',
          if (row['mayo_endoscopic_score'] != null)
            'Mayo score ${row['mayo_endoscopic_score']}',
          if (row['ses_cd_score'] != null) 'SES-CD ${row['ses_cd_score']}',
          if (row['rutgeerts_score'] != null)
            'Rutgeerts ${row['rutgeerts_score']}',
          if ((row['findings_text'] as String?)?.trim().isNotEmpty == true)
            'findings: ${row['findings_text']}',
          if ((row['notes'] as String?)?.trim().isNotEmpty == true)
            'notes: ${row['notes']}',
        ].join('; '),
      });
    }

    // Medication / intake events in range.
    final medications = await database.query(
      'intake_events',
      columns: ['id', 'event_type', 'logged_at', 'notes', 'metadata_json'],
      where: 'logged_at >= ? AND logged_at <= ?',
      whereArgs: [start, end],
      orderBy: 'logged_at ASC',
    );
    for (final row in medications) {
      final meta = row['metadata_json'];
      String? medicationName;
      if (meta != null) {
        try {
          final decoded = jsonDecode(meta as String) as Map<String, Object?>;
          medicationName = decoded['medication_name'] as String?;
        } catch (_) {}
      }
      events.add({
        'table': 'intake_events',
        'id': row['id'],
        'timestamp': row['logged_at'],
        'text': [
          'Medication: ${medicationName ?? row['event_type']}',
          if ((row['notes'] as String?)?.trim().isNotEmpty == true)
            'notes: ${row['notes']}',
        ].join('; '),
      });
    }

    events.sort((a, b) => '${a['timestamp']}'.compareTo('${b['timestamp']}'));
    return events;
  }

  Future<int> _upsertSummary({
    required int? existingId,
    required String level,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required Map<String, Object?> sourceEventIds,
    required String content,
    required String modelVersion,
  }) async {
    final database = await _database.open();
    final values = {
      'level': level,
      'date_range_start': _dateKey(rangeStart),
      'date_range_end': _dateKey(rangeEnd),
      'source_event_ids': jsonEncode(sourceEventIds),
      'content': content,
      'embedding_model_version': 'litert_lm_embed_v1',
      'prompt_version': promptVersion,
      'model_version': modelVersion,
      'generated_at': _nowProvider().toUtc().toIso8601String(),
      'needs_regeneration': 0,
    };
    if (existingId != null) {
      await database.update(
        'summaries',
        values,
        where: 'id = ?',
        whereArgs: [existingId],
      );
      return existingId;
    }
    return database.insert('summaries', values);
  }

  HierarchicalSummaryRecord _recordFromRow(Map<String, Object?> row) {
    return HierarchicalSummaryRecord(
      id: (row['id'] as num).toInt(),
      level: row['level'] as String,
      dateRangeStart: DateTime.parse(row['date_range_start'] as String),
      dateRangeEnd: DateTime.parse(row['date_range_end'] as String),
      sourceEventIds:
          jsonDecode(row['source_event_ids'] as String) as Map<String, Object?>,
      content: row['content'] as String,
      promptVersion: row['prompt_version'] as String?,
      modelVersion: row['model_version'] as String?,
      generatedAt: DateTime.parse(row['generated_at'] as String),
      needsRegeneration:
          ((row['needs_regeneration'] as num?)?.toInt() ?? 0) == 1,
    );
  }

  String _summaryInstruction(
    String level,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    return 'Create a concise $level Gemma Flares memory summary for '
        '${_dateKey(rangeStart)} through ${_dateKey(rangeEnd)}. Cover all '
        'available data: Apple Health wearable metrics (steps, HR, sleep, HRV, '
        'SpO2) if present, symptom logs, PRO-2 check-in scores, labs, '
        'medications/intake events, procedures, and any chat context. Skip '
        'categories with no data. Include risk-relevant changes, uncertainty, '
        'and follow-up context. Do not diagnose or recommend medication changes.';
  }

  String _systemPrompt(String level) {
    return 'You are Gemma Flares summarizing local IBD health memory for future '
        'retrieval. Source events include Apple Health wearable data (steps, '
        'resting HR, sleep, HRV, SpO2, wrist temp), symptom logs, PRO-2 '
        'check-ins, lab values, medications, procedures, and chat messages. '
        'Use only provided source events. Write compact clinical-context notes, '
        'not advice. If a category has no data, omit it. Preserve uncertainty. '
        'Output plain text. Level: $level.';
  }

  String _sourceHash(List<Map<String, Object?>> sources) {
    return sha256.convert(utf8.encode(jsonEncode(sources))).toString();
  }

  Future<void> _indexSummaryForRag({
    required String level,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String content,
  }) async {
    final ragCorpus = _ragCorpus;
    if (ragCorpus == null) return;
    try {
      await ragCorpus.indexSummary(
        level: level,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        summaryText: content,
      );
    } catch (_) {
      // RAG corpus writes are best-effort; the SQLite summary remains source
      // of truth and will be re-indexed by later maintenance.
    }
  }

  static DateTime _startOfDayUtc(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  static DateTime _endOfDayUtc(DateTime value) {
    return _startOfDayUtc(
      value,
    ).add(const Duration(days: 1)).subtract(const Duration(microseconds: 1));
  }

  static String _dateKey(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
    ).toIso8601String().substring(0, 10);
  }
}
