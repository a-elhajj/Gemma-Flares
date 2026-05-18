import '../database/wearable_sample_repository.dart';
import 'rag_index_service.dart';

class ClinicalRecordIngestionService {
  ClinicalRecordIngestionService({
    required WearableSampleRepository repository,
    RagIndexService? ragIndexService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _ragIndexService = ragIndexService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final RagIndexService? _ragIndexService;
  final DateTime Function() _nowProvider;

  Future<int> ingestFhirResource({
    required Map<String, Object?> resource,
    String source = 'healthkit_clinical_records',
  }) async {
    final resourceType = resource['resourceType'] as String? ?? 'unknown';
    final id = resource['id'] as String?;
    final effectiveDate = _effectiveDate(resource);
    final extracted = _extract(resource);
    final importId = await _repository.insertClinicalRecordImport(
      ClinicalRecordImportRecord(
        recordType: _recordType(resourceType, extracted),
        source: source,
        effectiveDate: effectiveDate,
        fhirResourceType: resourceType,
        fhirId: id,
        extractedJson: extracted,
        rawResourceJson: resource,
        importStatus: extracted.isEmpty ? 'stored_unmapped' : 'extracted',
        createdAt: _nowProvider(),
      ),
    );

    if (resourceType == 'Observation' &&
        effectiveDate != null &&
        extracted['lab_type'] is String &&
        extracted['value_numeric'] is num) {
      final lab = LabValueRecord(
        drawnDate: effectiveDate,
        labType: extracted['lab_type'] as String,
        valueNumeric: (extracted['value_numeric'] as num).toDouble(),
        unit: extracted['unit'] as String? ?? '',
        labName: source,
        notes: extracted['display'] as String?,
        createdAt: _nowProvider(),
        updatedAt: _nowProvider(),
      );
      final labId = await _repository.upsertLabValue(lab);
      await _indexLabForRag(labId, lab);
    } else if ((resourceType == 'Procedure' ||
            resourceType == 'DiagnosticReport') &&
        extracted.isNotEmpty) {
      await _indexClinicalRecordForRag(
        importId: importId,
        resourceType: resourceType,
        effectiveDate: effectiveDate,
        source: source,
        extracted: extracted,
      );
    }
    return importId;
  }

  Future<void> _indexLabForRag(int id, LabValueRecord lab) async {
    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) return;
    try {
      await ragCorpus.indexLabValue(id: id, lab: lab);
    } catch (_) {}
  }

  Future<void> _indexClinicalRecordForRag({
    required int importId,
    required String resourceType,
    required String? effectiveDate,
    required String source,
    required Map<String, Object?> extracted,
  }) async {
    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) return;
    try {
      await ragCorpus.indexProcedureRecord(
        'clinical_${resourceType}_$importId',
        [
          'Clinical record import id: $importId',
          'FHIR resource type: $resourceType',
          if (effectiveDate != null) 'Effective date: $effectiveDate',
          'Source: $source',
          if ((extracted['display']?.toString() ?? '').trim().isNotEmpty)
            'Display: ${extracted['display']}',
          'Extracted: $extracted',
        ].join('\n'),
      );
    } catch (_) {}
  }

  Map<String, Object?> _extract(Map<String, Object?> resource) {
    final resourceType = resource['resourceType'] as String? ?? '';
    if (resourceType == 'Observation') {
      final display = _codeDisplay(resource).toLowerCase();
      final value = resource['valueQuantity'];
      if (value is! Map) return {};
      final numeric = value['value'];
      if (numeric is! num) return {};
      final unit =
          (value['unit'] as String?) ?? (value['code'] as String?) ?? '';
      final labType = _labType(display);
      if (labType == null) return {};
      return {
        'lab_type': labType,
        'display': _codeDisplay(resource),
        'value_numeric': numeric.toDouble(),
        'unit': unit,
      };
    }
    if (resourceType == 'Procedure' || resourceType == 'DiagnosticReport') {
      return {
        'display': _codeDisplay(resource),
        'ibd_relevant':
            _codeDisplay(resource).toLowerCase().contains('colon') ||
                _codeDisplay(resource).toLowerCase().contains('endoscopy') ||
                _codeDisplay(resource).toLowerCase().contains('pathology'),
      };
    }
    return {};
  }

  String? _labType(String display) {
    if (display.contains('c-reactive') || display.contains('crp')) {
      return 'crp';
    }
    if (display.contains('erythrocyte') || display.contains('esr')) {
      return 'esr';
    }
    if (display.contains('calprotectin')) {
      return 'fc';
    }
    if (display.contains('hemoglobin')) {
      return 'hemoglobin';
    }
    if (display.contains('albumin')) {
      return 'albumin';
    }
    if (display.contains('white blood') || display.contains('wbc')) {
      return 'wbc';
    }
    if (display.contains('ferritin')) {
      return 'ferritin';
    }
    if (display.contains('vitamin d')) {
      return 'vitamin_d';
    }
    if (display.contains('b12')) {
      return 'b12';
    }
    return null;
  }

  String _recordType(String resourceType, Map<String, Object?> extracted) {
    if (extracted['lab_type'] != null) {
      return 'lab';
    }
    if (resourceType == 'Procedure') {
      return 'procedure';
    }
    if (resourceType == 'DiagnosticReport') {
      return 'diagnostic_report';
    }
    return resourceType.toLowerCase();
  }

  String _codeDisplay(Map<String, Object?> resource) {
    final code = resource['code'];
    if (code is Map) {
      final text = code['text'];
      if (text is String && text.isNotEmpty) return text;
      final coding = code['coding'];
      if (coding is List && coding.isNotEmpty && coding.first is Map) {
        final display = (coding.first as Map)['display'];
        if (display is String) return display;
      }
    }
    return '';
  }

  String? _effectiveDate(Map<String, Object?> resource) {
    final raw = resource['effectiveDateTime'] ??
        resource['issued'] ??
        resource['performedDateTime'] ??
        resource['recordedDate'];
    if (raw is! String || raw.length < 10) return null;
    return raw.substring(0, 10);
  }
}
