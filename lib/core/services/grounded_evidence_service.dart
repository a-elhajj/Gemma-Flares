import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';
import 'ibd_checkin_service.dart';
import 'profile_service.dart';

class GroundedEvidenceBundle {
  const GroundedEvidenceBundle({
    required this.dateLocal,
    required this.evidence,
    required this.evidenceHash,
    required this.receipt,
  });

  final String dateLocal;
  final Map<String, Object?> evidence;
  final String evidenceHash;
  final Map<String, Object?> receipt;
}

class GroundedEvidenceService {
  GroundedEvidenceService({
    required WearableSampleRepository repository,
    ProfileService? profileService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _profileService = profileService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final ProfileService? _profileService;
  final DateTime Function() _nowProvider;

  Future<GroundedEvidenceBundle> buildLatestBundle({String? dateLocal}) async {
    final now = _nowProvider();
    final effectiveDate = dateLocal ?? _dateOnly(now);
    final latestScore = await _repository.getLatestUserFacingFlareRiskScore();
    final latestSummary = await _repository.getLatestDailySummary();
    final latestDailyFeatures = await _repository.getDailyFeatureForDate(
      effectiveDate,
    );
    final syncState = await _repository.getSyncState('apple_health');
    final symptoms = await _repository.getRecentSymptoms(limit: 8);
    final labs = await _repository.getLabValues();
    final procedures = await _repository.getEndoscopyRecords();
    final checkIns = await _repository.getRecentPro2Surveys(limit: 7);
    final latestCosinor = await _repository.getCosinorFeature(effectiveDate);
    final profile = await _profileService?.getGroundedSummary() ??
        const <String, Object?>{};

    final evidence = <String, Object?>{
      'date_local': effectiveDate,
      'latest_score': latestScore == null
          ? null
          : {
              'value': latestScore.riskScore.round(),
              'band': latestScore.riskBand,
              'confidence': latestScore.confidenceScore.round(),
              'drivers': latestScore.contributionJson,
              'features': _sanitizeMap(latestScore.featureSnapshotJson),
            },
      'latest_summary': _sanitizeMap(latestSummary?.summaryJson ?? const {}),
      'daily_features_full': _sanitizeMap(
        latestDailyFeatures?.featureJson ?? const {},
      ),
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
          .take(8)
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
          .take(4)
          .map(
            (item) => {
              'date': item.procedureDate,
              'type': item.procedureType,
              'mayo': item.mayoEndoscopicScore,
              'ses_cd': item.sesCdScore,
            },
          )
          .toList(growable: false),
      'checkins': checkIns
          .map(IbdCheckInService.evidenceForSurvey)
          .toList(growable: false),
      'checkin_summary_7d': IbdCheckInService.sevenDaySummary(checkIns),
      'cosinor': latestCosinor == null
          ? null
          : {
              'fit_valid': latestCosinor.fitValid,
              'mesor': latestCosinor.mesor,
              'amplitude': latestCosinor.amplitude,
              'peak_time_hours': latestCosinor.peakTimeHours,
            },
      'profile': profile,
    };
    final evidenceHash = _hashJson(evidence);
    return GroundedEvidenceBundle(
      dateLocal: effectiveDate,
      evidence: evidence,
      evidenceHash: evidenceHash,
      receipt: {
        'evidence_hash': evidenceHash,
        'symptom_count': symptoms.length,
        'lab_count': labs.length,
        'procedure_count': procedures.length,
        'checkin_count': checkIns.length,
        'has_score': latestScore != null,
        'has_daily_features': latestDailyFeatures != null,
        'created_at': now.toUtc().toIso8601String(),
      },
    );
  }

  Map<String, Object?> _sanitizeMap(Map<String, Object?> raw) {
    final safe = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains('note') ||
          key.contains('transcript') ||
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
        safe[entry.key] = _sanitizeMap(Map<String, Object?>.from(value));
      } else {
        safe[entry.key] = value;
      }
    }
    return safe;
  }

  String _hashJson(Map<String, Object?> value) {
    return sha256.convert(utf8.encode(jsonEncode(value))).toString();
  }

  String _dateOnly(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}
