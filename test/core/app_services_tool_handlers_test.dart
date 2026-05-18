import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/lab_risk_contribution_service.dart';
import 'package:gemma_flares/core/services/score_stability_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_tools_');
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    AppServices.configureForTesting(
      databaseOverride: database,
      repositoryOverride: repository,
      localModelRuntimeOverride: _ToolCallRuntime(),
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
    AppServices.resetToDefaults();
  });

  test('ingest_lab_panel tool stages labs for review before saving', () async {
    final result = await AppServices.gemmaToolDispatchService.sendAndDispatch(
      userMessage: 'OCR found CRP 12.4 mg/L on 2026-05-06.',
      assembledContext: 'local lab OCR context',
      restrictToTools: const ['ingest_lab_panel'],
    );

    expect(result, isNotNull);
    expect(result!.toolName, 'ingest_lab_panel');
    expect(result.handlerResult, isA<Map>());
    final handlerResult = Map<String, Object?>.from(
      result.handlerResult! as Map,
    );
    expect(handlerResult['status'], 'pending_review');
    expect(handlerResult['saved_count'], 0);
    expect(handlerResult['requires_confirmation'], isTrue);

    final labs = await repository.getLabValues();
    expect(labs, isEmpty);

    final auditRows = await AppServices.toolAuditService.latest(limit: 5);
    expect(
      auditRows.any(
        (row) => row['result_json'].toString().contains('pending_review'),
      ),
      isTrue,
    );
  });

  test('risk extension services are registered and injectable', () {
    expect(
      AppServices.labRiskContributionService,
      isA<LabRiskContributionService>(),
    );
    expect(AppServices.scoreStabilityGate, isA<ScoreStabilityGate>());
    expect(AppServices.riskEngineService, isNotNull);
  });
}

class _ToolCallRuntime implements LocalModelRuntime {
  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText:
          '{"name":"ingest_lab_panel","arguments":{"source":"photo_ocr","results":[{"analyte_canonical_id":"crp","value_numeric":12.4,"unit":"mg/L","drawn_date":"2026-05-06","reference_high":5,"confidence":0.91}]}}',
      runtimeName: 'fake-tool-runtime',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => _status();

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _status();

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
    String? backendId,
  ) async =>
      _status();
}

LocalModelRuntimeStatus _status() {
  return const LocalModelRuntimeStatus(
    status: 'ready',
    runtimeName: 'fake-tool-runtime',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b',
    quantization: 'q4',
    expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
    isBackendLinked: true,
    isBundledModelPresent: true,
    isModelLoaded: true,
    reason: 'ready',
  );
}
