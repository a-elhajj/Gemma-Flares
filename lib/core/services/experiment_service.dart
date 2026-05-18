import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';

class ExperimentService {
  ExperimentService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const riskExplanationLength = 'risk_explanation_length';
  static const permissionPrep = 'permission_preprompt_copy';
  static const checkInLayout = 'checkin_copy_layout';
  static const alertThresholdBanding = 'alert_threshold_banding';
  static const contextReasonCopy = 'context_reason_copy';

  static const _installIdKey = 'experiment_install_id';
  static const _forbiddenMetadataFragments = [
    'health',
    'hrv',
    'heart',
    'symptom',
    'transcript',
    'lab',
    'crp',
    'esr',
    'fecal',
    'calprotectin',
    'score',
    'risk',
    'pain',
    'stool',
    'bleeding',
    'sleep',
    'steps',
    'spo2',
    'temperature',
    'weight',
    'bmi',
  ];

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<String> variantFor(
    String experimentKey, {
    List<String> variants = const ['A', 'B'],
  }) async {
    if (variants.isEmpty) {
      throw ArgumentError.value(variants, 'variants', 'Must not be empty.');
    }
    final existing = await _repository.getExperimentAssignment(experimentKey);
    if (existing != null && variants.contains(existing.variant)) {
      return existing.variant;
    }

    final installId = await _getOrCreateInstallId();
    final digest = sha256.convert(utf8.encode('$installId:$experimentKey'));
    final bucket = digest.bytes.fold<int>(0, (sum, byte) => sum + byte);
    final variant = variants[bucket % variants.length];
    await _repository.upsertExperimentAssignment(
      ExperimentAssignmentRecord(
        experimentKey: experimentKey,
        variant: variant,
        assignedAt: _nowProvider(),
      ),
    );
    return variant;
  }

  Future<void> logExposure({
    required String experimentKey,
    required String eventName,
    String? sessionId,
    Map<String, Object?> metadata = const {},
  }) async {
    final variant = await variantFor(experimentKey);
    await _repository.insertExperimentEvent(
      ExperimentEventRecord(
        eventName: eventName,
        experimentKey: experimentKey,
        variant: variant,
        sessionId: sessionId,
        metadataJson: _scrubMetadata(metadata),
        createdAt: _nowProvider(),
      ),
    );
  }

  Future<String> _getOrCreateInstallId() async {
    final stored = await _repository.getAppSettingJson(_installIdKey);
    if (stored is String && stored.isNotEmpty) {
      return stored;
    }
    final seed = sha256
        .convert(
          utf8.encode('gemma_flares:${_nowProvider().microsecondsSinceEpoch}'),
        )
        .toString();
    await _repository.upsertAppSettingJson(key: _installIdKey, value: seed);
    return seed;
  }

  Map<String, Object?> _scrubMetadata(Map<String, Object?> metadata) {
    final scrubbed = <String, Object?>{};
    for (final entry in metadata.entries) {
      final key = entry.key;
      final normalizedKey = key.toLowerCase();
      final isForbidden = _forbiddenMetadataFragments.any(
        normalizedKey.contains,
      );
      if (isForbidden) {
        scrubbed[key] = '[redacted]';
        continue;
      }
      final value = entry.value;
      if (value == null || value is String || value is num || value is bool) {
        scrubbed[key] = value;
      } else {
        scrubbed[key] = '[redacted]';
      }
    }
    return scrubbed;
  }
}
