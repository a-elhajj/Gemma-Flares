import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/hierarchical_summary_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/vector_index_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_summary_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
  });

  tearDown(() async {
    await database.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('generates and indexes a daily summary from local events', () async {
    await _insertConversation(
      database,
      createdAt: DateTime.parse('2026-05-04T14:00:00Z'),
      user: 'I used the bathroom six times today.',
      assistant: 'I logged increased stool frequency.',
    );
    await _insertSymptom(
      database,
      loggedAt: DateTime.parse('2026-05-04T15:00:00Z'),
      symptomType: 'abdominal_pain',
      severity: 3,
      notes: 'Cramping after lunch.',
    );

    final indexed = <Map<String, Object?>>[];
    final service = _service(
      database,
      generatedText: 'Daily summary: stool frequency increased with cramping.',
      indexed: indexed,
    );

    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNotNull);
    expect(result!.generated, isTrue);
    expect(result.sourceEventCount, 2);
    expect(result.record.level, 'daily');
    expect(result.record.content, contains('stool frequency'));
    expect(
      result.record.promptVersion,
      HierarchicalSummaryService.promptVersion,
    );
    expect(result.record.sourceEventIds['events'], hasLength(2));
    expect(indexed.single['collection'], 'summaries');
    expect(indexed.single['id'], result.record.id.toString());
  });

  test('skips regeneration when the source hash is unchanged', () async {
    await _insertConversation(
      database,
      createdAt: DateTime.parse('2026-05-04T14:00:00Z'),
      user: 'Gut feels okay today.',
      assistant: 'I saved that check-in.',
    );

    var generateCalls = 0;
    final service = _service(
      database,
      generatedText: 'Daily summary: stable gut symptoms.',
      onGenerate: () => generateCalls++,
    );

    final first = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );
    final second = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(first!.generated, isTrue);
    expect(second!.generated, isFalse);
    expect(second.record.id, first.record.id);
    expect(generateCalls, 1);
  });

  test('regenerates an existing summary when source events change', () async {
    await _insertConversation(
      database,
      createdAt: DateTime.parse('2026-05-04T14:00:00Z'),
      user: 'Gut feels okay today.',
      assistant: 'I saved that check-in.',
    );

    var generateCalls = 0;
    final service = _service(
      database,
      generatedText: () => generateCalls == 0
          ? 'Daily summary: stable gut symptoms.'
          : 'Daily summary: later cramping changed the day.',
      onGenerate: () => generateCalls++,
    );

    final first = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );
    await _insertSymptom(
      database,
      loggedAt: DateTime.parse('2026-05-04T20:00:00Z'),
      symptomType: 'cramping',
      severity: 2,
      notes: 'Evening flare-up feeling.',
    );
    final second = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(second!.generated, isTrue);
    expect(second.record.id, first!.record.id);
    expect(second.record.content, contains('later cramping'));
    expect(second.sourceHash, isNot(first.sourceHash));
    expect(generateCalls, 2);
  });

  test('returns null when a range has no source events', () async {
    final service = _service(database, generatedText: 'unused');

    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNull);
  });

  test('throws when Gemma summary generation fails', () async {
    await _insertConversation(
      database,
      createdAt: DateTime.parse('2026-05-04T14:00:00Z'),
      user: 'Gut feels rough.',
      assistant: 'I saved that check-in.',
    );
    final service = _service(
      database,
      generatedText: 'unused',
      status: 'unavailable',
      reason: 'memory_pressure_too_high',
    );

    expect(
      () => service.generateForRange(
        level: 'daily',
        rangeStart: DateTime.utc(2026, 5, 4),
        rangeEnd: DateTime.utc(2026, 5, 4),
      ),
      throwsStateError,
    );
  });

  // ── New data sources ──────────────────────────────────────────────────────

  test('includes Apple Health daily wearable data in source events', () async {
    await _insertDailySummary(
      database,
      dateLocal: '2026-05-04',
      stepCount: 7200,
      restingHrMean: 62.5,
      sleepTotalMinutes: 430,
      hrvSdnnMean: 48.3,
    );

    final captured = <Map<String, Object?>>[];
    final service = _service(
      database,
      generatedText: 'Daily summary: 7200 steps, HR 62.5, sleep 7h10m.',
      capturedContext: captured,
    );

    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNotNull);
    expect(result!.sourceEventCount, 1);
    final text = captured.single['source_events'] as List;
    final healthEvent = (text).firstWhere(
      (e) => '${e['table']}' == 'daily_summaries',
    );
    expect(healthEvent['text'], contains('steps 7200'));
    expect(healthEvent['text'], contains('62.5 bpm'));
    expect(healthEvent['text'], contains('7h10m'));
    expect(healthEvent['text'], contains('48.3 ms'));
  });

  test('skips daily wearable row when summary_json is unparseable', () async {
    final db = await database.open();
    await db.insert('daily_summaries', {
      'date_local': '2026-05-04',
      'summary_json': 'not-valid-json',
      'sync_quality_score': 0.0,
      'recomputed_at': '2026-05-04T06:00:00.000Z',
    });

    final service = _service(database, generatedText: 'unused');
    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    // Corrupt JSON row is silently skipped; no other events → null result.
    expect(result, isNull);
  });

  test('skips daily wearable row when all metrics are null', () async {
    await _insertDailySummary(
      database,
      dateLocal: '2026-05-04',
      stepCount: null,
      restingHrMean: null,
      sleepTotalMinutes: null,
      hrvSdnnMean: null,
    );

    final service = _service(database, generatedText: 'unused');
    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNull);
  });

  test('includes endoscopy record in source events', () async {
    await _insertEndoscopy(
      database,
      procedureDate: '2026-05-04',
      procedureType: 'colonoscopy',
      mayoScore: 2,
      findings: 'Mild inflammation in sigmoid colon.',
    );

    final captured = <Map<String, Object?>>[];
    final service = _service(
      database,
      generatedText: 'Daily summary: colonoscopy — mild inflammation.',
      capturedContext: captured,
    );

    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNotNull);
    final text = (captured.single['source_events'] as List).firstWhere(
      (e) => '${e['table']}' == 'endoscopy_records',
    );
    expect(text['text'], contains('colonoscopy'));
    expect(text['text'], contains('Mayo score 2'));
    expect(text['text'], contains('sigmoid colon'));
  });

  test('includes medication intake event in source events', () async {
    await _insertIntakeEvent(
      database,
      loggedAt: DateTime.parse('2026-05-04T08:00:00Z'),
      eventType: 'medication_taken',
      medicationName: 'Humira',
      notes: '40 mg subcutaneous injection.',
    );

    final captured = <Map<String, Object?>>[];
    final service = _service(
      database,
      generatedText: 'Daily summary: Humira administered.',
      capturedContext: captured,
    );

    final result = await service.generateForRange(
      level: 'daily',
      rangeStart: DateTime.utc(2026, 5, 4),
      rangeEnd: DateTime.utc(2026, 5, 4),
    );

    expect(result, isNotNull);
    final text = (captured.single['source_events'] as List).firstWhere(
      (e) => '${e['table']}' == 'intake_events',
    );
    expect(text['text'], contains('Humira'));
    expect(text['text'], contains('40 mg subcutaneous'));
  });

  test(
    'medication event falls back to event_type when metadata has no name',
    () async {
      await _insertIntakeEvent(
        database,
        loggedAt: DateTime.parse('2026-05-04T08:00:00Z'),
        eventType: 'medication_taken',
        medicationName: null,
        notes: null,
      );

      final captured = <Map<String, Object?>>[];
      final service = _service(
        database,
        generatedText: 'Daily summary: medication logged.',
        capturedContext: captured,
      );

      await service.generateForRange(
        level: 'daily',
        rangeStart: DateTime.utc(2026, 5, 4),
        rangeEnd: DateTime.utc(2026, 5, 4),
      );

      final text = (captured.single['source_events'] as List).firstWhere(
        (e) => '${e['table']}' == 'intake_events',
      );
      expect(text['text'], contains('medication_taken'));
    },
  );

  test(
    'all five source types appear together in a single daily summary',
    () async {
      final day = DateTime.utc(2026, 5, 4);
      await _insertConversation(
        database,
        createdAt: DateTime.parse('2026-05-04T09:00:00Z'),
        user: 'Feeling rough.',
        assistant: 'Logged.',
      );
      await _insertSymptom(
        database,
        loggedAt: DateTime.parse('2026-05-04T10:00:00Z'),
        symptomType: 'abdominal_pain',
        severity: 2,
        notes: 'Mild cramping.',
      );
      await _insertDailySummary(
        database,
        dateLocal: '2026-05-04',
        stepCount: 4000,
        restingHrMean: 70.0,
        sleepTotalMinutes: 360,
        hrvSdnnMean: null,
      );
      await _insertEndoscopy(
        database,
        procedureDate: '2026-05-04',
        procedureType: 'flexible_sigmoidoscopy',
        mayoScore: 1,
        findings: null,
      );
      await _insertIntakeEvent(
        database,
        loggedAt: DateTime.parse('2026-05-04T08:00:00Z'),
        eventType: 'medication_taken',
        medicationName: 'Mesalamine',
        notes: null,
      );

      final captured = <Map<String, Object?>>[];
      final service = _service(
        database,
        generatedText: 'Full daily summary.',
        capturedContext: captured,
      );

      final result = await service.generateForRange(
        level: 'daily',
        rangeStart: day,
        rangeEnd: day,
      );

      expect(result, isNotNull);
      final tables = (captured.single['source_events'] as List)
          .map((e) => e['table'] as String)
          .toSet();
      expect(
        tables,
        containsAll([
          'messages',
          'symptoms',
          'daily_summaries',
          'endoscopy_records',
          'intake_events',
        ]),
      );
    },
  );
}

HierarchicalSummaryService _service(
  AppDatabase database, {
  required Object generatedText,
  List<Map<String, Object?>>? indexed,
  List<Map<String, Object?>>? capturedContext,
  void Function()? onGenerate,
  String status = 'ok',
  String? reason,
}) {
  return HierarchicalSummaryService(
    database: database,
    router: GemmaRouterService(runtime: const UnavailableGemmaRuntime()),
    vectorIndex: VectorIndexService(),
    nowProvider: () => DateTime.parse('2026-05-05T12:00:00Z'),
    generatorOverride: (
      userMessage, {
      required taskType,
      required systemPrompt,
      required groundedContext,
      conversationId,
    }) async {
      final text = generatedText is String
          ? generatedText
          : (generatedText as String Function())();
      onGenerate?.call();
      capturedContext?.add(groundedContext);
      return LocalModelResponse(
        status: status,
        outputText: text,
        runtimeName: 'fake-gemma',
        reason: reason,
        modelIdUsed: 'gemma-4-e2b-test',
        taskType: taskType,
      );
    },
    indexerOverride: ({
      required rowId,
      required level,
      required content,
      required rangeStart,
      required rangeEnd,
    }) async {
      indexed?.add({
        'collection': 'summaries',
        'id': rowId.toString(),
        'level': level,
        'content': content,
        'range_start': rangeStart.toIso8601String(),
        'range_end': rangeEnd.toIso8601String(),
      });
    },
  );
}

Future<void> _insertConversation(
  AppDatabase appDatabase, {
  required DateTime createdAt,
  required String user,
  required String assistant,
}) async {
  final database = await appDatabase.open();
  await database.insert('messages', {
    'created_at': createdAt.toUtc().toIso8601String(),
    'user_message': user,
    'assistant_message': assistant,
    'tool_trace_json': '{}',
    'grounded_summary_json': '{}',
  });
}

Future<void> _insertSymptom(
  AppDatabase appDatabase, {
  required DateTime loggedAt,
  required String symptomType,
  required int severity,
  required String notes,
}) async {
  final database = await appDatabase.open();
  await database.insert('symptoms', {
    'logged_at': loggedAt.toUtc().toIso8601String(),
    'symptom_type': symptomType,
    'severity': severity,
    'notes': notes,
    'extraction_method': 'test',
    'created_at': loggedAt.toUtc().toIso8601String(),
  });
}

Future<void> _insertDailySummary(
  AppDatabase appDatabase, {
  required String dateLocal,
  required int? stepCount,
  required double? restingHrMean,
  required int? sleepTotalMinutes,
  required double? hrvSdnnMean,
}) async {
  final database = await appDatabase.open();
  await database.insert(
      'daily_summaries',
      {
        'date_local': dateLocal,
        'summary_json': jsonEncode({
          'date_local': dateLocal,
          if (stepCount != null) 'step_count_total': stepCount,
          if (restingHrMean != null) 'resting_hr_mean': restingHrMean,
          if (sleepTotalMinutes != null)
            'sleep_total_minutes': sleepTotalMinutes,
          if (hrvSdnnMean != null) 'hrv_sdnn_mean': hrvSdnnMean,
        }),
        'sync_quality_score': 0.5,
        'recomputed_at': '${dateLocal}T06:00:00.000Z',
      },
      conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<void> _insertEndoscopy(
  AppDatabase appDatabase, {
  required String procedureDate,
  required String procedureType,
  required int? mayoScore,
  required String? findings,
}) async {
  final database = await appDatabase.open();
  await database.insert('endoscopy_records', {
    'procedure_date': procedureDate,
    'procedure_type': procedureType,
    if (mayoScore != null) 'mayo_endoscopic_score': mayoScore,
    if (findings != null) 'findings_text': findings,
    'biopsies_taken': 0,
    'created_at': '${procedureDate}T00:00:00.000Z',
  });
}

Future<void> _insertIntakeEvent(
  AppDatabase appDatabase, {
  required DateTime loggedAt,
  required String eventType,
  required String? medicationName,
  required String? notes,
}) async {
  final database = await appDatabase.open();
  await database.insert('intake_events', {
    'event_type': eventType,
    'logged_at': loggedAt.toUtc().toIso8601String(),
    'date_local': loggedAt.toUtc().toIso8601String().substring(0, 10),
    'source': 'test',
    'confidence': 1.0,
    if (notes != null) 'notes': notes,
    'metadata_json': jsonEncode({
      if (medicationName != null) 'medication_name': medicationName,
    }),
    'created_at': loggedAt.toUtc().toIso8601String(),
  });
}
