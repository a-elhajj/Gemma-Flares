import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/proactive_open_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_proactive_test',
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
    'allows a first daily opening check-in when no prior open exists',
    () async {
      final service = _service(database);

      final decision = await service.evaluate(
        evidence: const ProactiveOpenEvidence(),
      );

      expect(decision.shouldSpeakFirst, isTrue);
      expect(decision.triggerType, 'daily_open_checkin');
      expect(decision.openCountToday, 0);
    },
  );

  test('allows symptom escalation when outside cooldown', () async {
    await _insertProactiveOpen(
      database,
      DateTime.parse('2026-05-05T08:00:00Z'),
    );
    final service = _service(database);

    final decision = await service.evaluate(
      evidence: const ProactiveOpenEvidence(symptomEscalation: true),
    );

    expect(decision.shouldSpeakFirst, isTrue);
    expect(decision.triggerType, 'symptom_escalation');
    expect(decision.openCountToday, 1);
    expect(decision.minutesSinceLastOpen, 300);
  });

  test('blocks opens during the 240 minute cooldown', () async {
    await _insertProactiveOpen(
      database,
      DateTime.parse('2026-05-05T10:00:00Z'),
    );
    final service = _service(database);

    final decision = await service.evaluate(
      evidence: const ProactiveOpenEvidence(newLab: true),
    );

    expect(decision.shouldSpeakFirst, isFalse);
    expect(decision.reason, 'cooldown_active');
    expect(decision.minutesSinceLastOpen, 180);
  });

  test(
    'blocks cooldown using repository-persisted proactive open flag',
    () async {
      final repository = WearableSampleRepository(database: database);
      await repository.insertConversation(
        ConversationRecord(
          createdAt: DateTime.parse('2026-05-05T10:00:00Z'),
          userMessage: '[app_open_proactive_checkin]',
          assistantMessage: 'How is your gut feeling today?',
          toolTraceJson: const {'status': 'proactive_open'},
          groundedSummaryJson: const {},
          sessionId: 'sess-1',
          isProactiveOpen: true,
        ),
      );
      final service = _service(database);

      final decision = await service.evaluate(
        evidence: const ProactiveOpenEvidence(newLab: true),
      );

      expect(decision.shouldSpeakFirst, isFalse);
      expect(decision.reason, 'cooldown_active');
      expect(decision.openCountToday, 1);
    },
  );

  test('blocks after three proactive opens in one day', () async {
    await _insertProactiveOpen(
      database,
      DateTime.parse('2026-05-05T01:00:00Z'),
    );
    await _insertProactiveOpen(
      database,
      DateTime.parse('2026-05-05T02:00:00Z'),
    );
    await _insertProactiveOpen(
      database,
      DateTime.parse('2026-05-05T03:00:00Z'),
    );
    final service = _service(database);

    final decision = await service.evaluate(
      evidence: const ProactiveOpenEvidence(hrvDrop: true),
    );

    expect(decision.shouldSpeakFirst, isFalse);
    expect(decision.reason, 'daily_limit_reached');
    expect(decision.openCountToday, 3);
  });

  test('respects quiet hours preferences', () async {
    final service = ProactiveOpenService(
      database: database,
      nowProvider: () => DateTime.parse('2026-05-05T03:00:00Z'),
    );

    final decision = await service.evaluate(
      evidence: const ProactiveOpenEvidence(missedMedication: true),
    );

    expect(decision.shouldSpeakFirst, isFalse);
    expect(decision.reason, 'quiet_hours');
  });

  test('derives symptom escalation from grounded context', () async {
    final service = _service(database);

    final decision = await service.evaluateFromGroundedContext({
      'recent_symptoms': [
        {'symptom': 'cramping', 'severity': 3},
      ],
      'recent_checkins': const [],
    });

    expect(decision.shouldSpeakFirst, isTrue);
    expect(decision.triggerType, 'symptom_escalation');
  });
}

ProactiveOpenService _service(AppDatabase database) {
  return ProactiveOpenService(
    database: database,
    nowProvider: () => DateTime.parse('2026-05-05T13:00:00Z'),
  );
}

Future<void> _insertProactiveOpen(
  AppDatabase appDatabase,
  DateTime createdAt,
) async {
  final database = await appDatabase.open();
  await database.insert('messages', {
    'created_at': createdAt.toUtc().toIso8601String(),
    'user_message': '[app_open_proactive_checkin]',
    'assistant_message': 'How is your gut feeling today?',
    'tool_trace_json': '{"status":"proactive_open"}',
    'grounded_summary_json': '{}',
    'is_proactive_open': 1,
  });
}
