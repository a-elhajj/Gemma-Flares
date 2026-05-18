import 'dart:io';

import 'lab_report_ocr_service.dart';
import 'local_model_runtime.dart';

enum PhotoIntakeKind {
  labReport,
  food,
  medicationLabel,
  symptomPhoto,
  unrelated,
  unknown,
}

class PhotoIntakeResult {
  const PhotoIntakeResult({
    required this.transactionId,
    required this.kind,
    required this.confidence,
    this.ocrText,
    required this.userFacingSummary,
    required this.requiresConfirmation,
    this.metadata = const {},
  });

  final String transactionId;
  final PhotoIntakeKind kind;
  final double confidence;
  final String? ocrText;
  final String userFacingSummary;
  final bool requiresConfirmation;
  final Map<String, Object?> metadata;

  bool get isRelevant =>
      kind != PhotoIntakeKind.unrelated && kind != PhotoIntakeKind.unknown;
}

class PhotoIntakeService {
  PhotoIntakeService({
    required LabReportOcrService ocrService,
    LocalModelRuntime? runtime,
    DateTime Function()? nowProvider,
  })  : _ocrService = ocrService,
        _runtime = runtime,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const maxImageBytes = 12 * 1024 * 1024;

  final LabReportOcrService _ocrService;
  final LocalModelRuntime? _runtime;
  final DateTime Function() _nowProvider;

  Future<PhotoIntakeResult> inspectImagePath(String path) async {
    final tx = 'photo_tx_${_nowProvider().microsecondsSinceEpoch}';
    final file = File(path);
    if (!await file.exists()) {
      return _result(
        tx,
        PhotoIntakeKind.unknown,
        0,
        'I could not read that photo, so I did not save it.',
        requiresConfirmation: false,
        metadata: {'reason': 'file_missing'},
      );
    }
    final size = await file.length();
    final extension = path.split('.').last.toLowerCase();
    if (!const {'jpg', 'jpeg', 'png', 'heic', 'heif'}.contains(extension)) {
      return _result(
        tx,
        PhotoIntakeKind.unknown,
        0,
        'That file type is not supported for photo review, so I did not save it.',
        requiresConfirmation: false,
        metadata: {'reason': 'unsupported_type', 'extension': extension},
      );
    }
    if (size > maxImageBytes) {
      return _result(
        tx,
        PhotoIntakeKind.unknown,
        0,
        'That photo is too large to process safely on-device, so I did not save it.',
        requiresConfirmation: false,
        metadata: {'reason': 'image_too_large', 'bytes': size},
      );
    }

    final ocr = await _ocrService.recognizeTextAtPath(path);
    final ocrText = ocr.text.trim();
    final classified = _classifyFromText(tx, ocrText);
    if (classified.confidence >= 0.7 || _runtime == null) {
      return classified;
    }
    return _classifyWithGemmaFallback(classified, ocrText);
  }

  PhotoIntakeResult _classifyFromText(String tx, String text) {
    final lower = text.toLowerCase();
    if (text.isEmpty) {
      return _result(
        tx,
        PhotoIntakeKind.unknown,
        0.2,
        'I could not read useful text from that photo, so I did not save it.',
        requiresConfirmation: false,
        ocrText: text,
      );
    }
    final labHits = _labSignalCount(lower);
    final clinicalRecordHits = _clinicalRecordSignalCount(lower);
    final hasLabShape = _hasLabResultShape(lower);
    if (labHits >= 1 || clinicalRecordHits >= 1 || hasLabShape) {
      final confidence = labHits >= 4 || clinicalRecordHits >= 3
          ? 0.95
          : labHits >= 2 || clinicalRecordHits >= 2 || hasLabShape
              ? 0.86
              : 0.74;
      return _result(
        tx,
        PhotoIntakeKind.labReport,
        confidence,
        'This looks like a lab report. Review the extracted values before anything is saved.',
        requiresConfirmation: true,
        ocrText: text,
        metadata: {
          'lab_signal_count': labHits,
          'clinical_record_signal_count': clinicalRecordHits,
          'lab_shape_detected': hasLabShape,
          'ocr_status': 'classified_from_text',
        },
      );
    }
    final medHits = [
      'rx',
      'prescription',
      'tablet',
      'capsule',
      'mg',
      'dose',
      'take',
      'pharmacy',
      'refill',
      'prednisone',
      'mesalamine',
      'humira',
      'stelara',
      'entyvio',
      'rinvoq',
    ].where((term) => lower.contains(term)).length;
    if (medHits >= 2) {
      return _result(
        tx,
        PhotoIntakeKind.medicationLabel,
        0.78,
        'This looks medication-related. I can help turn it into a review card, but I will not save it without confirmation.',
        requiresConfirmation: true,
        ocrText: text,
        metadata: {'medication_signal_count': medHits},
      );
    }
    final foodHits = [
      'nutrition facts',
      'calories',
      'protein',
      'ingredient',
      'serving',
      'restaurant',
      'menu',
    ].where((term) => lower.contains(term)).length;
    if (foodHits >= 1) {
      return _result(
        tx,
        PhotoIntakeKind.food,
        0.74,
        'This looks food-related. I can help log it after you confirm the details.',
        requiresConfirmation: true,
        ocrText: text,
        metadata: {'food_signal_count': foodHits},
      );
    }
    if (lower.contains('stool') ||
        lower.contains('blood') ||
        lower.contains('rash') ||
        lower.contains('wound')) {
      return _result(
        tx,
        PhotoIntakeKind.symptomPhoto,
        0.72,
        'This may be symptom-related. I will not save the photo, but I can help create a text note if you confirm.',
        requiresConfirmation: true,
        ocrText: text,
      );
    }
    return _result(
      tx,
      PhotoIntakeKind.unrelated,
      0.65,
      'This does not look related to Gemma Flares, so I did not save it.',
      requiresConfirmation: false,
      ocrText: text,
    );
  }

  int _labSignalCount(String lower) {
    const phraseSignals = [
      'blood test',
      'blood work',
      'bloodwork',
      'lab result',
      'test result',
      'reference range',
      'reference interval',
      'abnormal flag',
      'labcorp',
      'quest',
      'diagnostics',
      'specimen',
      'cbc',
      'complete blood count',
      'cmp',
      'comprehensive metabolic panel',
      'metabolic panel',
      'chemistry panel',
      'hepatic panel',
      'liver panel',
      'thyroid panel',
      'iron studies',
      'stool culture',
      'c. diff',
      'c diff',
      'fecal',
      'calprotectin',
      '25-hydroxyvitamin',
      '25 hydroxyvitamin',
      'vitamin d',
      'vitamin c',
      'ascorbic acid',
      'vitamin b12',
    ];
    const shortAnalytes = [
      'crp',
      'esr',
      'wbc',
      'rbc',
      'hgb',
      'hct',
      'mcv',
      'mch',
      'rdw',
      'plt',
      'alt',
      'ast',
      'alp',
      'bun',
      'egfr',
      'tsh',
      'a1c',
    ];
    const longAnalytes = [
      'c-reactive',
      'sed rate',
      'hemoglobin',
      'hematocrit',
      'platelet',
      'albumin',
      'ferritin',
      'folate',
      'transferrin',
      'saturation',
      'bilirubin',
      'creatinine',
      'sodium',
      'potassium',
      'chloride',
      'bicarbonate',
      'calcium',
      'magnesium',
      'phosphorus',
      'glucose',
      'lipase',
      'amylase',
      'neutrophil',
      'lymphocyte',
      'monocyte',
      'eosinophil',
      'basophil',
    ];
    var hits = 0;
    hits += phraseSignals.where(lower.contains).length;
    hits += longAnalytes.where(lower.contains).length;
    hits += shortAnalytes.where((term) => _containsToken(lower, term)).length;
    if (RegExp(
      r'\b(?:mg/dl|mg/l|mmol/l|u/l|iu/l|ng/ml|pg/ml|ug/dl|μg/dl|ug/g|μg/g|miu/l|g/dl|x10|10\^|%)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      hits++;
    }
    return hits;
  }

  int _clinicalRecordSignalCount(String lower) {
    const signals = [
      'pathologic diagnosis',
      'pathology',
      'microscopic diagnosis',
      'biopsy',
      'terminal ileum',
      'ileitis',
      'colitis',
      'proctitis',
      'granuloma',
      'dysplasia',
      'malignancy',
      'colonoscopy',
      'endoscopy',
      'findings',
      'impression',
      'erythema',
      'erosion',
      'ulceration',
      'ulcerated mucosa',
      'decreased vascularity',
      'clinical correlation',
    ];
    return signals.where(lower.contains).length;
  }

  bool _hasLabResultShape(String lower) {
    final hasNumber = RegExp(r'\b\d+(?:\.\d+)?\b').hasMatch(lower);
    if (!hasNumber) return false;
    final hasResultWord = lower.contains('result') ||
        lower.contains('test') ||
        lower.contains('panel') ||
        lower.contains('units') ||
        lower.contains('reference') ||
        lower.contains('status');
    return hasResultWord && _labSignalCount(lower) >= 1;
  }

  bool _containsToken(String lower, String token) {
    return RegExp(
      '(^|[^a-z0-9])${RegExp.escape(token)}([^a-z0-9]|\$)',
    ).hasMatch(lower);
  }

  Future<PhotoIntakeResult> _classifyWithGemmaFallback(
    PhotoIntakeResult fallback,
    String ocrText,
  ) async {
    final runtime = _runtime;
    if (runtime == null) return fallback;
    try {
      final status = await runtime.getRuntimeStatus();
      if (!status.isModelLoaded) return fallback;
      final response = await runtime.generate(
        LocalModelRequest(
          systemPrompt:
              'Classify a Gemma Flares photo from OCR text. Return one label only: lab_report, food, medication_label, stool_or_symptom_photo, unrelated, unknown.',
          userPrompt: ocrText,
          groundedContext: const {'task': 'photo_classify'},
          taskType: 'photo_classify',
          maxTokens: 24,
          temperature: 0,
        ),
      );
      final label = response.outputText.toLowerCase();
      final kind = label.contains('lab_report')
          ? PhotoIntakeKind.labReport
          : label.contains('medication')
              ? PhotoIntakeKind.medicationLabel
              : label.contains('food')
                  ? PhotoIntakeKind.food
                  : label.contains('symptom') || label.contains('stool')
                      ? PhotoIntakeKind.symptomPhoto
                      : label.contains('unrelated')
                          ? PhotoIntakeKind.unrelated
                          : fallback.kind;
      if (kind == fallback.kind) return fallback;
      return _result(
        fallback.transactionId,
        kind,
        0.7,
        kind == PhotoIntakeKind.unrelated
            ? 'This does not look related to Gemma Flares, so I did not save it.'
            : 'This may be Gemma Flares-related. Please review before anything is saved.',
        requiresConfirmation: kind != PhotoIntakeKind.unrelated,
        ocrText: ocrText,
        metadata: {'gemma_label': label.trim()},
      );
    } catch (_) {
      return fallback;
    }
  }

  PhotoIntakeResult _result(
    String tx,
    PhotoIntakeKind kind,
    double confidence,
    String summary, {
    required bool requiresConfirmation,
    String? ocrText,
    Map<String, Object?> metadata = const {},
  }) {
    return PhotoIntakeResult(
      transactionId: tx,
      kind: kind,
      confidence: confidence,
      ocrText: ocrText,
      userFacingSummary: summary,
      requiresConfirmation: requiresConfirmation,
      metadata: metadata,
    );
  }
}
