import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/background_job_service.dart';
import 'package:gemma_flares/core/services/background_orchestration_service.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/hierarchical_summary_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/proactive_open_service.dart';
import 'package:gemma_flares/core/services/vector_index_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_bg_orchestrator_test',
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

  test(
    'schedules summaries and proactive planning for daily maintenance',
    () async {
      final service = _service(database);

      final jobs = await service.scheduleDailyMaintenance(
        throughDate: DateTime.utc(2026, 5, 5),
        summaryLookbackDays: 2,
      );

      expect(jobs.map((job) => job.idempotencyKey), [
        'daily_summary:2026-05-04',
        'daily_summary:2026-05-05',
        'proactive_plan:2026-05-05',
      ]);
    },
  );

  test('runDue executes daily summary jobs', () async {
    await _insertConversation(
      database,
      createdAt: DateTime.parse('2026-05-05T14:00:00Z'),
      user: 'Bathroom six times today.',
      assistant: 'Logged increased stool frequency.',
    );
    final generated = <String>[];
    final service = _service(database, generated: generated);
    await service.scheduleDailyMaintenance(
      throughDate: DateTime.utc(2026, 5, 5),
      summaryLookbackDays: 1,
    );

    final result = await service.runDue(maxJobs: 1);

    expect(result.completed, 1);
    expect(generated, ['daily_summary']);
  });
}

BackgroundOrchestrationService _service(
  AppDatabase database, {
  List<String>? generated,
}) {
  final backgroundJobs = BackgroundJobService(
    database: database,
    nowProvider: () => DateTime.utc(2026, 5, 5, 23, 58),
  );
  final summaries = HierarchicalSummaryService(
    database: database,
    router: GemmaRouterService(runtime: const UnavailableGemmaRuntime()),
    vectorIndex: VectorIndexService(),
    nowProvider: () => DateTime.utc(2026, 5, 5, 23, 58),
    generatorOverride: (
      userMessage, {
      required taskType,
      required systemPrompt,
      required groundedContext,
      conversationId,
    }) async {
      generated?.add(taskType);
      return LocalModelResponse(
        status: 'success',
        outputText: 'Summary generated for $taskType.',
        runtimeName: 'fake',
        modelIdUsed: 'gemma-test',
      );
    },
    indexerOverride: ({
      required rowId,
      required level,
      required content,
      required rangeStart,
      required rangeEnd,
    }) async {},
  );
  return BackgroundOrchestrationService(
    backgroundJobs: backgroundJobs,
    summaries: summaries,
    proactiveOpen: ProactiveOpenService(
      database: database,
      nowProvider: () => DateTime.utc(2026, 5, 5, 23, 58),
    ),
    nowProvider: () => DateTime.utc(2026, 5, 5, 23, 58),
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
