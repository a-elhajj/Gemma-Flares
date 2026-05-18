import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/gemma_task_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'Copilot review: fallback doctor summary is spaced and non-indented',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-16',
          diseaseType: 'UC',
          ucRectalBleeding: 1,
          ucStoolFrequency: 2,
          pro2Score: 3,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'rectal_bleeding_0_3': 1,
              'bathroom_frequency_0_3': 2,
            },
            completedSections: const ['core'],
          ),
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);
      _copilotReviewDoctorSummaryOutput(result.summaryText);
      await harness.dispose();
    },
  );

  test(
    'Copilot review: sparse context renders explicit "No … recorded yet"',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      final result = await harness.service.createDoctorSummary(days: 30);

      _copilotReviewDoctorSummaryOutput(result.summaryText);
      expect(result.summaryText, contains('No saved symptom'));
      expect(result.summaryText, contains('No saved lab'));
      expect(result.summaryText, contains('No saved check-in'));

      await harness.dispose();
    },
  );

  test(
    'Copilot review: messy model output is normalized (indent + bullets)',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText: '''
  ## Overview
    - Current Gemma Flares risk score: 44/100 — MODERATE.

  ## Lab Results
    * labs look ok

  ## Check-in Summary
    1. bleeding 1/3
    2. urgency 2/3
''',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-16',
          riskScore: 44,
          riskBand: 'moderate',
          confidenceScore: 80,
          contributionJson: const {'symptom_points': 12},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);
      _copilotReviewDoctorSummaryOutput(result.summaryText);
      await harness.dispose();
    },
  );

  test(
    'Copilot review: labs present -> output includes lab name + value',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText:
                  '## Overview\nAll good.\n\n## Lab Results\nNo details.',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      await harness.repository.upsertLabValue(
        LabValueRecord(
          drawnDate: '2026-04-10',
          labType: 'crp',
          labName: 'CRP',
          valueNumeric: 12.0,
          unit: 'mg/L',
          referenceHigh: 5.0,
          createdAt: DateTime.parse('2026-04-10T08:00:00Z'),
          updatedAt: DateTime.parse('2026-04-10T08:00:00Z'),
        ),
      );
      await harness.repository.upsertLabValue(
        LabValueRecord(
          drawnDate: '2026-04-12',
          labType: 'fc',
          labName: 'Fecal Calprotectin',
          valueNumeric: 320.0,
          unit: 'μg/g',
          referenceHigh: 50.0,
          createdAt: DateTime.parse('2026-04-12T08:00:00Z'),
          updatedAt: DateTime.parse('2026-04-12T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);
      _copilotReviewDoctorSummaryOutput(
        result.summaryText,
        expectedLabs: const [('CRP', '12.0'), ('Fecal Calprotectin', '320.0')],
      );
      await harness.dispose();
    },
  );

  test('Copilot review: numbered list markers are removed', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: '''
## Overview
1) First line
2. Second line
''',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    expect(result.summaryText, isNot(contains('1) ')));
    expect(result.summaryText, isNot(contains('2. ')));
    await harness.dispose();
  });

  test('Copilot review: tabs and leading spaces are removed', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText:
                '## Overview\n\t\t- Indented\n\n## Lab Results\n\tCRP 12',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    for (final line in result.summaryText.split('\n')) {
      expect(line.startsWith('\t'), isFalse);
      expect(line.startsWith(' '), isFalse);
    }
    await harness.dispose();
  });

  test('Copilot review: high-concern safety guard remains formatted', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: '## Overview\nCurrent Gemma Flares risk score: 29/100.',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    await harness.repository.insertPro2Survey(
      Pro2SurveyRecord(
        surveyDate: '2026-04-16',
        diseaseType: 'UC',
        ucRectalBleeding: 2,
        ucStoolFrequency: 3,
        pro2Score: 5,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
        notes: IbdCheckInService.encodeNotes(
          diseaseType: 'UC',
          dailyCore: const {
            'abdominal_pain': 3,
            'stool_frequency': 3,
            'rectal_bleeding': 2,
            'general_wellbeing': 2,
            'urgency': 3,
          },
          completedSections: const ['core'],
          source: 'gemma_chat_checkin',
        ),
        createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 7);
    expect(result.summaryText, startsWith('## Clinical Safety Priority'));
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    await harness.dispose();
  });

  test('Copilot review: no triple blank lines appear', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: '## Overview\n\n\nToo many blanks',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    expect(result.summaryText, isNot(contains('\n\n\n')));
    await harness.dispose();
  });

  test('Copilot review: duplicate headings are de-duplicated', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: '''
## Overview
First.

## Overview
Second.

## Lab Results
None.
''',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    expect('## Overview'.allMatches(result.summaryText).length, 1);
    await harness.dispose();
  });

  test('Copilot review: code fence markers are removed', () async {
    final harness = await _Harness.create(
      runtime: _FakeRuntime(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: '```markdown\n## Overview\nAll good.\n```\n',
            runtimeName: 'test-gemma',
          ),
        ],
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);
    _copilotReviewDoctorSummaryOutput(result.summaryText);
    expect(result.summaryText, isNot(contains('```')));
    await harness.dispose();
  });

  test('Copilot review: fuzz corpus (150) passes formatting gates', () async {
    final random = math.Random(1337);
    final responses = List<LocalModelResponse>.generate(150, (index) {
      final indent = List.filled(random.nextInt(4), ' ').join();
      final bullet = switch (random.nextInt(4)) {
        0 => '- ',
        1 => '* ',
        2 => '1. ',
        _ => '• ',
      };
      final maybeMissingLabs = random.nextBool();
      final extraBlanks = random.nextInt(3) == 0 ? '\n\n\n' : '\n\n';
      final labsSection = maybeMissingLabs
          ? ''
          : '## Lab Results\n$indent${bullet}CRP is elevated\n';
      return LocalModelResponse(
        status: 'success',
        runtimeName: 'test-gemma',
        outputText: '''
$indent## Overview
$indent${bullet}Current Gemma Flares risk score: 44/100 — MODERATE.$extraBlanks
$indent## GI Activity & Symptoms
$indent${bullet}Bloating noted.$extraBlanks
$labsSection
$indent## Check-in Summary
$indent${bullet}bleeding 1/3
''',
      );
    });

    final harness = await _Harness.create(
      runtime: _FakeRuntime(responses: responses),
    );

    await harness.repository.upsertLabValue(
      LabValueRecord(
        drawnDate: '2026-04-12',
        labType: 'crp',
        labName: 'CRP',
        valueNumeric: 12.0,
        unit: 'mg/L',
        referenceHigh: 5.0,
        createdAt: DateTime.parse('2026-04-12T08:00:00Z'),
        updatedAt: DateTime.parse('2026-04-12T08:00:00Z'),
      ),
    );

    for (var i = 0; i < 150; i += 1) {
      final result = await harness.service.createDoctorSummary(days: 30);
      _copilotReviewDoctorSummaryOutput(
        result.summaryText,
        expectedLabs: const [('CRP', '12.0')],
      );
    }
    await harness.dispose();
  });
}

void _copilotReviewDoctorSummaryOutput(
  String summary, {
  List<(String, String)> expectedLabs = const [],
}) {
  final text = summary.trim();
  expect(text, isNotEmpty);
  expect(text, equals(summary));
  expect(text, isNot(contains('\n\n\n')));
  expect(text, isNot(contains('```')));
  expect(text.toLowerCase(), isNot(contains('risk score')));
  expect(RegExp(r'\b\d{1,3}\s*/\s*100\b').hasMatch(text), isFalse);

  const required = <String>[
    'Overview',
    'GI Activity Summary',
    'Lab Results',
    'Check-in Summary',
    'Medication and Supplement Log',
    'Bowel Pattern Baseline',
    'Condensed Diet and Trigger Log',
    'Questions for Your GI Doctor',
    'Triage and Red Flags',
  ];

  var lastIndex = -1;
  for (final heading in required) {
    final idx = text.indexOf('## $heading');
    expect(idx, greaterThan(-1), reason: 'Missing heading: $heading');
    expect(
      idx,
      greaterThan(lastIndex),
      reason: 'Heading order broke at: $heading',
    );
    lastIndex = idx;
  }

  final headingMatches = RegExp(
    r'^## (.+)$',
    multiLine: true,
  ).allMatches(text).toList();
  expect(headingMatches.length, greaterThanOrEqualTo(required.length));
  for (var i = 0; i < headingMatches.length; i += 1) {
    final match = headingMatches[i];
    if (match.start == 0) continue;
    expect(text.substring(match.start - 2, match.start), '\n\n');
  }

  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    expect(line.startsWith(' '), isFalse);
    expect(line.startsWith('\t'), isFalse);
    final trimmed = line.trimLeft();
    expect(RegExp(r'^[-*•]\s+').hasMatch(trimmed), isFalse);
    expect(RegExp(r'^\d{1,2}[.)]\s+').hasMatch(trimmed), isFalse);
  }

  for (var i = 0; i < required.length; i += 1) {
    final heading = required[i];
    final start = text.indexOf('## $heading');
    final headingLineEnd = text.indexOf('\n', start);
    final bodyStart = headingLineEnd == -1 ? text.length : headingLineEnd + 1;
    final nextStart = i + 1 < required.length
        ? text.indexOf('## ${required[i + 1]}', bodyStart)
        : text.length;
    final body = text.substring(bodyStart, nextStart).trim();
    expect(body, isNotEmpty, reason: 'Empty section: $heading');
  }

  for (final (labName, value) in expectedLabs) {
    expect(text, contains('$labName:'), reason: 'Missing lab name: $labName');
    expect(text, contains(value), reason: 'Missing lab value: $labName=$value');
  }
}

class _Harness {
  const _Harness({
    required this.tempRoot,
    required this.database,
    required this.repository,
    required this.service,
  });

  final Directory tempRoot;
  final AppDatabase database;
  final WearableSampleRepository repository;
  final GemmaTaskService service;

  static Future<_Harness> create({
    required LocalModelRuntime runtime,
    DateTime? now,
  }) async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_doctor_summary_review',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = GemmaTaskService(
      repository: repository,
      runtime: runtime,
      nowProvider: () => now ?? DateTime.parse('2026-04-16T08:00:00Z'),
    );
    return _Harness(
      tempRoot: tempRoot,
      database: database,
      repository: repository,
      service: service,
    );
  }

  Future<void> dispose() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }
}

class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime({required this.responses});

  final List<LocalModelResponse> responses;
  int generateCalls = 0;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'test-gemma',
      backendStyle: 'test',
      modelId: 'gemma-4-e2b',
      quantization: 'q4_0',
      expectedModelFilename: 'Models/litert-lm/test',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'ready',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) =>
      getRuntimeStatus();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    final index = generateCalls;
    generateCalls += 1;
    if (responses.isEmpty) {
      return const LocalModelResponse(
        status: 'unavailable',
        outputText: '',
        runtimeName: 'test-gemma',
        reason: 'no response queued',
      );
    }
    return responses[index.clamp(0, responses.length - 1)];
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}
