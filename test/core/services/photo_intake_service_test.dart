import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/lab_report_ocr_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/photo_intake_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.gemma_flares/lab_ocr');
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_photo_intake_',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await tempRoot.delete(recursive: true);
  });

  test('lab report photo requires confirmation and carries OCR text', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'recognizeTextAtPath');
      return {
        'status': 'ok',
        'text': 'Quest Diagnostics\nCRP 12.4 mg/L\nWBC 11.2\nReference range',
      };
    });
    final file = await File('${tempRoot.path}/lab.png').writeAsBytes([1, 2, 3]);
    final service = PhotoIntakeService(
      ocrService: LabReportOcrService(channel: channel),
      nowProvider: () => DateTime.utc(2026, 5, 6, 12),
    );

    final result = await service.inspectImagePath(file.path);

    expect(result.transactionId, startsWith('photo_tx_'));
    expect(result.kind, PhotoIntakeKind.labReport);
    expect(result.requiresConfirmation, isTrue);
    expect(result.ocrText, contains('CRP 12.4'));
    expect(result.userFacingSummary, contains('Review'));
  });

  test('vitamin result photo is treated as a lab report', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return {
        'status': 'ok',
        'text':
            'Vitamin D Test\n25-hydroxyvitamin D3 Result 29 nmol/L\nStatus mild to moderate deficiency',
      };
    });
    final file = await File('${tempRoot.path}/vitamin.png').writeAsBytes([1]);
    final service = PhotoIntakeService(
      ocrService: LabReportOcrService(channel: channel),
    );

    final result = await service.inspectImagePath(file.path);

    expect(result.kind, PhotoIntakeKind.labReport);
    expect(result.requiresConfirmation, isTrue);
    expect(result.userFacingSummary, contains('Review'));
  });

  test('CBC and chemistry photo is treated as a lab report', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return {
        'status': 'ok',
        'text':
            'CBC CMP Results\nHemoglobin 11.8 g/dL\nWBC 12.1\nPlatelets 455\nCreatinine 0.86 mg/dL\nALT 41 U/L',
      };
    });
    final file = await File('${tempRoot.path}/bloodwork.jpg').writeAsBytes([1]);
    final service = PhotoIntakeService(
      ocrService: LabReportOcrService(channel: channel),
    );

    final result = await service.inspectImagePath(file.path);

    expect(result.kind, PhotoIntakeKind.labReport);
    expect(result.requiresConfirmation, isTrue);
    expect(result.metadata['lab_signal_count'], isNonZero);
  });

  test(
    'pathology and colonoscopy OCR is treated as clinical lab report',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return {
          'status': 'ok',
          'text':
              'FINAL PATHOLOGIC DIAGNOSIS\nTerminal ileum biopsy: chronic active ileitis with erosion. No dysplasia or malignancy. Colonoscopy findings: erythema and ulceration.',
        };
      });
      final file = await File(
        '${tempRoot.path}/pathology.jpeg',
      ).writeAsBytes([1]);
      final service = PhotoIntakeService(
        ocrService: LabReportOcrService(channel: channel),
      );

      final result = await service.inspectImagePath(file.path);

      expect(result.kind, PhotoIntakeKind.labReport);
      expect(result.requiresConfirmation, isTrue);
      expect(result.metadata['clinical_record_signal_count'], isNonZero);
    },
  );

  test('unrelated image is not marked relevant or saveable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return {'status': 'ok', 'text': 'concert ticket seat 14 row B'};
    });
    final file = await File('${tempRoot.path}/ticket.jpg').writeAsBytes([1]);
    final service = PhotoIntakeService(
      ocrService: LabReportOcrService(channel: channel),
    );

    final result = await service.inspectImagePath(file.path);

    expect(result.kind, PhotoIntakeKind.unrelated);
    expect(result.requiresConfirmation, isFalse);
    expect(result.isRelevant, isFalse);
    expect(result.userFacingSummary, contains('did not save'));
  });

  test(
    'low-confidence OCR can use loaded Gemma classification fallback',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return {'status': 'ok', 'text': 'bottle label dose refill'};
      });
      final file = await File('${tempRoot.path}/label.heic').writeAsBytes([1]);
      final service = PhotoIntakeService(
        ocrService: LabReportOcrService(channel: channel),
        runtime: _FakeRuntime(loaded: true, output: 'medication_label'),
      );

      final result = await service.inspectImagePath(file.path);

      expect(result.kind, PhotoIntakeKind.medicationLabel);
      expect(result.requiresConfirmation, isTrue);
    },
  );

  test('rejects unsupported files before OCR', () async {
    final file = await File('${tempRoot.path}/notes.pdf').writeAsBytes([1]);
    final service = PhotoIntakeService(
      ocrService: LabReportOcrService(channel: channel),
    );

    final result = await service.inspectImagePath(file.path);

    expect(result.kind, PhotoIntakeKind.unknown);
    expect(result.requiresConfirmation, isFalse);
    expect(result.metadata['reason'], 'unsupported_type');
  });
}

class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime({required this.loaded, required this.output});

  final bool loaded;
  final String output;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return LocalModelResponse(
      status: 'ok',
      outputText: output,
      runtimeName: 'fake',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return _status(isModelLoaded: loaded);
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    return _status(isModelLoaded: true);
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return _status(isModelLoaded: loaded);
  }
}

LocalModelRuntimeStatus _status({required bool isModelLoaded}) {
  return LocalModelRuntimeStatus(
    status: 'ready',
    runtimeName: 'fake',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b',
    quantization: 'q4',
    expectedModelFilename: 'model.gguf',
    isBackendLinked: true,
    isBundledModelPresent: true,
    isModelLoaded: isModelLoaded,
    reason: 'test',
  );
}
