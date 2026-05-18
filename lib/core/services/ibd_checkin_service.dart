import 'dart:convert';

import '../database/wearable_sample_repository.dart';

class IbdCheckInService {
  const IbdCheckInService._();

  static const schemaVersion = 'ibd_checkin_v1';

  static String encodeNotes({
    required String diseaseType,
    required Map<String, Object?> dailyCore,
    Map<String, Object?> dailyDetails = const {},
    Map<String, Object?> weeklyQuality = const {},
    List<String> completedSections = const ['core'],
    String source = 'checkin_screen',
  }) {
    final redFlags = _redFlags(
      diseaseType: diseaseType,
      dailyCore: dailyCore,
      dailyDetails: dailyDetails,
      weeklyQuality: weeklyQuality,
    );
    return jsonEncode({
      'schema_version': schemaVersion,
      'disease_type': diseaseType,
      'daily_core': dailyCore,
      'daily_details': dailyDetails,
      'weekly_quality': weeklyQuality,
      'completed_sections': completedSections,
      'red_flags': redFlags,
      'source': source,
    });
  }

  static String memoryTextForSurvey({
    required int surveyId,
    required Pro2SurveyRecord survey,
  }) {
    final evidence = evidenceForSurvey(survey);
    final core = Map<String, Object?>.from(evidence['core'] as Map);
    final details = Map<String, Object?>.from(evidence['details'] as Map);
    final redFlags =
        (evidence['red_flags'] as List?)?.whereType<String>().toList(
                  growable: false,
                ) ??
            const <String>[];
    return [
      'Check-in id: $surveyId',
      'Date: ${survey.surveyDate}',
      'Disease type: ${survey.diseaseType}',
      'Score: ${survey.pro2Score}',
      'Flare threshold crossed: ${survey.isFlare}',
      if (core.isNotEmpty) 'Core: ${jsonEncode(core)}',
      if (details.isNotEmpty) 'Details: ${jsonEncode(details)}',
      if (redFlags.isNotEmpty) 'Red flags: ${redFlags.join(', ')}',
      'Summary: ${summaryForSurvey(survey)}',
    ].join('\n');
  }

  static Map<String, Object?> memoryMetadataForSurvey({
    required int surveyId,
    required Pro2SurveyRecord survey,
  }) {
    final evidence = evidenceForSurvey(survey);
    final redFlags =
        (evidence['red_flags'] as List?)?.whereType<String>().toList(
                  growable: false,
                ) ??
            const <String>[];
    return {
      'survey_id': surveyId,
      'survey_date': survey.surveyDate,
      'disease_type': survey.diseaseType,
      'score': survey.pro2Score,
      'is_flare': survey.isFlare,
      'score_version': survey.scoreVersion,
      'red_flag_count': redFlags.length,
      'source': 'checkin_confirmation',
    };
  }

  static Map<String, Object?> parseNotes(String? notes) {
    if (notes == null || notes.trim().isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(notes);
      if (decoded is! Map) {
        return const {};
      }
      final mapped = Map<String, Object?>.from(decoded);
      if (mapped['schema_version'] != schemaVersion) {
        return const {};
      }
      return mapped;
    } catch (_) {
      return const {};
    }
  }

  static bool hasStructuredNotes(Pro2SurveyRecord survey) =>
      parseNotes(survey.notes).isNotEmpty;

  static Map<String, Object?> evidenceForSurvey(Pro2SurveyRecord survey) {
    final parsed = parseNotes(survey.notes);
    final rawDailyCore = Map<String, Object?>.from(
      parsed['daily_core'] as Map? ?? const {},
    );
    final rawDailyDetails = Map<String, Object?>.from(
      parsed['daily_details'] as Map? ?? const {},
    );
    final dailyCore = _normalizeDailyCore(
      survey: survey,
      rawDailyCore: rawDailyCore,
      rawDailyDetails: rawDailyDetails,
    );
    final dailyDetails = _normalizeDailyDetails(
      survey: survey,
      rawDailyCore: rawDailyCore,
      rawDailyDetails: rawDailyDetails,
    );
    final weeklyQuality = Map<String, Object?>.from(
      parsed['weekly_quality'] as Map? ?? const {},
    );
    final redFlags = ((parsed['red_flags'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final sections = ((parsed['completed_sections'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final diseaseType = survey.diseaseType;
    return {
      'date': survey.surveyDate,
      'disease_type': diseaseType,
      'score': survey.pro2Score,
      'is_flare': survey.isFlare,
      'score_version': survey.scoreVersion,
      'core': dailyCore.isEmpty ? _legacyCoreFromSurvey(survey) : dailyCore,
      'details': dailyDetails,
      'weekly_quality': weeklyQuality,
      'completed_sections': sections,
      'completion_score': completionScore(survey),
      'red_flags': redFlags,
      'summary': summaryForSurvey(survey),
    };
  }

  static Map<String, Object?> sevenDaySummary(List<Pro2SurveyRecord> surveys) {
    final recent = List<Pro2SurveyRecord>.from(surveys)
      ..sort((a, b) => b.surveyDate.compareTo(a.surveyDate));
    final latestSeven = recent.take(7).toList(growable: false);
    if (latestSeven.isEmpty) {
      return const {
        'completed_days': 0,
        'days_with_bleeding': 0,
        'days_with_urgency': 0,
        'days_with_fatigue': 0,
        'days_with_red_flags': 0,
      };
    }
    var painTotal = 0;
    var painCount = 0;
    var bleedingDays = 0;
    var urgencyDays = 0;
    var fatigueDays = 0;
    var redFlagDays = 0;
    var detailDays = 0;

    for (final survey in latestSeven) {
      final evidence = evidenceForSurvey(survey);
      final core = Map<String, Object?>.from(evidence['core'] as Map);
      final details = Map<String, Object?>.from(evidence['details'] as Map);
      final redFlags = evidence['red_flags'] as List;
      final pain = _asInt(core['abdominal_pain_0_3']) ??
          _asInt(details['belly_or_rectal_pain_0_3']);
      if (pain != null) {
        painTotal += pain;
        painCount += 1;
      }
      final bleeding =
          _asInt(core['rectal_bleeding_0_3']) ?? _asInt(details['blood_0_3']);
      if ((bleeding ?? 0) > 0) bleedingDays += 1;
      if ((_asInt(details['urgency_0_3']) ?? 0) > 0) urgencyDays += 1;
      if ((_asInt(details['fatigue_0_3']) ?? 0) > 0) fatigueDays += 1;
      if (redFlags.isNotEmpty) redFlagDays += 1;
      if (details.isNotEmpty) detailDays += 1;
    }

    return {
      'completed_days': latestSeven.length,
      'detail_days': detailDays,
      'average_pain_0_3': painCount == 0
          ? null
          : double.parse((painTotal / painCount).toStringAsFixed(2)),
      'days_with_bleeding': bleedingDays,
      'days_with_urgency': urgencyDays,
      'days_with_fatigue': fatigueDays,
      'days_with_red_flags': redFlagDays,
      'latest': evidenceForSurvey(latestSeven.first),
    };
  }

  static double completionScore(Pro2SurveyRecord survey) {
    final parsed = parseNotes(survey.notes);
    if (parsed.isEmpty) {
      return 0.4;
    }
    final sections = ((parsed['completed_sections'] as List?) ?? const [])
        .whereType<String>()
        .toSet();
    var score = 0.5;
    if (sections.contains('daily_details')) score += 0.3;
    if (sections.contains('weekly_quality')) score += 0.2;
    return score.clamp(0.0, 1.0).toDouble();
  }

  static bool hasWeeklyQuality(Pro2SurveyRecord survey) {
    final parsed = parseNotes(survey.notes);
    final weekly = parsed['weekly_quality'];
    return weekly is Map && weekly.isNotEmpty;
  }

  static String summaryForSurvey(Pro2SurveyRecord survey) {
    final evidence = evidenceForSurveyWithoutSummary(survey);
    final core = evidence['core'] as Map<String, Object?>;
    final details = evidence['details'] as Map<String, Object?>;
    if (survey.diseaseType == 'UC') {
      final bleeding = _severityLabel(
        _asInt(core['rectal_bleeding_0_3']) ?? survey.ucRectalBleeding ?? 0,
      );
      final stool = _ucStoolLabel(
        _asInt(core['bathroom_frequency_0_3']) ?? survey.ucStoolFrequency ?? 0,
      );
      final urgency = _severityLabel(_asInt(details['urgency_0_3']) ?? 0);
      return 'UC check-in: bleeding $bleeding, bathroom trips $stool, urgency $urgency.';
    }
    if (survey.diseaseType == 'IBS') {
      final total = survey.pro2Score.round();
      final severity = _ibsSssLabel(total);
      final pain = _asInt(core['ibs_pain_severity_0_100']) ?? 0;
      final bloating = _asInt(core['ibs_bloating_severity_0_100']) ?? 0;
      return 'IBS check-in: symptom severity $severity (score $total/500), '
          'pain ${pain == 0 ? "none" : pain}, bloating ${bloating == 0 ? "none" : bloating}.';
    }
    final pain = _severityLabel(
      _asInt(core['abdominal_pain_0_3']) ?? survey.cdAbdominalPain ?? 0,
    );
    final stools = _cdStoolLabel(
      _asInt(core['loose_stool_bucket']) ?? survey.cdStoolFrequency ?? 0,
    );
    final bloating = _severityLabel(_asInt(details['bloating_0_3']) ?? 0);
    return 'Crohn\'s check-in: belly pain $pain, loose stools $stools, bloating $bloating.';
  }

  static Map<String, Object?> evidenceForSurveyWithoutSummary(
    Pro2SurveyRecord survey,
  ) {
    final parsed = parseNotes(survey.notes);
    final rawDailyCore = Map<String, Object?>.from(
      parsed['daily_core'] as Map? ?? const {},
    );
    final rawDailyDetails = Map<String, Object?>.from(
      parsed['daily_details'] as Map? ?? const {},
    );
    return {
      'core': _normalizeDailyCore(
        survey: survey,
        rawDailyCore: rawDailyCore,
        rawDailyDetails: rawDailyDetails,
      ),
      'details': _normalizeDailyDetails(
        survey: survey,
        rawDailyCore: rawDailyCore,
        rawDailyDetails: rawDailyDetails,
      ),
    };
  }

  static Map<String, Object?> _normalizeDailyCore({
    required Pro2SurveyRecord survey,
    required Map<String, Object?> rawDailyCore,
    required Map<String, Object?> rawDailyDetails,
  }) {
    final core = Map<String, Object?>.from(rawDailyCore);
    final details = rawDailyDetails;
    if (survey.diseaseType == 'UC') {
      core['rectal_bleeding_0_3'] = _firstInt(core, details, const [
            'rectal_bleeding_0_3',
            'rectal_bleeding',
            'blood_0_3',
          ]) ??
          survey.ucRectalBleeding ??
          0;
      core['bathroom_frequency_0_3'] = _firstInt(core, details, const [
            'bathroom_frequency_0_3',
            'stool_frequency',
          ]) ??
          survey.ucStoolFrequency ??
          0;
      return core;
    }

    if (survey.diseaseType == 'IBS') {
      // IBS-SSS components stored in notes JSON with these keys.
      for (final key in const [
        'ibs_pain_severity_0_100',
        'ibs_pain_days_0_10',
        'ibs_bowel_satisfaction_0_100',
        'ibs_life_interference_0_100',
        'ibs_bloating_severity_0_100',
      ]) {
        core[key] = _firstInt(core, details, [key]) ?? 0;
      }
      return core;
    }

    core['abdominal_pain_0_3'] = _firstInt(core, details, const [
          'abdominal_pain_0_3',
          'abdominal_pain',
        ]) ??
        survey.cdAbdominalPain ??
        0;
    core['loose_stool_bucket'] = _firstInt(core, details, const [
          'loose_stool_bucket',
          'stool_frequency',
        ]) ??
        survey.cdStoolFrequency ??
        0;
    return core;
  }

  static Map<String, Object?> _normalizeDailyDetails({
    required Pro2SurveyRecord survey,
    required Map<String, Object?> rawDailyCore,
    required Map<String, Object?> rawDailyDetails,
  }) {
    final details = Map<String, Object?>.from(rawDailyDetails);
    final core = rawDailyCore;
    details['urgency_0_3'] =
        _firstInt(details, core, const ['urgency_0_3', 'urgency']) ?? 0;
    details['general_wellbeing_0_3'] = _firstInt(details, core, const [
      'general_wellbeing_0_3',
      'general_wellbeing',
    ]);

    if (survey.diseaseType == 'UC') {
      details['belly_or_rectal_pain_0_3'] = _firstInt(details, core, const [
            'belly_or_rectal_pain_0_3',
            'abdominal_pain_0_3',
            'abdominal_pain',
          ]) ??
          0;
    } else if (survey.diseaseType != 'IBS') {
      // CD and IC get the blood detail field.
      details['blood_0_3'] = _firstInt(details, core, const [
            'blood_0_3',
            'rectal_bleeding_0_3',
            'rectal_bleeding',
          ]) ??
          0;
    }
    // IBS details: no extra normalization needed — IBS core carries all components.
    return details;
  }

  static int? _firstInt(
    Map<String, Object?> primary,
    Map<String, Object?> secondary,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _asInt(primary[key]) ?? _asInt(secondary[key]);
      if (value != null) return value;
    }
    return null;
  }

  static Map<String, Object?> _legacyCoreFromSurvey(Pro2SurveyRecord survey) {
    if (survey.diseaseType == 'UC') {
      return {
        'rectal_bleeding_0_3': survey.ucRectalBleeding ?? 0,
        'bathroom_frequency_0_3': survey.ucStoolFrequency ?? 0,
      };
    }
    if (survey.diseaseType == 'IBS') {
      // IBS legacy path: all zeros; real data lives in notes JSON.
      return const {
        'ibs_pain_severity_0_100': 0,
        'ibs_pain_days_0_10': 0,
        'ibs_bowel_satisfaction_0_100': 0,
        'ibs_life_interference_0_100': 0,
        'ibs_bloating_severity_0_100': 0,
      };
    }
    return {
      'abdominal_pain_0_3': survey.cdAbdominalPain ?? 0,
      'loose_stool_bucket': survey.cdStoolFrequency ?? 0,
    };
  }

  static List<String> _redFlags({
    required String diseaseType,
    required Map<String, Object?> dailyCore,
    required Map<String, Object?> dailyDetails,
    required Map<String, Object?> weeklyQuality,
  }) {
    final flags = <String>[];

    if (diseaseType == 'IBS') {
      // Rectal bleeding is atypical for IBS and warrants clinical review.
      final ibsBleeding = _asInt(dailyDetails['ibs_rectal_bleeding']) ?? 0;
      if (ibsBleeding >= 1) flags.add('rectal_bleeding_ibs_atypical');
      // Pain severity ≥80/100 for more than 3 days is a high-acuity signal.
      final ibsPain = _asInt(dailyCore['ibs_pain_severity_0_100']) ?? 0;
      final ibsPainDays = _asInt(dailyCore['ibs_pain_days_0_10']) ?? 0;
      if (ibsPain >= 80 && ibsPainDays >= 3) {
        flags.add('severe_ibs_pain_prolonged');
      }
      if ((_asInt(weeklyQuality['weight_or_appetite_0_3']) ?? 0) >= 3) {
        flags.add('weight_loss');
      }
      if ((_asInt(weeklyQuality['medication_0_3']) ?? 0) >= 3) {
        flags.add('concerning_medication_side_effect');
      }
      return flags.toSet().toList(growable: false);
    }

    final bleeding = _asInt(dailyCore['rectal_bleeding_0_3']) ??
        _asInt(dailyDetails['blood_0_3']) ??
        0;
    if (bleeding >= 2) flags.add('blood_visible');
    if (bleeding >= 3) flags.add('heavy_bleeding');
    final cdPain = _asInt(dailyCore['abdominal_pain_0_3']) ?? 0;
    final ucPain = _asInt(dailyDetails['belly_or_rectal_pain_0_3']) ?? 0;
    if (cdPain >= 3 || ucPain >= 3) flags.add('severe_pain');
    if ((_asInt(dailyDetails['perianal_symptom_0_3']) ?? 0) >= 3) {
      flags.add('perianal_drainage_or_swelling');
    }
    if ((_asInt(weeklyQuality['weight_or_appetite_0_3']) ?? 0) >= 3) {
      flags.add('weight_loss');
    }
    if ((_asInt(weeklyQuality['medication_0_3']) ?? 0) >= 3) {
      flags.add('concerning_medication_side_effect');
    }
    return flags.toSet().toList(growable: false);
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return null;
  }

  static String _severityLabel(int value) => switch (value) {
        <= 0 => 'none',
        1 => 'mild',
        2 => 'moderate',
        _ => 'severe',
      };

  static String _cdStoolLabel(int value) => switch (value) {
        <= 0 => 'none',
        1 => '1-3',
        2 => '4-6',
        _ => '7+',
      };

  static String _ucStoolLabel(int value) => switch (value) {
        <= 0 => 'usual',
        1 => '1-2 more',
        2 => '3-4 more',
        _ => '5+ more',
      };

  // IBS-SSS total severity band (Francis et al. 1997 / Rome IV).
  static String _ibsSssLabel(int total) {
    if (total < 75) return 'minimal';
    if (total < 175) return 'mild';
    if (total < 300) return 'moderate';
    return 'severe';
  }

  // Compute IBS flare status from IBS-SSS components stored in the notes JSON.
  static bool ibsIsFlare(Map<String, Object?> core) {
    final painSeverity = (_asInt(core['ibs_pain_severity_0_100']) ?? 0).clamp(
      0,
      100,
    );
    final painDays = (_asInt(core['ibs_pain_days_0_10']) ?? 0).clamp(0, 10);
    final bowelSatisfaction =
        (_asInt(core['ibs_bowel_satisfaction_0_100']) ?? 0).clamp(0, 100);
    final lifeInterference =
        (_asInt(core['ibs_life_interference_0_100']) ?? 0).clamp(0, 100);
    final bloatingSeverity =
        (_asInt(core['ibs_bloating_severity_0_100']) ?? 0).clamp(0, 100);
    final total = painSeverity +
        painDays * 10 +
        bowelSatisfaction +
        lifeInterference +
        bloatingSeverity;
    return total >= Pro2SurveyRecord.ibsSssFlareThreshold;
  }
}
