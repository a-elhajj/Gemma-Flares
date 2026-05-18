@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/features/chat/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AutonomousUiReport report;
  late void Function(FlutterErrorDetails details)? originalOnError;

  setUp(() {
    AppServices.configureForTesting(
      localModelRuntimeOverride: _FakeLocalModelRuntime(),
      repositoryOverride: _FakeWearableSampleRepository(),
    );
    originalOnError = FlutterError.onError;
    report = _AutonomousUiReport(
      startedAt: DateTime.now().toUtc(),
      scenarioName: 'chat_ui_agent',
    );

    FlutterError.onError = (details) {
      report.errors.add(
        _AutonomousUiError(
          source: 'flutter_error',
          message: details.exceptionAsString(),
          stack: details.stack?.toString(),
        ),
      );
      originalOnError?.call(details);
    };

    AppServices.localAgentService = _ScriptedLocalAgentService();
  });

  tearDown(() async {
    FlutterError.onError = originalOnError;
    AppServices.resetToDefaults();
  });

  testWidgets('autonomous chat UI agent writes interaction report', (
    tester,
  ) async {
    await _runStep(report, 'boot_chat_screen', () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const Scaffold(body: ChatScreen()),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Try asking:'), findsOneWidget);
      expect(find.text('Daily check-in'), findsWidgets);
    });

    await _tapPromptAndExpectReply(
      tester: tester,
      report: report,
      label: 'Daily check-in',
      expectedText: 'check-in',
    );
    await _tapPromptAndExpectReply(
      tester: tester,
      report: report,
      label: 'Why higher?',
      expectedText: 'risk',
    );
    await _tapPromptAndExpectReply(
      tester: tester,
      report: report,
      label: 'GI summary',
      expectedText: 'GI summary',
    );

    await _runStep(report, 'type_custom_lab_question', () async {
      await tester.enterText(
        find.byType(TextField).last,
        'I have lab results: CRP 12 mg/L and hemoglobin 11.8 g/dL.',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await _pumpUntilText(tester, 'lab review');
    });

    _writeReport(report..endedAt = DateTime.now().toUtc());

    expect(report.errors, isEmpty, reason: report.markdown());
    expect(
      report.steps.where((step) => step.status == 'failed'),
      isEmpty,
      reason: report.markdown(),
    );
  });
}

Future<void> _tapPromptAndExpectReply({
  required WidgetTester tester,
  required _AutonomousUiReport report,
  required String label,
  required String expectedText,
}) async {
  await _runStep(report, 'tap_${_slug(label)}', () async {
    final finder = find.text(label);
    expect(finder, findsWidgets);
    await tester.tap(finder.last);
    await _pumpUntilText(tester, expectedText);
  });
}

Future<void> _runStep(
  _AutonomousUiReport report,
  String name,
  Future<void> Function() body,
) async {
  final started = DateTime.now().toUtc();
  try {
    await body();
    report.steps.add(
      _AutonomousUiStep(
        name: name,
        status: 'passed',
        startedAt: started,
        endedAt: DateTime.now().toUtc(),
      ),
    );
  } catch (error, stackTrace) {
    report.steps.add(
      _AutonomousUiStep(
        name: name,
        status: 'failed',
        startedAt: started,
        endedAt: DateTime.now().toUtc(),
        error: error.toString(),
        stack: stackTrace.toString(),
      ),
    );
    report.errors.add(
      _AutonomousUiError(
        source: name,
        message: error.toString(),
        stack: stackTrace.toString(),
      ),
    );
  }
}

Future<void> _pumpUntilText(
  WidgetTester tester,
  String text, {
  int maxPumps = 80,
}) async {
  final lowerText = text.toLowerCase();
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    final found = find.byWidgetPredicate((widget) {
      return widget is Text &&
          (widget.data ?? '').toLowerCase().contains(lowerText);
    });
    if (found.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for text containing "$text"');
}

void _writeReport(_AutonomousUiReport report) {
  final outDir = Directory('tooling/autonomous_ui/out')
    ..createSync(recursive: true);
  final jsonFile = File('${outDir.path}/app_functionality_report.json');
  final mdFile = File('${outDir.path}/app_functionality_report.md');
  jsonFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report.toJson()),
  );
  mdFile.writeAsStringSync(report.markdown());
}

String _slug(String input) {
  return input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}

class _AutonomousUiReport {
  _AutonomousUiReport({required this.startedAt, required this.scenarioName});

  final DateTime startedAt;
  final String scenarioName;
  DateTime? endedAt;
  final steps = <_AutonomousUiStep>[];
  final errors = <_AutonomousUiError>[];

  Map<String, Object?> toJson() {
    return {
      'scenario_name': scenarioName,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'status': errors.isEmpty && steps.every((step) => step.status == 'passed')
          ? 'passed'
          : 'failed',
      'step_count': steps.length,
      'error_count': errors.length,
      'steps': steps.map((step) => step.toJson()).toList(growable: false),
      'errors': errors.map((error) => error.toJson()).toList(growable: false),
    };
  }

  String markdown() {
    final buffer = StringBuffer()
      ..writeln('# Autonomous UI App Functionality Report')
      ..writeln()
      ..writeln('- scenario: `$scenarioName`')
      ..writeln('- status: `${toJson()['status']}`')
      ..writeln('- started_at: `${startedAt.toIso8601String()}`')
      ..writeln('- ended_at: `${endedAt?.toIso8601String() ?? 'not_finished'}`')
      ..writeln('- steps: `${steps.length}`')
      ..writeln('- errors: `${errors.length}`')
      ..writeln()
      ..writeln('## Steps')
      ..writeln();
    for (final step in steps) {
      buffer
        ..writeln('- `${step.status}` `${step.name}` (${step.durationMs}ms)')
        ..writeln(step.error == null ? '' : '  - error: ${step.error}');
    }
    buffer
      ..writeln()
      ..writeln('## Errors')
      ..writeln();
    if (errors.isEmpty) {
      buffer.writeln('No errors captured.');
    } else {
      for (final error in errors) {
        buffer
          ..writeln('- source: `${error.source}`')
          ..writeln('  - message: ${error.message}')
          ..writeln('  - stack:')
          ..writeln('```')
          ..writeln(error.stack ?? '')
          ..writeln('```');
      }
    }
    return buffer.toString();
  }
}

class _AutonomousUiStep {
  const _AutonomousUiStep({
    required this.name,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    this.error,
    this.stack,
  });

  final String name;
  final String status;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? error;
  final String? stack;

  int get durationMs => endedAt.difference(startedAt).inMilliseconds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'status': status,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'duration_ms': durationMs,
      if (error != null) 'error': error,
      if (stack != null) 'stack': stack,
    };
  }
}

class _AutonomousUiError {
  const _AutonomousUiError({
    required this.source,
    required this.message,
    this.stack,
  });

  final String source;
  final String message;
  final String? stack;

  Map<String, Object?> toJson() {
    return {
      'source': source,
      'message': message,
      if (stack != null) 'stack': stack,
    };
  }
}

class _FakeWearableSampleRepository extends WearableSampleRepository {
  _FakeWearableSampleRepository() : super(database: AppDatabase());

  @override
  Future<List<ConversationRecord>> getRecentConversations({int? limit}) async {
    return const [];
  }

  @override
  Future<int> insertConversation(ConversationRecord record) async => 1;
}

class _FakeLocalModelRuntime implements LocalModelRuntime {
  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText: 'OK',
      runtimeName: 'autonomous-ui-fake-runtime',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'loaded',
      runtimeName: 'autonomous-ui-fake-runtime',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'Ready.',
      backendRequested: 'cpu',
      backendUsed: 'litert-lm',
      contextWindow: 4096,
      activeRuntimeProfile: 'phone_balanced',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return getRuntimeStatus();
  }
}

class _ScriptedLocalAgentService extends LocalAgentService {
  _ScriptedLocalAgentService()
      : super(
          repository: _FakeWearableSampleRepository(),
          runtime: _FakeLocalModelRuntime(),
        );

  @override
  Future<LocalAgentReply> ask(String userMessage) async {
    final lower = userMessage.toLowerCase();
    final message = lower.contains('lab') || lower.contains('crp')
        ? 'I see lab review context. I will stage results for review before anything is saved.'
        : lower.contains('summary') || lower.contains('gi')
            ? 'Here is a GI summary draft based on local records.'
            : lower.contains('risk') || lower.contains('higher')
                ? 'Your risk explanation is grounded in recent local signals.'
                : 'Starting check-in. First question: how is your gut today?';
    return LocalAgentReply(
      status: 'success',
      message: message,
      runtimeName: 'autonomous-ui-scripted-agent',
      toolTraceJson: const {
        'used_model_output': false,
        'agent_intent': 'autonomous_ui_smoke',
      },
      groundedSummaryJson: const {},
    );
  }

  @override
  Future<void> resetSession({String reason = 'manual'}) async {}
}
