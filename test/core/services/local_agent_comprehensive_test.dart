@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/gemma_task_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A runtime that returns a successful model response with configurable text.
class _FakeSuccessRuntime implements LocalModelRuntime {
  const _FakeSuccessRuntime(
    this.outputText, {
    this.responseStatus = 'success',
    this.reason = 'generation_success',
  });

  final String outputText;
  final String responseStatus;
  final String reason;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'fake-success',
      backendStyle: 'test',
      modelId: 'fake',
      quantization: 'none',
      expectedModelFilename: 'Models/litert-lm/fake',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'ok',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) =>
      getRuntimeStatus();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return LocalModelResponse(
      status: responseStatus,
      outputText: outputText,
      runtimeName: 'fake-success',
      reason: reason,
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}

class _CapturingRuntime implements LocalModelRuntime {
  LocalModelRequest? lastRequest;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'capturing-runtime',
      backendStyle: 'test',
      modelId: 'fake',
      quantization: 'none',
      expectedModelFilename: 'Models/litert-lm/fake',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'ok',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) =>
      getRuntimeStatus();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    lastRequest = request;
    return const LocalModelResponse(
      status: 'success',
      outputText: 'Your local signals are worth watching.',
      runtimeName: 'capturing-runtime',
      reason: 'generation_success',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}

class _LoadThenSuccessRuntime implements LocalModelRuntime {
  int loadCalls = 0;
  int generateCalls = 0;
  String? requestedProfile;
  LocalModelRequest? lastRequest;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return LocalModelRuntimeStatus(
      status: loadCalls == 0 ? 'not_loaded' : 'ready',
      runtimeName: 'load-then-success',
      backendStyle: 'test',
      modelId: 'fake',
      quantization: 'none',
      expectedModelFilename: 'Models/litert-lm/fake',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: loadCalls > 0,
      reason: loadCalls == 0 ? 'not loaded' : 'ready',
      activeRuntimeProfile: 'phone_balanced',
      contextWindow: 1024,
      batchSize: 8,
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    loadCalls += 1;
    requestedProfile = profile;
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateCalls += 1;
    lastRequest = request;
    return const LocalModelResponse(
      status: 'success',
      outputText: 'Gemma saw the local evidence and explained it.',
      runtimeName: 'load-then-success',
      reason: 'generation_success',
      estimatedPromptTokens: 120,
      promptBudget: 928,
      generationLimit: 96,
      generationLatencyMs: 42,
      activeRuntimeProfile: 'phone_balanced',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}

late Directory _tempRoot;
late AppDatabase _database;
late WearableSampleRepository _repository;

Future<void> _setUp() async {
  _tempRoot = await Directory.systemTemp.createTemp('gemma_flares_agent_comp_');
  _database = AppDatabase(
    migrationLoader: (assetPath) async => File(assetPath).readAsString(),
    databaseFactoryOverride: databaseFactoryFfi,
    databaseDirectoryProvider: () async => _tempRoot.path,
  );
  _repository = WearableSampleRepository(database: _database);
}

Future<void> _tearDown() async {
  await _database.close();
  await _tempRoot.delete(recursive: true);
}

FlareRiskScoreRecord _score({
  double riskScore = 48,
  String riskBand = 'moderate',
  double confidence = 82,
  Map<String, Object?> contributions = const {
    'hrv_points': 16,
    'resting_hr_points': 12,
    'sleep_points': 5,
    'symptom_points': 0,
    'steps_points': 4,
  },
}) {
  return FlareRiskScoreRecord(
    dateLocal: '2026-04-19',
    riskScore: riskScore,
    riskBand: riskBand,
    confidenceScore: confidence,
    contributionJson: contributions,
    featureSnapshotJson: const {},
    modelVersion: 'risk_v1',
    createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
  );
}

DailySummaryRecord _summary({String date = '2026-04-19'}) {
  return DailySummaryRecord(
    dateLocal: date,
    summaryJson: const {
      'hrv_sdnn_mean': 42.0,
      'resting_hr_mean': 62.0,
      'sleep_total_minutes': 390,
      'step_count_total': 6100,
    },
    syncQualityScore: 1,
    recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
  );
}

SymptomRecord _symptom({String type = 'abdominal_pain', int severity = 6}) {
  return SymptomRecord(
    loggedAt: DateTime.parse('2026-04-19T14:00:00Z'),
    symptomType: type,
    severity: severity,
    sourceTranscript: 'test',
    extractionMethod: 'test',
    extractionConfidence: 0.8,
    createdAt: DateTime.parse('2026-04-19T14:00:00Z'),
  );
}

LabValueRecord _lab({
  String drawnDate = '2026-04-19',
  String labType = 'crp',
  double value = 12.4,
  String unit = 'mg/L',
  double? referenceHigh = 5,
}) {
  return LabValueRecord(
    drawnDate: drawnDate,
    labType: labType,
    valueNumeric: value,
    unit: unit,
    referenceHigh: referenceHigh,
    createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
    updatedAt: DateTime.parse('2026-04-20T08:00:00Z'),
  );
}

void main() {
  sqfliteFfiInit();

  // ── Safety envelope ──────────────────────────────────────────

  group('Safety envelope', () {
    test('appends non-diagnostic disclaimer when absent', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('Your HRV was lower yesterday.'),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('How am I?');
      expect(reply.message, contains('not a doctor'));
      expect(reply.message, startsWith('Your HRV was lower yesterday.'));
      await _tearDown();
    });

    test(
      'does not double-append disclaimer when model already includes it',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime(
            'Patterns look stable. This is not a diagnosis.',
          ),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('Summary');
        expect('This is not a diagnosis.'.allMatches(reply.message).length, 1);
        await _tearDown();
      },
    );

    test('handles empty model output gracefully', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime(''),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Hello');
      expect(reply.status, 'fallback_invalid_model_output');
      expect(reply.message, startsWith('Hi!'));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      expect(reply.message.trim(), isNotEmpty);
      await _tearDown();
    });

    test('handles whitespace-only model output', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('   \n  '),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Hello');
      expect(reply.status, 'fallback_invalid_model_output');
      expect(reply.message, startsWith('Hi!'));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // ── Fallback reply: no score ─────────────────────────────────

  group('Fallback reply when no risk score exists', () {
    test('instructs user to sync Health data', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('What is my risk?');
      // Fallback: no score message references syncing data
      expect(reply.message.toLowerCase(), contains('sync'));
      expect(reply.message.toLowerCase(), contains('health data'));
      await _tearDown();
    });

    test(
      'lab-start statement asks for values or report instead of greeting',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('I just got labs back');

        expect(reply.toolTraceJson['agent_intent'], 'lab_question');
        expect(reply.message.toLowerCase(), contains('paste the values'));
        expect(reply.message.toLowerCase(), contains('attach'));
        expect(reply.message.toLowerCase(), contains('crp'));
        expect(reply.message.toLowerCase(), isNot(contains('hi there')));
        await _tearDown();
      },
    );
  });

  group('Off-topic model output rejection', () {
    test(
      'routes bare lab intent through deterministic intake prompt',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime(
            'Hi there. How can I help you with your IBD concerns today?',
          ),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('I just got labs back');

        expect(reply.status, 'deterministic_action_prompt');
        expect(reply.toolTraceJson['agent_intent'], 'lab_question');
        expect(reply.toolTraceJson['used_model_output'], isFalse);
        expect(reply.toolTraceJson['chat_path'], 'action_intake_prompt');
        expect(reply.message.toLowerCase(), contains('paste the values'));
        expect(reply.message.toLowerCase(), contains('scan the report'));
        expect(reply.message.toLowerCase(), isNot(contains('hi there')));
        await _tearDown();
      },
    );
  });

  group('Lab chat ingestion', () {
    test('pasted lab values create a review-before-save action', () async {
      await _setUp();
      final labRuntime = _FakeSuccessRuntime(
        '{"drawn_date":"2026-04-20","lab_name":"Quest","ordering_provider":null,"labs":[{"lab_type":"crp","value_numeric":12.4,"unit":"mg/L","reference_high":5,"abnormal_flag":true,"confidence":0.91,"source_text_snippet":"CRP 12.4 mg/L"}]}',
      );
      final gemmaTaskService = GemmaTaskService(
        repository: _repository,
        runtime: labRuntime,
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('This should not be used.'),
        gemmaTaskService: gemmaTaskService,
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      final reply = await service.ask('I just got labs back. CRP 12.4 mg/L');

      expect(reply.status, 'lab_review_pending');
      expect(reply.pendingAction?.type, 'lab_review');
      expect(reply.message.toLowerCase(), contains('crp'));
      expect(reply.message.toLowerCase(), contains('nothing is saved'));
      final candidates = reply.pendingAction?.payloadJson['candidate_labs'];
      expect(candidates, isA<List>());
      expect((candidates as List), hasLength(1));
      expect((candidates.single as Map)['lab_type'], 'crp');
      await _tearDown();
    });
  });

  // ── Fallback reply: with score, "why" / "explain" path ──────

  group('Fallback reply – explain path', () {
    test(
      'includes score, band, confidence and drivers for "why" question',
      () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('Summarize my recent pattern.');
        expect(reply.message, contains('48/100'));
        expect(reply.message, contains('moderate'));
        expect(reply.message, contains('82/100')); // confidence
        expect(reply.message, contains('lower heart rhythm variability'));
        expect(reply.message, contains('higher resting heart rate'));
        expect(reply.message, contains('reduced sleep'));
        expect(reply.message, contains('lower activity'));
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      },
    );

    test('"explain" triggers the same explain path', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Please explain my score');
      expect(reply.message, contains('48/100'));
      expect(reply.message, contains('lower heart rhythm variability'));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });

    test('shows "no strong contributors" when all points are zero', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(
        _score(
          riskScore: 5,
          riskBand: 'low',
          contributions: const {
            'hrv_points': 0,
            'resting_hr_points': 0,
            'sleep_points': 0,
            'symptom_points': 0,
            'steps_points': 0,
          },
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Why is this the score?');
      expect(
        reply.message,
        contains('no strong signals'),
      ); // renamed from 'no strong contributors'
      await _tearDown();
    });

    test('includes "recent symptoms" driver when symptom_points > 0', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(
        _score(
          contributions: const {
            'hrv_points': 0,
            'resting_hr_points': 0,
            'sleep_points': 0,
            'symptom_points': 15,
            'steps_points': 0,
          },
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Explain');
      expect(reply.message, contains('recent symptoms'));
      await _tearDown();
    });
  });

  // ── Fallback reply: "symptom" path ──────────────────────────

  group('Fallback reply – symptom path', () {
    test('reports symptom count and score', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      await _repository.insertSymptom(_symptom());
      await _repository.insertSymptom(_symptom(type: 'nausea', severity: 4));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Tell me about my symptoms');
      expect(reply.message, contains('2 recent symptom'));
      expect(reply.message, contains('48/100'));
      await _tearDown();
    });

    test('zero symptoms reports 0', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Any symptom patterns?');
      expect(reply.message, contains('0 recent symptom'));
      await _tearDown();
    });
  });

  // ── Fallback reply: generic path ────────────────────────────

  group('Fallback reply – generic path', () {
    test('returns score and drivers for generic question', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Hello');
      expect(reply.message, startsWith('Hi!'));
      expect(reply.message, contains('48/100'));
      expect(reply.message, isNot(contains('This is not a diagnosis.')));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // ── Grounded context assembly ───────────────────────────────

  group('Grounded context assembly', () {
    test('includes latest score details', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Summarize my recent pattern.');
      final latestScore =
          reply.groundedSummaryJson['latest_score'] as Map<String, Object?>;
      expect(latestScore['risk_score'], 48);
      expect(latestScore['risk_band'], 'moderate');
      expect(latestScore['confidence_score'], 82);
      expect(latestScore['date_local'], '2026-04-19');
      await _tearDown();
    });

    test('latest_score is null when database is empty', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Summarize my recent pattern.');
      expect(reply.groundedSummaryJson['latest_score'], isNull);
      await _tearDown();
    });

    test('includes recent summary dates', () async {
      await _setUp();
      await _repository.upsertDailySummary(_summary(date: '2026-04-18'));
      await _repository.upsertDailySummary(_summary(date: '2026-04-19'));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Summarize my recent pattern.');
      final dates =
          reply.groundedSummaryJson['recent_summary_dates'] as List<Object?>;
      expect(dates, hasLength(2));
      await _tearDown();
    });

    test('includes recent symptoms in grounded context', () async {
      await _setUp();
      await _repository.insertSymptom(_symptom());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Summarize my recent pattern.');
      final symptoms =
          reply.groundedSummaryJson['recent_symptoms'] as List<Object?>;
      expect(symptoms, hasLength(1));
      final first = symptoms.first as Map<String, Object?>;
      expect(first['symptom_type'], 'abdominal_pain');
      expect(first['severity'], 6.0);
      await _tearDown();
    });

    test('latest_summary carries summaryJson through', () async {
      await _setUp();
      await _repository.upsertDailySummary(_summary());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Why is my risk higher?');
      final summary =
          reply.groundedSummaryJson['latest_summary'] as Map<String, Object?>;
      expect(summary['hrv_sdnn_mean'], 42.0);
      await _tearDown();
    });
  });

  // ── Tool trace ──────────────────────────────────────────────

  group('Tool trace', () {
    test('contains expected tool names', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Why is my risk higher?');
      final tools = reply.toolTraceJson['tools_called'] as List<Object?>;
      expect(
        tools,
        containsAll([
          'get_today_risk_snapshot',
          'get_context_attribution',
          'get_recent_symptoms',
        ]),
      );
      await _tearDown();
    });

    test('records asked_at timestamp from nowProvider', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('test');
      expect(reply.toolTraceJson['asked_at'], '2026-04-20T08:00:00.000Z');
      await _tearDown();
    });
  });

  // ── Conversation persistence ────────────────────────────────

  group('Conversation persistence', () {
    test('first ask has empty recent_conversation_turns', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Hello');
      final turns = reply.groundedSummaryJson['recent_conversation_turns']
          as List<Object?>;
      expect(turns, isEmpty);
      await _tearDown();
    });

    test(
      'second ask sees first conversation in recent_conversation_turns',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        await service.ask('First question');
        final reply2 = await service.ask('Second question');
        final turns = reply2.groundedSummaryJson['recent_conversation_turns']
            as List<Object?>;
        expect(turns, hasLength(1));
        final first = turns.first as Map<String, Object?>;
        expect(first['user_message'], 'First question');
        await _tearDown();
      },
    );

    test('conversation accumulates up to limit', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      await service.ask('Q1');
      await service.ask('Q2');
      await service.ask('Q3');
      final reply4 = await service.ask('Q4');
      final turns = reply4.groundedSummaryJson['recent_conversation_turns']
          as List<Object?>;
      // limit: 3 in the service
      expect(turns, hasLength(3));
      await _tearDown();
    });

    test(
      'persisted conversation contains user and assistant messages',
      () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        await service.ask('Why is my risk higher?');
        final conversations = await _repository.getRecentConversations();
        expect(conversations, hasLength(1));
        expect(conversations.first.userMessage, 'Why is my risk higher?');
        expect(conversations.first.assistantMessage, contains('48/100'));
        await _tearDown();
      },
    );

    test(
      'persisted conversation includes tool trace and grounded summary',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        await service.ask('Hello');
        final conversations = await _repository.getRecentConversations();
        expect(conversations.first.toolTraceJson['tools_called'], isNotNull);
        expect(conversations.first.groundedSummaryJson, isNotEmpty);
        await _tearDown();
      },
    );
  });

  // ── Successful runtime path ─────────────────────────────────

  group('Successful runtime path', () {
    test('uses model output when status is success', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('Your patterns look stable.'),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('How am I?');
      expect(reply.status, 'success');
      expect(reply.runtimeName, 'fake-success');
      expect(reply.message, startsWith('Your patterns look stable.'));
      expect(reply.message, contains('not a doctor'));
      await _tearDown();
    });

    test(
      'rejects legacy ready status even with non-empty model output',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime(
            'Hi, how are you feeling today?',
            responseStatus: 'ready',
            reason: 'legacy_ready_status',
          ),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('hi');
        expect(reply.status, 'ready');
        expect(reply.message, startsWith('Hi!'));
        expect(reply.toolTraceJson['model_generation_status'], 'ready');
        expect(reply.toolTraceJson['used_model_output'], isFalse);
        await _tearDown();
      },
    );

    test(
      'rejects control-token garbage from successful model response',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime(
            r'Why</>}</.</</!</</>\</>>>>>>>>.</</>>>>>>>>.</.</></>>>>>>>>>>>>>>>>.</shtml',
          ),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask('Summarize my recent pattern.');
        expect(reply.status, 'fallback_invalid_model_output');
        expect(reply.message, isNot(contains('>>>>')));
        expect(reply.message, isNot(contains('shtml')));
        expect(reply.toolTraceJson['used_model_output'], isFalse);
        expect(reply.toolTraceJson['output_quality_status'], 'rejected');
        await _tearDown();
      },
    );

    test('strips stale loading notice from model output', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime(
          'Your score is based on local trends.\n\n'
          '_Gemma 4 is loading -- full conversational analysis will be available shortly._',
        ),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Summarize my recent pattern.');
      expect(reply.message, contains('Your score is based on local trends.'));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });

    test('sends compact runtime grounding to fit native context', () async {
      await _setUp();
      final runtime = _CapturingRuntime();
      await _repository.upsertFlareRiskScore(
        _score(
          contributions: {
            'hrv_points': 16,
            'resting_hr_points': 12,
            'sleep_points': 5,
            'symptom_points': 0,
            'debug_blob': 'x' * 2000,
          },
        ),
      );
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: DateTime.parse('2026-04-20T07:00:00Z'),
          userMessage: 'Previous long question ${'q' * 500}',
          assistantMessage: 'Previous long answer ${'a' * 2000}',
          toolTraceJson: const {},
          groundedSummaryJson: const {},
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: runtime,
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      await service.ask('Summarize my recent pattern. ${'u' * 500}');

      final request = runtime.lastRequest!;
      // Sparse data (score only, no symptoms/labs/checkins) → scaled tokens
      expect(request.maxTokens, 132);
      expect(request.taskType, 'chat');
      expect(request.systemPrompt.length, lessThan(2300));
      expect(request.userPrompt.length, lessThan(1200));
      expect(request.groundedContext.keys, contains('score'));
      expect(request.groundedContext.keys, isNot(contains('latest_summary')));
      expect(
        request.groundedContext.keys,
        isNot(contains('recent_conversation_turns')),
      );
      expect(request.groundedContext.toString(), isNot(contains('debug_blob')));
      await _tearDown();
    });

    test(
      'loads bundled model before generating when runtime is available',
      () async {
        await _setUp();
        final runtime = _LoadThenSuccessRuntime();
        final service = LocalAgentService(
          repository: _repository,
          runtime: runtime,
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );

        final reply = await service.ask('Summarize my recent pattern.');

        expect(reply.status, 'success');
        expect(runtime.loadCalls, 1);
        expect(runtime.requestedProfile, 'phone_large');
        expect(runtime.generateCalls, 1);
        expect(runtime.lastRequest?.taskType, 'chat');
        expect(reply.toolTraceJson['runtime_load_attempted'], isTrue);
        expect(reply.toolTraceJson['used_model_output'], isTrue);
        expect(reply.toolTraceJson['estimated_prompt_tokens'], 120);
        await _tearDown();
      },
    );
  });

  // ── Reply metadata ──────────────────────────────────────────

  group('Reply metadata', () {
    test('reports unavailable status when runtime is down', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('test');
      expect(reply.status, 'unavailable');
      expect(reply.runtimeName, 'litert-lm-ios-gemma4-unavailable');
      await _tearDown();
    });
  });

  // ── High risk score ─────────────────────────────────────────

  group('High / critical risk score fallback', () {
    test('critical score shows correct band and drivers', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(
        _score(
          riskScore: 88,
          riskBand: 'critical',
          confidence: 90,
          contributions: const {
            'hrv_points': 25,
            'resting_hr_points': 20,
            'sleep_points': 15,
            'symptom_points': 18,
            'steps_points': 10,
          },
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Why is my risk so high?');
      expect(reply.message, contains('88/100'));
      expect(reply.message, contains('critical'));
      expect(reply.message, contains('lower heart rhythm variability'));
      expect(reply.message, contains('higher resting heart rate'));
      expect(reply.message, contains('reduced sleep'));
      expect(reply.message, contains('recent symptoms'));
      expect(reply.message, contains('lower activity'));
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // =========================================================================
  // Crohn's symptom keyword coverage — fallback path
  // =========================================================================
  group('Crohn symptom keyword fallback replies', () {
    // Each question below contains a Crohn's-specific symptom term.
    // The fallback path should classify them as symptom_question or
    // general_health_question and produce a relevant reply.
    const symptomQuestions = {
      'fistula': 'I think I have a fistula',
      'abscess': 'do I have an abscess',
      'stricture': 'is my stricture getting worse',
      'obstruction': 'I feel like I have an obstruction',
      'mouth sores': 'I have mouth sores again',
      'constipation': 'I have been constipated for days',
      'night sweats': 'I had night sweats last night',
      'joint pain': 'my joints are killing me',
      'rash': 'I got a new rash',
      'rectal': 'I have rectal discomfort',
      'drainage': 'there is drainage from my fistula site',
      'weight loss': 'I keep losing weight without trying',
      'malnutrition': 'I think I am malnourished',
      'anemia': 'am I anemic',
      'dehydration': 'I feel very dehydrated',
      'chills': 'I have chills and feel terrible',
      'tenesmus': 'I have tenesmus after every meal',
      'gas': 'the gas is unbearable today',
      'anal fissure': 'I think I have an anal fissure',
      'eye issues': 'my eye is irritated and red today',
    };

    for (final entry in symptomQuestions.entries) {
      test('fallback handles "${entry.key}" question', () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(entry.value);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Medication term recognition in fallback path
  // =========================================================================
  group('Medication question recognition', () {
    const medQuestions = [
      'should I stop taking humira?',
      'can I switch from remicade to stelara?',
      'what about entyvio side effects?',
      'should I start skyrizi?',
      'can I take rinvoq?',
      'what about cimzia?',
      'is omvoh better?',
      'tell me about tremfya',
      'should I stop imuran?',
      'can I switch to pentasa?',
      'what about sulfasalazine?',
      'should I change my lialda dose?',
      'what does simponi do?',
      'can I stop mercaptopurine?',
      'should I take ciprofloxacin?',
      'is flagyl safe for me?',
      'what about metronidazole?',
      'is a jak inhibitor right for me?',
    ];

    for (final q in medQuestions) {
      test(
        'recognizes med question: "${q.length > 35 ? q.substring(0, 35) : q}..."',
        () async {
          await _setUp();
          final service = LocalAgentService(
            repository: _repository,
            runtime: const UnavailableGemmaRuntime(),
            nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
          );
          final reply = await service.ask(q);
          // Medication questions should include a safety redirect
          expect(reply.message, isNotEmpty);
          expect(reply.message, isNot(contains('Gemma 4 is loading')));
          await _tearDown();
        },
      );
    }
  });

  // =========================================================================
  // Urgent symptom detection
  // =========================================================================
  group('Urgent symptom routing', () {
    const urgentMessages = [
      'I have severe pain in my abdomen',
      'there is heavy bleeding from my rectum',
      'I have a high fever of 104',
      'I can\'t keep anything down',
      'should I go to the ER?',
      'I need an ambulance',
      'excruciating pain won\'t stop',
      'I\'m burning up with fever',
      'soaked in blood',
      'throwing up everything',
    ];

    for (final msg in urgentMessages) {
      test(
        'routes urgent: "${msg.length > 35 ? msg.substring(0, 35) : msg}..."',
        () async {
          await _setUp();
          final service = LocalAgentService(
            repository: _repository,
            runtime: const UnavailableGemmaRuntime(),
            nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
          );
          final reply = await service.ask(msg);
          expect(
            reply.message.toLowerCase(),
            anyOf(
              contains('emergency'),
              contains('911'),
              contains('urgent'),
              contains('medical'),
              contains('help'),
              contains('doctor'),
            ),
          );
          expect(reply.message, isNot(contains('Gemma 4 is loading')));
          await _tearDown();
        },
      );
    }
  });

  // =========================================================================
  // Emotional distress routing
  // =========================================================================
  group('Emotional distress routing', () {
    const emotionalMessages = [
      'I am so scared about my disease',
      'I feel hopeless about crohns',
      'I can\'t cope anymore',
      'why me this is not fair',
      'I am so frustrated and alone',
      'I feel depressed about my condition',
      'will this ever get better?',
      'I\'m tired of being sick all the time',
    ];

    for (final msg in emotionalMessages) {
      test(
        'emotional: "${msg.length > 35 ? msg.substring(0, 35) : msg}..."',
        () async {
          await _setUp();
          final service = LocalAgentService(
            repository: _repository,
            runtime: const UnavailableGemmaRuntime(),
            nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
          );
          final reply = await service.ask(msg);
          expect(reply.message, isNotEmpty);
          expect(reply.message, isNot(contains('Gemma 4 is loading')));
          await _tearDown();
        },
      );
    }
  });

  // =========================================================================
  // Diet question routing
  // =========================================================================
  group('Diet question routing', () {
    const dietQuestions = [
      'should I avoid dairy?',
      'can I eat spicy food?',
      'is gluten bad for crohns?',
      'what about alcohol and IBD?',
      'should I drink coffee?',
      'is fiber good or bad?',
      'can I eat a normal diet?',
      'what food triggers a flare?',
    ];

    for (final q in dietQuestions) {
      test('diet: "$q"', () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(q);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Out-of-scope question routing
  // =========================================================================
  group('Out-of-scope routing', () {
    const outOfScope = [
      'what is the weather today?',
      'tell me a joke',
      'who is the president?',
      'translate hello to spanish',
      'write me a poem',
      'what is the capital of france?',
    ];

    for (final q in outOfScope) {
      test('out-of-scope: "$q"', () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(q);
        expect(reply.message, isNotEmpty);
        // Should not give health data for out-of-scope questions
        expect(reply.message, isNot(contains('48/100')));
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Data gap question routing
  // =========================================================================
  group('Data gap routing', () {
    const dataGapQuestions = [
      'why is my data missing?',
      'my watch is not syncing',
      'where is my data?',
      'I have no data today',
      'apple watch not connected',
    ];

    for (final q in dataGapQuestions) {
      test('data gap: "$q"', () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(q);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Lab question routing
  // =========================================================================
  group('Lab question routing', () {
    const labQuestions = [
      'what does my CRP mean?',
      'is my ESR too high?',
      'tell me about calprotectin',
      'my blood work came back',
      'what is my ferritin level?',
      'hemoglobin is low',
      'albumin results',
      'vitamin B12 deficiency?',
    ];

    for (final q in labQuestions) {
      test('lab: "$q"', () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(q);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }

    test('explains latest saved labs instead of asking for upload', () async {
      await _setUp();
      await _repository.upsertLabValue(_lab());
      await _repository.upsertLabValue(
        _lab(
          labType: 'hemoglobin',
          value: 11.8,
          unit: 'g/dL',
          referenceHigh: null,
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      final reply = await service.ask('what did my labs show?');

      expect(reply.status, 'deterministic_lab_summary');
      expect(reply.toolTraceJson['chat_path'], 'latest_lab_summary');
      expect(reply.message.toLowerCase(), contains('latest saved labs'));
      expect(reply.message, contains('CRP'));
      expect(reply.message, contains('12.4 mg/L'));
      expect(reply.message, contains('Hemoglobin'));
      expect(reply.message.toLowerCase(), isNot(contains('paste the values')));
      await _tearDown();
    });

    test('answers latest CRP from saved labs', () async {
      await _setUp();
      await _repository.upsertLabValue(
        _lab(drawnDate: '2026-04-18', labType: 'crp', value: 4.2),
      );
      await _repository.upsertLabValue(
        _lab(drawnDate: '2026-04-20', labType: 'crp', value: 13),
      );
      await _repository.upsertLabValue(
        _lab(
          drawnDate: '2026-04-20',
          labType: 'albumin',
          value: 3.2,
          unit: 'g/dL',
          referenceHigh: null,
        ),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      final reply = await service.ask('what was my last CRP?');

      expect(reply.status, 'deterministic_lab_summary');
      expect(reply.message, contains('CRP'));
      expect(reply.message, contains('13 mg/L'));
      expect(reply.message, isNot(contains('Albumin')));
      await _tearDown();
    });

    test(
      'mentions local memory when lab RAG transaction is verified',
      () async {
        await _setUp();
        await _repository.upsertLabValue(_lab());
        await _repository.upsertRagMemoryTransaction(
          RagMemoryTransactionRecord(
            transactionId: 'lab_tx_1',
            sourceType: 'lab_value',
            sourceId: '1',
            chunkId: 'lab_value_1',
            status: 'verified',
            textHash: 'hash',
            createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
            indexedAt: DateTime.parse('2026-04-20T08:01:00Z'),
            verifiedAt: DateTime.parse('2026-04-20T08:02:00Z'),
          ),
        );
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );

        final reply = await service.ask('what did my labs show?');

        expect(reply.status, 'deterministic_lab_summary');
        expect(reply.message, contains('CRP'));
        expect(
          reply.message.toLowerCase(),
          contains('local gemma_flares memory'),
        );
        await _tearDown();
      },
    );

    test('lab explanation without saved labs keeps intake prompt', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      final reply = await service.ask('what were my lab results?');

      expect(reply.toolTraceJson['agent_intent'], 'lab_question');
      expect(reply.message.toLowerCase(), contains('paste the values'));
      expect(reply.message.toLowerCase(), contains('attach'));
      await _tearDown();
    });

    test(
      'lab explanation with pending review explains unsaved state',
      () async {
        await _setUp();
        await _repository.insertGemmaExtractionReview(
          GemmaExtractionReviewRecord(
            reviewType: 'lab_text_extract',
            sourceKind: 'lab_report_text',
            extractedJson: const {
              'labs': [
                {
                  'lab_type': 'crp',
                  'value_numeric': 89.5,
                  'unit': 'mg/L',
                  'drawn_date': '2026-05-07',
                },
              ],
            },
            userConfirmedJson: const {},
            reviewStatus: 'pending_user_confirm',
            createdAt: DateTime.parse('2026-05-07T08:00:00Z'),
          ),
        );
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
        );

        final reply = await service.ask('Explain my labs');

        expect(reply.status, 'deterministic_pending_lab_review');
        expect(reply.toolTraceJson['chat_path'], 'pending_lab_review_recall');
        expect(
          reply.message.toLowerCase(),
          contains('waiting for your confirmation'),
        );
        expect(reply.message.toLowerCase(), contains('not saved yet'));
        expect(reply.message.toLowerCase(), contains('reply "confirm"'));
        expect(reply.message, contains('89.5'));
        await _tearDown();
      },
    );

    test('new lab values still route to lab review', () async {
      await _setUp();
      final gemmaTaskService = GemmaTaskService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        gemmaTaskService: gemmaTaskService,
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      final reply = await service.ask('CRP 12 mg/L today');

      expect(reply.status, 'lab_review_pending');
      expect(reply.toolTraceJson['pending_action_type'], 'lab_review');
      expect(reply.message.toLowerCase(), contains('review them first'));
      await _tearDown();
    });

    test('start check-in returns structured intake prompt', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('generic model text'),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('Start a check-in');

      expect(reply.status, 'deterministic_action_prompt');
      expect(reply.toolTraceJson['chat_path'], 'action_intake_prompt');
      expect(reply.message.toLowerCase(), contains('belly pain'));
      expect(reply.message.toLowerCase(), contains('review card'));
      expect(
        reply.message.toLowerCase(),
        isNot(contains('provide your health data')),
      );
      await _tearDown();
    });

    test('prints saved symptoms from local rows', () async {
      await _setUp();
      await _repository.insertSymptom(_symptom(type: 'bloating', severity: 4));
      await _repository.insertSymptom(_symptom(type: 'abdominal_pain'));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('generic model text'),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('print all my symotoms');

      expect(reply.status, 'deterministic_symptom_list');
      expect(reply.toolTraceJson['chat_path'], 'saved_symptom_list');
      expect(reply.message.toLowerCase(), contains('saved symptoms'));
      expect(reply.message.toLowerCase(), contains('bloating'));
      expect(reply.message.toLowerCase(), contains('abdominal_pain'));
      await _tearDown();
    });

    test('contract trace proves health summary hydration', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      await _repository.insertSymptom(_symptom(type: 'bloating', severity: 4));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('summary of my health data');

      expect(reply.toolTraceJson['task_contract'], 'healthSummary');
      expect(
        reply.toolTraceJson['contract_route'],
        'structured_health_summary',
      );
      expect(
        reply.toolTraceJson['tools_called'],
        containsAll([
          'get_health_summary_context',
          'get_today_risk_snapshot',
          'get_recent_symptoms',
        ]),
      );
      expect(
        reply.toolTraceJson['structured_sources_used'],
        containsAll(['flare_risk_scores', 'symptoms']),
      );
      expect(reply.toolTraceJson['rag_query_performed'], isFalse);
      await _tearDown();
    });

    test(
      'apple watch review uses local wearable context when present',
      () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        await _repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: '2026-05-07',
            summaryJson: const {
              'sleep_total_minutes': 420,
              'step_count_total': 8300,
              'resting_hr_mean': 64,
              'hrv_sdnn_mean': 41.5,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-05-07T08:00:00Z'),
          ),
        );
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime('generic model text'),
          nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
        );

        final reply = await service.ask('review my Apple Watch data');

        expect(reply.status, 'deterministic_apple_watch_review');
        expect(reply.toolTraceJson['task_contract'], 'appleWatchReview');
        expect(reply.toolTraceJson['chat_path'], 'apple_watch_review');
        expect(reply.message.toLowerCase(), contains('apple watch-derived'));
        expect(reply.message.toLowerCase(), contains('8300 steps'));
        expect(
          reply.message.toLowerCase(),
          isNot(contains('provide your data')),
        );
        await _tearDown();
      },
    );

    test(
      'apple watch review says data is missing when no rows exist',
      () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime('I reviewed your watch data'),
          nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
        );

        final reply = await service.ask('review my Apple Watch data');

        expect(reply.status, 'deterministic_apple_watch_review');
        expect(reply.toolTraceJson['task_contract'], 'appleWatchReview');
        expect(reply.message.toLowerCase(), contains('do not have local'));
        expect(reply.message.toLowerCase(), isNot(contains('i reviewed')));
        await _tearDown();
      },
    );

    test('basic crohns education routes to IBD knowledge', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('generic model text'),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('tell me more about Crohns');

      expect(reply.status, 'deterministic_ibd_knowledge');
      expect(reply.toolTraceJson['task_contract'], 'ibdKnowledge');
      expect(reply.toolTraceJson['chat_path'], 'ibd_knowledge');
      expect(reply.message.toLowerCase(), contains('inflammatory bowel'));
      expect(reply.message.toLowerCase(), contains('general ibd education'));
      await _tearDown();
    });

    test('colitis education does not claim personal diagnosis', () async {
      await _setUp();
      final service = LocalAgentService(
        repository: _repository,
        runtime: const _FakeSuccessRuntime('you have colitis'),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('tell me more about colities');

      expect(reply.status, 'deterministic_ibd_knowledge');
      expect(reply.message.toLowerCase(), contains('ulcerative colitis'));
      expect(reply.message.toLowerCase(), isNot(contains('you have colitis')));
      await _tearDown();
    });

    test(
      'rejects model claim that memory was used without RAG retrieval',
      () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const _FakeSuccessRuntime(
            'I found in memory that your symptoms were worse yesterday.',
          ),
          nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
        );

        final reply = await service.ask('how am I doing?');

        expect(reply.status, 'fallback_invalid_model_output');
        expect(
          reply.toolTraceJson['response_grounding_status'],
          'rejected_unsupported_claim',
        );
        expect(
          reply.toolTraceJson['rejection_reason'],
          'unsupported_memory_access_claim',
        );
        expect(reply.message.toLowerCase(), isNot(contains('found in memory')));
        await _tearDown();
      },
    );

    test('contract tool results expose row counts and sources', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      await _repository.insertSymptom(_symptom(type: 'bloating', severity: 4));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-05-07T08:00:00Z'),
      );

      final reply = await service.ask('how am I doing?');
      final results = reply.toolTraceJson['tool_contract_results'] as List;

      expect(results, isNotEmpty);
      expect(results.first['tool_name'], 'get_health_summary_context');
      expect(results.first['row_count'], greaterThan(0));
      expect(results.first['source_tables'], contains('flare_risk_scores'));
      expect(reply.toolTraceJson['response_grounding_status'], isNotNull);
      await _tearDown();
    });
  });

  // =========================================================================
  // Model output sanitization for Crohn's-specific claims
  // =========================================================================
  group('Model sanitization for Crohn claims', () {
    const unsafeCrohnOutputs = [
      'you have a fistula near your rectum',
      'you have a stricture in your ileum',
      'you have an abscess that needs draining',
      'you need a colonoscopy immediately',
      'you should stop your biologic medication',
      'you have colon cancer based on this data',
      'you have a blood clot in your leg',
    ];

    for (final output in unsafeCrohnOutputs) {
      test(
        'rejects unsafe: "${output.length > 40 ? output.substring(0, 40) : output}..."',
        () async {
          await _setUp();
          final service = LocalAgentService(
            repository: _repository,
            runtime: _FakeSuccessRuntime(output),
            nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
          );
          final reply = await service.ask('What does my data show?');
          expect(reply.status, 'fallback_invalid_model_output');
          expect(reply.toolTraceJson['output_quality_status'], 'rejected');
          expect(reply.message, isNot(contains(output)));
          await _tearDown();
        },
      );
    }
  });

  // =========================================================================
  // Safe model outputs pass through
  // =========================================================================
  group('Safe Crohn-related model outputs pass through', () {
    const safeCrohnOutputs = [
      'Your recent patterns show some changes worth monitoring.',
      'Your HRV has been lower than your baseline this week.',
      'You logged 3 symptoms in the last 48 hours.',
      'Your sleep has decreased compared to last week.',
      'Consider discussing these patterns with your GI team.',
    ];

    for (final output in safeCrohnOutputs) {
      test(
        'accepts safe: "${output.length > 40 ? output.substring(0, 40) : output}..."',
        () async {
          await _setUp();
          final service = LocalAgentService(
            repository: _repository,
            runtime: _FakeSuccessRuntime(output),
            nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
          );
          final reply = await service.ask('How am I doing?');
          expect(reply.status, 'success');
          expect(reply.message, contains(output.substring(0, 20)));
          await _tearDown();
        },
      );
    }
  });

  // =========================================================================
  // Week summary routing
  // =========================================================================
  group('Week summary routing', () {
    const weekQuestions = [
      'summarize my week',
      'give me an overview',
      'what are my recent trends?',
      'catch me up',
      'what have I missed?',
    ];

    for (final q in weekQuestions) {
      test('week summary: "$q"', () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(q);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Multiple symptoms in one session
  // =========================================================================
  group('Multiple symptoms in session', () {
    test('reports correct count with various Crohn symptoms', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      await _repository.insertSymptom(
        _symptom(type: 'abdominal_pain', severity: 7),
      );
      await _repository.insertSymptom(_symptom(type: 'diarrhea', severity: 5));
      await _repository.insertSymptom(_symptom(type: 'nausea', severity: 3));
      await _repository.insertSymptom(_symptom(type: 'fatigue', severity: 6));
      await _repository.insertSymptom(_symptom(type: 'bleeding', severity: 4));
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('Tell me about my symptoms');
      expect(reply.message, contains('5 recent symptom'));
      expect(reply.message, contains('48/100'));
      await _tearDown();
    });
  });

  // =========================================================================
  // Confidence question routing
  // =========================================================================
  group('Confidence question routing', () {
    test('explains confidence when asked', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('How is the confidence calculated?');
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });

    test('data quality question routes correctly', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask('What about data quality?');
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // =========================================================================
  // Followup intents
  // =========================================================================
  group('Followup intents', () {
    test('correction intent detected', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      await service.ask('What is my risk?');
      final reply = await service.ask('that\'s not right');
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });

    test('expand intent detected', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      await service.ask('What is my risk?');
      final reply = await service.ask('tell me more');
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });

    test('compare intent detected', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      await service.ask('What is my risk?');
      final reply = await service.ask('what changed compared with yesterday?');
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // =========================================================================
  // Greeting variations
  // =========================================================================
  group('Greeting variations', () {
    const greetings = [
      'hi',
      'hello',
      'hey',
      'yo',
      'good morning',
      'good evening',
      'hiya',
      'howdy',
      'sup',
      'greetings',
      'hola',
      'namaste',
    ];

    for (final g in greetings) {
      test('greeting "$g" gets friendly reply', () async {
        await _setUp();
        await _repository.upsertFlareRiskScore(_score());
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        final reply = await service.ask(g);
        expect(reply.message, startsWith('Hi!'));
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });

  // =========================================================================
  // Doctor summary request
  // =========================================================================
  group('Doctor summary request', () {
    test('doctor summary request detected', () async {
      await _setUp();
      await _repository.upsertFlareRiskScore(_score());
      final service = LocalAgentService(
        repository: _repository,
        runtime: const UnavailableGemmaRuntime(),
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );
      final reply = await service.ask(
        'Prepare a GI summary report for my doctor visit',
      );
      expect(reply.message, isNotEmpty);
      expect(reply.message, isNot(contains('Gemma 4 is loading')));
      await _tearDown();
    });
  });

  // =========================================================================
  // Explicit symptom log request
  // =========================================================================
  group('Explicit symptom log requests', () {
    const logRequests = [
      'log that',
      'log this',
      'save that symptom',
      'record that symptom',
      'save this symptom',
    ];

    for (final req in logRequests) {
      test('recognizes log request: "$req"', () async {
        await _setUp();
        final service = LocalAgentService(
          repository: _repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
        );
        // First say a symptom, then log it
        await service.ask('I have bad cramping');
        final reply = await service.ask(req);
        expect(reply.message, isNotEmpty);
        expect(reply.message, isNot(contains('Gemma 4 is loading')));
        await _tearDown();
      });
    }
  });
}
