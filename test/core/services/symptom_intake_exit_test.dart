// Tests that verify symptom intake exits only on explicit pivots
// (greetings/cancel/navigation) and uses clarifiers for underspecified input.
//
// Current behavior: Greeting/cancel exits intake, while vague or non-health
// short text stays in intake and receives a deterministic clarifier.

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
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_symptom_exit_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  LocalAgentService makeService() => LocalAgentService(
        repository: repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-05-11T10:00:00Z'),
      );

  // ── Greeting exits symptom intake mode ───────────────────────────────────

  test('saying "hi" after starting symptom log exits symptom intake', () async {
    final service = makeService();

    // Start symptom logging
    final start = await service.ask('Log a symptom');
    expect(start.status, 'deterministic_bare_symptom_intake');
    expect(start.message, contains('describe the symptom'));

    // User says "hi" instead of providing a symptom
    final greeting = await service.ask('hi');
    // Should exit symptom intake and return a greeting
    expect(greeting.status, isNot('deterministic_symptom_intake_clarifier'));
    expect(greeting.status, isNot('symptom_review_pending'));
    // Should be a greeting or general health question response
    expect(
      greeting.status,
      anyOf(
        'deterministic_greeting',
        'greeting',
        'deterministic_risk_reply',
        'unavailable',
      ),
    );
  });

  test(
    'saying "hello" after starting symptom log exits symptom intake',
    () async {
      final service = makeService();

      await service.ask('Log a symptom');
      final greeting = await service.ask('hello');

      expect(greeting.status, isNot('deterministic_symptom_intake_clarifier'));
      expect(greeting.status, isNot('symptom_review_pending'));
    },
  );

  test(
    'saying "hey" after starting symptom log exits symptom intake',
    () async {
      final service = makeService();

      await service.ask('Log a symptom');
      final greeting = await service.ask('hey');

      expect(greeting.status, isNot('deterministic_symptom_intake_clarifier'));
      expect(greeting.status, isNot('symptom_review_pending'));
    },
  );

  // ── Non-health short inputs stay in clarifier mode ───────────────────────

  test('non-health input "silly willy" triggers symptom clarifier', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final nonsense = await service.ask('silly willy');

    // Current intake flow keeps non-pivot short text in bounded clarifier mode.
    expect(nonsense.status, 'deterministic_symptom_intake_clarifier');
    expect(nonsense.message, contains('Please share'));
  });

  test('minimal non-health text triggers symptom clarifier', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final minimal = await service.ask('ok');

    // "ok" alone is treated as underspecified intake follow-up.
    expect(minimal.status, 'deterministic_symptom_intake_clarifier');
    expect(minimal.message, contains('Please share'));
  });

  // ── Health-related inputs STAY in symptom intake ──────────────────────────

  test('health-related input continues symptom intake', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final symptomInput = await service.ask('cramping pain');

    // Should stay in symptom intake or move to review
    expect(
      symptomInput.status,
      anyOf('deterministic_symptom_intake_clarifier', 'symptom_review_pending'),
    );
  });

  test('stool-related slang continues symptom intake', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final stoolInput = await service.ask('big poop');

    // Should stay in symptom intake or move to review
    expect(
      stoolInput.status,
      anyOf('deterministic_symptom_intake_clarifier', 'symptom_review_pending'),
    );
  });

  // ── Cancel command exits symptom intake ───────────────────────────────────

  test('saying "cancel" exits symptom intake', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final cancel = await service.ask('cancel');

    expect(cancel.status, isNot('deterministic_symptom_intake_clarifier'));
    expect(cancel.status, isNot('symptom_review_pending'));
  });

  test(
    'diacritic typo "cancé" is treated as cancel and exits intake',
    () async {
      final service = makeService();

      await service.ask('Log a symptom');
      final cancel = await service.ask('cancé');

      expect(cancel.status, isNot('deterministic_symptom_intake_clarifier'));
      expect(cancel.status, isNot('symptom_review_pending'));
    },
  );

  test('saying "stop" exits symptom intake', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final stop = await service.ask('stop');

    expect(stop.status, isNot('deterministic_symptom_intake_clarifier'));
    expect(stop.status, isNot('symptom_review_pending'));
  });

  test('saying "nevermind" exits symptom intake', () async {
    final service = makeService();

    await service.ask('Log a symptom');
    final nevermind = await service.ask('nevermind');

    expect(nevermind.status, isNot('deterministic_symptom_intake_clarifier'));
    expect(nevermind.status, isNot('symptom_review_pending'));
  });
}
