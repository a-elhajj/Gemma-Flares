import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';
import 'ibd_checkin_service.dart';
import 'diagnostic_log_service.dart';
import 'local_model_runtime.dart';
import 'profile_service.dart';

class GuidanceSnapshot {
  const GuidanceSnapshot({
    required this.dateLocal,
    required this.text,
    required this.fallbackText,
    required this.evidenceHash,
    required this.generatedAt,
    required this.status,
    required this.usedModelOutput,
    required this.traceJson,
  });

  final String dateLocal;
  final String text;
  final String fallbackText;
  final String evidenceHash;
  final DateTime generatedAt;
  final String status;
  final bool usedModelOutput;
  final Map<String, Object?> traceJson;

  Map<String, Object?> toJson() {
    return {
      'date_local': dateLocal,
      'text': text,
      'fallback_text': fallbackText,
      'evidence_hash': evidenceHash,
      'generated_at': generatedAt.toUtc().toIso8601String(),
      'status': status,
      'used_model_output': usedModelOutput,
      'trace_json': traceJson,
    };
  }

  static GuidanceSnapshot? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final json = Map<String, Object?>.from(value);
    final generatedAt = DateTime.tryParse(
      json['generated_at'] as String? ?? '',
    );
    final dateLocal = json['date_local'] as String?;
    final text = json['text'] as String?;
    final fallbackText = json['fallback_text'] as String?;
    final evidenceHash = json['evidence_hash'] as String?;
    if (generatedAt == null ||
        dateLocal == null ||
        text == null ||
        fallbackText == null ||
        evidenceHash == null) {
      return null;
    }
    return GuidanceSnapshot(
      dateLocal: dateLocal,
      text: text,
      fallbackText: fallbackText,
      evidenceHash: evidenceHash,
      generatedAt: generatedAt,
      status: json['status'] as String? ?? 'unknown',
      usedModelOutput: json['used_model_output'] as bool? ?? false,
      traceJson: json['trace_json'] is Map
          ? Map<String, Object?>.from(json['trace_json'] as Map)
          : const {},
    );
  }
}

class GuidanceService {
  GuidanceService({
    required WearableSampleRepository repository,
    required LocalModelRuntime runtime,
    ProfileService? profileService,
    DiagnosticLogService? diagnosticLogService,
    Duration minimumModelInterval = const Duration(minutes: 4),
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _runtime = runtime,
        _profileService = profileService,
        _diagnosticLogService = diagnosticLogService,
        _minimumModelInterval = minimumModelInterval,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final LocalModelRuntime _runtime;
  final ProfileService? _profileService;
  final DiagnosticLogService? _diagnosticLogService;
  final Duration _minimumModelInterval;
  final DateTime Function() _nowProvider;

  static const _cacheKeyPrefix = 'guidance_cache';

  Future<GuidanceSnapshot?> getCachedLatestGuidance() async {
    final dateLocal = _dateOnly(_nowProvider());
    return getCachedGuidance(dateLocal);
  }

  Future<GuidanceSnapshot?> getCachedGuidance(String dateLocal) async {
    final value = await _repository.getAppSettingJson(_cacheKey(dateLocal));
    return GuidanceSnapshot.fromJson(value);
  }

  Future<GuidanceSnapshot> refreshLatestGuidance({
    String reason = 'manual',
    bool allowModel = true,
  }) async {
    final now = _nowProvider();
    final dateLocal = _dateOnly(now);
    final evidence = await _buildEvidence(dateLocal: dateLocal, now: now);
    final fallbackText = _fallbackGuidance(evidence);
    final evidenceHash = _hashJson(_stableEvidenceForHash(evidence));
    final cached = await getCachedGuidance(dateLocal);
    if (cached != null &&
        cached.evidenceHash == evidenceHash &&
        cached.text.trim().isNotEmpty) {
      return cached;
    }

    var text = fallbackText;
    var status = 'fallback';
    var usedModelOutput = false;
    var modelSkippedByBackoff = false;
    final trace = <String, Object?>{
      'reason': reason,
      'evidence_hash': evidenceHash,
      'requested_model': allowModel,
    };

    if (allowModel &&
        cached != null &&
        cached.usedModelOutput &&
        now.difference(cached.generatedAt.toUtc()) < _minimumModelInterval) {
      allowModel = false;
      modelSkippedByBackoff = true;
    }
    trace['model_backoff_applied'] = modelSkippedByBackoff;
    trace['minimum_model_interval_seconds'] = _minimumModelInterval.inSeconds;

    if (allowModel) {
      var runtimeStatus = await _runtime.getRuntimeStatus();
      if (!runtimeStatus.isModelLoaded &&
          runtimeStatus.isBundledModelPresent &&
          runtimeStatus.isBackendLinked) {
        runtimeStatus = await _runtime.loadBundledModel(
          profile: 'phone_balanced',
        );
      }
      trace.addAll({
        'runtime_status': runtimeStatus.status,
        'runtime_loaded': runtimeStatus.isModelLoaded,
        'active_runtime_profile': runtimeStatus.activeRuntimeProfile,
      });
      if (runtimeStatus.isModelLoaded) {
        final modelEvidence = _modelEvidence(evidence);
        trace['model_evidence_chars'] = jsonEncode(modelEvidence).length;
        final response = await _runtime.generate(
          LocalModelRequest(
            systemPrompt:
                'You are Gemma 4 running locally in Gemma Flares. Write one short, warm, non-diagnostic guidance note from local evidence only. Distinguish HealthKit trends, check-ins, chat symptoms, labs, and health records. Do not diagnose or recommend medication changes. If severe pain, heavy bleeding, fever, dehydration, or unsafe symptoms appear, advise clinician or urgent care.',
            userPrompt:
                'Give the user one helpful next step for today. Keep it under 55 words.',
            groundedContext: modelEvidence,
            maxTokens: 96,
            temperature: 0.15,
            taskType: 'chat',
            modelRole: 'daily_fast',
            contextPolicy: 'standard',
            privacyMode: 'local_only',
          ),
        );
        final cleaned = _cleanGuidance(response.outputText);
        usedModelOutput = response.status == 'success' &&
            response.outputQualityStatus != 'rejected' &&
            cleaned.isNotEmpty;
        trace.addAll({
          'generation_status': response.status,
          'used_model_output': usedModelOutput,
          'fallback_reason': response.fallbackReason ?? response.reason,
          'generation_limit': response.generationLimit,
          'latency_ms': response.generationLatencyMs,
        });
        if (usedModelOutput) {
          text = cleaned;
          status = 'model';
        }
      }
    }

    final snapshot = GuidanceSnapshot(
      dateLocal: dateLocal,
      text: text,
      fallbackText: fallbackText,
      evidenceHash: evidenceHash,
      generatedAt: _nowProvider(),
      status: status,
      usedModelOutput: usedModelOutput,
      traceJson: trace,
    );
    await _repository.upsertAppSettingJson(
      key: _cacheKey(dateLocal),
      value: snapshot.toJson(),
    );
    await _diagnosticLogService?.info(
      'guidance_refresh_completed',
      category: DiagnosticLogService.categoryRiskEngine,
      message: 'Local guidance cache refreshed.',
      metadata: {
        'reason': reason,
        'status': status,
        'used_model_output': usedModelOutput,
        'model_backoff_applied': modelSkippedByBackoff,
      },
    );
    return snapshot;
  }

  Future<Map<String, Object?>> _buildEvidence({
    required String dateLocal,
    required DateTime now,
  }) async {
    final latestScore = await _repository.getLatestUserFacingFlareRiskScore();
    final latestSummary = await _repository.getLatestDailySummary();
    final latestDailyFeatures = await _repository.getDailyFeatureForDate(
      dateLocal,
    );
    final latestBaseline = await _repository.getLatestBaselineSnapshot();
    final syncState = await _repository.getSyncState('apple_health');
    final symptoms = await _repository.getRecentSymptoms(limit: 8);
    final labs = await _repository.getLabValues();
    final procedures = await _repository.getEndoscopyRecords();
    final checkIns = await _repository.getRecentPro2Surveys(limit: 7);
    final flareLabel = await _repository.getFlareLabel(dateLocal);
    final latestCosinor = await _repository.getCosinorFeature(dateLocal);
    final cosinorRange = await _repository.getCosinorFeaturesInRange(
      _offsetDate(dateLocal, -7),
      dateLocal,
    );
    final profile = await _profileService?.getGroundedSummary() ??
        const <String, Object?>{};

    return {
      'date_local': dateLocal,
      'latest_score': latestScore == null
          ? null
          : {
              'value': latestScore.riskScore.round(),
              'band': latestScore.riskBand,
              'confidence': latestScore.confidenceScore.round(),
              'drivers': latestScore.contributionJson,
              'features': _compactFeatureSnapshot(
                latestScore.featureSnapshotJson,
              ),
            },
      'latest_summary': _compactFeatureSnapshot(
        latestSummary?.summaryJson ?? const {},
      ),
      'daily_features_full': _sanitizeEvidenceMap(
        latestDailyFeatures?.featureJson ?? const {},
      ),
      'baseline': latestBaseline == null
          ? null
          : {
              'state': latestBaseline.readinessState,
              'valid_days': latestBaseline.validDays,
            },
      'sync': syncState == null
          ? null
          : {
              'last_sync_at': syncState.lastSyncAt?.toUtc().toIso8601String(),
              'last_error': syncState.lastError,
            },
      'symptoms': symptoms
          .map(
            (item) => {
              'type': item.symptomType,
              'severity': item.severity,
              'logged_at': item.loggedAt.toUtc().toIso8601String(),
            },
          )
          .toList(growable: false),
      'labs': labs
          .take(5)
          .map(
            (item) => {
              'type': item.labType,
              'value': item.valueNumeric,
              'unit': item.unit,
              'drawn_date': item.drawnDate,
              'elevated':
                  item.valueNumeric > (item.referenceHigh ?? double.infinity),
            },
          )
          .toList(growable: false),
      'procedures': procedures
          .take(3)
          .map(
            (item) => {
              'date': item.procedureDate,
              'type': item.procedureType,
              'mayo': item.mayoEndoscopicScore,
              'ses_cd': item.sesCdScore,
              'biopsy': item.biopsyResult,
            },
          )
          .toList(growable: false),
      'checkins': checkIns
          .map(IbdCheckInService.evidenceForSurvey)
          .toList(growable: false),
      'checkin_summary_7d': IbdCheckInService.sevenDaySummary(checkIns),
      'flare_label_today': flareLabel == null
          ? null
          : {
              'inflammatory': flareLabel.inflammatoryFlare,
              'symptomatic': flareLabel.symptomaticFlare,
              'clinical': flareLabel.clinicalFlare,
              'confidence': flareLabel.confidence,
            },
      'cosinor': {
        'latest': latestCosinor == null
            ? null
            : {
                'feature_date_local': latestCosinor.featureDate,
                'fit_valid': latestCosinor.fitValid,
                'mesor': latestCosinor.mesor,
                'amplitude': latestCosinor.amplitude,
                'peak_time_hours': latestCosinor.peakTimeHours,
                'r_squared': latestCosinor.rSquared,
                'sample_count': latestCosinor.sampleCount,
              },
        'recent_7d': cosinorRange
            .map(
              (item) => {
                'feature_date_local': item.featureDate,
                'fit_valid': item.fitValid,
                'mesor': item.mesor,
                'amplitude': item.amplitude,
                'peak_time_hours': item.peakTimeHours,
                'r_squared': item.rSquared,
              },
            )
            .toList(growable: false),
      },
      'profile': profile,
    };
  }

  Map<String, Object?> _stableEvidenceForHash(Map<String, Object?> evidence) {
    final copy = Map<String, Object?>.from(evidence);
    final sync = copy['sync'];
    if (sync is Map) {
      final syncCopy = Map<String, Object?>.from(sync);
      syncCopy.remove('last_sync_at');
      copy['sync'] = syncCopy;
    }
    copy.remove('generated_at');
    return copy;
  }

  Map<String, Object?> _modelEvidence(Map<String, Object?> evidence) {
    final latestScore = evidence['latest_score'];
    final score = latestScore is Map
        ? Map<String, Object?>.from(latestScore)
        : const <String, Object?>{};
    final checkinSummary = evidence['checkin_summary_7d'];
    final checkinMap = checkinSummary is Map
        ? Map<String, Object?>.from(checkinSummary)
        : const <String, Object?>{};
    final latestCheckin = checkinMap['latest'];
    final latestCheckinMap = latestCheckin is Map
        ? Map<String, Object?>.from(latestCheckin)
        : const <String, Object?>{};

    final compact = <String, Object?>{
      'score': score.isEmpty
          ? null
          : {
              'value': score['value'],
              'band': score['band'],
              'confidence': score['confidence'],
              'drivers': _compactFeatureSnapshot(
                Map<String, Object?>.from(score['drivers'] as Map? ?? const {}),
              ),
            },
      'baseline': evidence['baseline'],
      'sync': _compactSync(evidence['sync']),
      'symptoms': _compactList(
        evidence['symptoms'],
        keys: const ['type', 'severity'],
        limit: 3,
      ),
      'labs': _compactList(
        evidence['labs'],
        keys: const ['type', 'value', 'unit', 'elevated'],
        limit: 3,
      ),
      'checkin': latestCheckinMap.isEmpty
          ? null
          : {
              'date': latestCheckinMap['date'],
              'disease_type': latestCheckinMap['disease_type'],
              'score': latestCheckinMap['score'],
              'is_flare': latestCheckinMap['is_flare'],
              'summary': latestCheckinMap['summary'],
              'red_flags': latestCheckinMap['red_flags'],
            },
      'checkin_7d': {
        'completed_days': checkinMap['completed_days'],
        'days_with_bleeding': checkinMap['days_with_bleeding'],
        'days_with_urgency': checkinMap['days_with_urgency'],
        'days_with_fatigue': checkinMap['days_with_fatigue'],
        'days_with_red_flags': checkinMap['days_with_red_flags'],
      },
      'features': _compactFeatureSnapshot(
        Map<String, Object?>.from(
          evidence['daily_features_full'] as Map? ?? const {},
        ),
      ),
      'cosinor': _compactCosinor(evidence['cosinor']),
      'limits': 'Local trend support only; not diagnosis or medication advice.',
    };

    final encoded = jsonEncode(compact);
    if (encoded.length <= 1800) return compact;

    return {
      'score': compact['score'],
      'baseline': compact['baseline'],
      'sync': compact['sync'],
      'symptoms': compact['symptoms'],
      'labs': compact['labs'],
      'checkin': compact['checkin'],
      'features': compact['features'],
      'limits': compact['limits'],
      'compact_notice': 'Evidence shortened for the phone context window.',
    };
  }

  Map<String, Object?>? _compactSync(Object? sync) {
    if (sync is! Map) return null;
    final mapped = Map<String, Object?>.from(sync);
    return {
      'has_recent_sync': mapped['last_sync_at'] != null,
      'last_error': mapped['last_error'],
    };
  }

  Map<String, Object?>? _compactCosinor(Object? cosinor) {
    if (cosinor is! Map) return null;
    final latest = cosinor['latest'];
    if (latest is! Map) return null;
    final mapped = Map<String, Object?>.from(latest);
    return {
      'fit_valid': mapped['fit_valid'],
      'mesor': mapped['mesor'],
      'amplitude': mapped['amplitude'],
      'peak_time_hours': mapped['peak_time_hours'],
    };
  }

  List<Map<String, Object?>> _compactList(
    Object? value, {
    required List<String> keys,
    required int limit,
  }) {
    if (value is! List) return const [];
    return value.take(limit).whereType<Map>().map((item) {
      final mapped = <String, Object?>{};
      for (final key in keys) {
        if (item.containsKey(key)) {
          mapped[key] = item[key];
        }
      }
      return mapped;
    }).toList(growable: false);
  }

  Map<String, Object?> _compactFeatureSnapshot(Map<String, Object?> source) {
    const keys = [
      'hrv_3d_pct_delta_vs_baseline',
      'hrv_7d_pct_delta_vs_baseline',
      'rhr_3d_delta_vs_baseline',
      'sleep_3d_pct_delta_vs_baseline',
      'steps_7d_pct_delta_vs_baseline',
      'spo2_7d_delta_vs_baseline',
      'symptom_count_48h',
      'symptom_max_severity_48h',
      'symptom_weighted_sum_48h',
      'checkin_present_today',
      'checkin_completeness_score',
      'checkin_core_symptom_score',
      'checkin_symptom_burden',
      'checkin_pain_0_3',
      'checkin_bleeding_0_3',
      'checkin_urgency_0_3',
      'checkin_red_flag_count',
      'apple_health_symptom_count',
      'clinical_anchor_inflammatory',
      'clinical_anchor_symptomatic',
      'clinical_anchor_endoscopy',
      'current_sync_quality_score',
      'stale_sync_hours',
      'context_attribution_reason',
    ];
    return {
      for (final key in keys)
        if (source.containsKey(key)) key: source[key],
    };
  }

  String _fallbackGuidance(Map<String, Object?> evidence) {
    final score = evidence['latest_score'] as Map<String, Object?>?;
    final symptoms = (evidence['symptoms'] as List?) ?? const [];
    final checkins = (evidence['checkins'] as List?) ?? const [];
    final labs = (evidence['labs'] as List?) ?? const [];
    final sync = evidence['sync'] as Map<String, Object?>?;
    final lastError = sync?['last_error'] as String?;
    if (sync == null) {
      return 'Start with a Health sync so Gemma Flares can compare today with your usual pattern.';
    }
    if (lastError != null && lastError.isNotEmpty) {
      return 'Health sync needs attention. Refresh it before reading today\'s pattern too closely.';
    }
    if (score == null) {
      return 'Keep logging short check-ins and symptoms. Gemma Flares will build a clearer local picture as data comes in.';
    }
    final band = score['band'] as String? ?? 'low';
    final confidence = score['confidence'] as int? ?? 0;
    if (band == 'high' || band == 'critical') {
      return 'Today has stronger signals than usual. Review what changed and contact your GI team if symptoms feel concerning.';
    }
    if (symptoms.isNotEmpty && labs.isNotEmpty) {
      return 'You have recent symptoms and lab context. A short GI summary can help connect the dots for your next visit.';
    }
    if (checkins.isNotEmpty) {
      return 'Your latest check-in is saved and will help Gemma explain today alongside HealthKit trends, symptoms, and labs.';
    }
    if (confidence < 55) {
      return 'Gemma Flares is still building confidence. A quick check-in or fresh Health sync will make today\'s guidance stronger.';
    }
    return 'Today looks steady. Keep an eye on symptoms and add a quick note if anything changes.';
  }

  String _cleanGuidance(String raw) {
    return raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(
          RegExp(r'^(Gemma Flares:|Guidance:)\s*', caseSensitive: false),
          '',
        )
        .trim();
  }

  String _hashJson(Map<String, Object?> value) {
    final encoded = jsonEncode(value);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  Map<String, Object?> _sanitizeEvidenceMap(Map<String, Object?> raw) {
    final sanitized = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains('transcript') ||
          key.contains('note') ||
          key.contains('message') ||
          key.contains('provider') ||
          key.contains('name') ||
          key.contains('address') ||
          key.contains('email') ||
          key.contains('phone')) {
        continue;
      }
      final value = entry.value;
      if (value is Map) {
        sanitized[entry.key] = _sanitizeEvidenceMap(
          Map<String, Object?>.from(value),
        );
      } else if (value is List) {
        sanitized[entry.key] = value
            .where((item) => item is num || item is bool || item is String)
            .take(64)
            .toList(growable: false);
      } else {
        sanitized[entry.key] = value;
      }
    }
    return sanitized;
  }

  String _offsetDate(String dateLocal, int deltaDays) {
    final base = DateTime.parse('${dateLocal}T00:00:00Z').toUtc();
    final next = base.add(Duration(days: deltaDays));
    return '${next.year.toString().padLeft(4, '0')}-'
        '${next.month.toString().padLeft(2, '0')}-'
        '${next.day.toString().padLeft(2, '0')}';
  }

  String _cacheKey(String dateLocal) => '$_cacheKeyPrefix:$dateLocal';

  String _dateOnly(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}
