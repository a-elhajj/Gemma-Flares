// Tests that verify the bare-symptom pre-query short-circuit fix:
//
// Before the fix, LocalAgentService.ask() always fired 17 parallel SQLite
// queries BEFORE routing, even for messages like "Log a symptom" that were
// going to return a canned intake prompt that used none of that data.
//
// After the fix, bare-symptom-log messages short-circuit before any DB I/O
// and return the intake prompt with an empty groundedSummaryJson.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late _SpyRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_bare_symptom_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = _SpyRepository(database: database);
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  LocalAgentService makeService() => LocalAgentService(
        repository: repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-05-08T10:00:00Z'),
      );

  // ── Bare intake prompt is returned ───────────────────────────────────────

  test('returns bare symptom intake prompt for "log a symptom"', () async {
    final service = makeService();
    final reply = await service.ask('Log a symptom');
    expect(reply.status, 'deterministic_bare_symptom_intake');
    expect(reply.message, contains('describe the symptom'));
    expect(reply.runtimeName, 'deterministic');
  });

  test('returns intake prompt for "log symptom" (no article)', () async {
    final service = makeService();
    final reply = await service.ask('log symptom');
    expect(reply.status, 'deterministic_bare_symptom_intake');
  });

  test('returns intake prompt for "record a symptom"', () async {
    final service = makeService();
    final reply = await service.ask('record a symptom');
    expect(reply.status, 'deterministic_bare_symptom_intake');
  });

  test('returns intake prompt for "I have a symptom to log"', () async {
    final service = makeService();
    final reply = await service.ask('I have a symptom to log');
    expect(reply.status, 'deterministic_bare_symptom_intake');
  });

  // ── No heavy DB queries fired before the fast path ───────────────────────

  test(
    'no flare-risk or daily-summary queries are fired for bare intake',
    () async {
      final service = makeService();
      await service.ask('Log a symptom');
      expect(
        repository.flareRiskQueryCount,
        0,
        reason: 'getLatestUserFacingFlareRiskScore should not be called',
      );
      expect(
        repository.dailySummaryQueryCount,
        0,
        reason: 'getLatestDailySummary should not be called',
      );
      expect(
        repository.labValueQueryCount,
        0,
        reason: 'getLabValues should not be called',
      );
      expect(
        repository.endoscopyQueryCount,
        0,
        reason: 'getEndoscopyRecords should not be called',
      );
    },
  );

  test(
    'conversation is still persisted even without DB context queries',
    () async {
      final service = makeService();
      await service.ask('Log a symptom');
      // insertConversation IS expected — that is the only write.
      expect(repository.insertConversationCount, 1);
      final convs = await repository.getRecentConversations(limit: 5);
      expect(convs, hasLength(1));
      expect(convs.single.userMessage, 'Log a symptom');
    },
  );

  test('groundedSummaryJson is empty for bare symptom fast path', () async {
    final service = makeService();
    final reply = await service.ask('Log a symptom');
    expect(reply.groundedSummaryJson, isEmpty);
  });

  // ── Messages with actual symptom content do NOT hit the fast path ─────────

  test('message with symptom detail does NOT hit bare-intake fast path',
      () async {
    final service = makeService();
    // "log a symptom: I have cramping pain severity 7" has content after the
    // bare-log prefix — it should reach the full query path.
    final reply = await service.ask(
      'I want to log my abdominal cramping — it started an hour ago, severity 7.',
    );
    // The reply will be 'unavailable' because the runtime is UnavailableGemmaRuntime,
    // but crucially it should NOT be the bare-intake status.
    expect(reply.status, isNot('deterministic_bare_symptom_intake'));
    // And the full context query block ran, meaning flare risk was queried.
    expect(repository.flareRiskQueryCount, greaterThan(0));
  });

  // ── Intake prompt content quality ────────────────────────────────────────

  test('intake prompt includes all four intake fields', () async {
    final service = makeService();
    final reply = await service.ask('log symptoms');
    expect(reply.message, contains('Symptom'));
    expect(reply.message, contains('Frequency'));
    expect(reply.message, contains('Trigger'));
    expect(reply.message, contains('Duration'));
  });

  test('tool trace records fast-path metadata', () async {
    final service = makeService();
    final reply = await service.ask('Log a symptom');
    expect(reply.toolTraceJson['deterministic_fast_path_used'], isTrue);
    expect(reply.toolTraceJson['chat_path'], 'bare_symptom_intake_prompt');
    expect(reply.toolTraceJson['used_model_output'], isFalse);
  });
}

// ---------------------------------------------------------------------------
// Spy repository — counts specific read method invocations so tests can
// assert that heavy queries are not fired on the fast path.
// ---------------------------------------------------------------------------

class _SpyRepository extends WearableSampleRepository {
  _SpyRepository({required super.database});

  int flareRiskQueryCount = 0;
  int dailySummaryQueryCount = 0;
  int labValueQueryCount = 0;
  int endoscopyQueryCount = 0;
  int insertConversationCount = 0;

  @override
  Future<FlareRiskScoreRecord?> getLatestUserFacingFlareRiskScore({
    String? dateLocal,
  }) {
    flareRiskQueryCount++;
    return super.getLatestUserFacingFlareRiskScore(dateLocal: dateLocal);
  }

  @override
  Future<DailySummaryRecord?> getLatestDailySummary() {
    dailySummaryQueryCount++;
    return super.getLatestDailySummary();
  }

  @override
  Future<List<LabValueRecord>> getLabValues({String? labType}) {
    labValueQueryCount++;
    return super.getLabValues(labType: labType);
  }

  @override
  Future<List<EndoscopyRecord>> getEndoscopyRecords() {
    endoscopyQueryCount++;
    return super.getEndoscopyRecords();
  }

  @override
  Future<int> insertConversation(ConversationRecord record) {
    insertConversationCount++;
    return super.insertConversation(record);
  }
}
