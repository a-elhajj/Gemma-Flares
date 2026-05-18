import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/experiment_service.dart';
import '../../core/services/ibd_checkin_service.dart';
import '../../core/services/pro2_score_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CheckInScreen
//
// Daily PRO-2 survey for IBD symptom tracking.
//
// CD (Crohn's Disease) PRO-2:
//   - Abdominal pain score (0–3): None / Mild / Moderate / Severe
//   - Stool frequency beyond normal (0–4): 0 / 1 / 2 / 3 / 4+
//   - New rows use score_version cd_pro2_v2_pain2_stool1.
//   - Historical rows keep their stored score_version.
//
// UC (Ulcerative Colitis) PRO-2:
//   - Rectal bleeding (0–3): None / Streaks / Obvious / Mostly
//   - Stool frequency beyond normal (0–3): Normal / 1–2 more / 3–4 more / 5+
//   - Score = bleeding + stool_freq   [remission ≤1 with bleeding=0 & freq≤1]
//
// After submit: triggers FlareLabelService recompute for affected window.
// ─────────────────────────────────────────────────────────────────────────────

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  // Disease type — preloaded from last survey, changeable before submit.
  String _diseaseType = 'CD'; // default until loaded

  // CD choices
  int _cdPain = 0; // 0–3
  int _cdStool = 0; // 0–3
  int _cdUrgency = 0; // 0–3
  int _cdBloating = 0; // 0–3
  int _cdFatigue = 0; // 0–3
  int _cdBlood = 0; // 0–3
  int _cdPerianal = 0; // 0–3

  // UC choices
  int _ucBleeding = 0; // 0–3
  int _ucStool = 0; // 0–3
  int _ucUrgency = 0; // 0–3
  int _ucIncomplete = 0; // 0–3
  int _ucNocturnal = 0; // 0–3
  int _ucPain = 0; // 0–3

  // IBS-SSS choices (Rome IV / Francis 1997)
  int _ibsPainSeverity = 0; // VAS 0–100
  int _ibsPainDays = 0; // days with pain in past 10 days (0–10)
  int _ibsBowelSatisfaction = 0; // dissatisfaction 0–100
  int _ibsLifeInterference = 0; // life interference 0–100
  int _ibsBloatingSeverity = 0; // bloating severity 0–100

  int _weeklyActivity = 0; // 0–3
  int _weeklyFatigue = 0; // 0–3
  int _weeklySleep = 0; // 0–3
  int _weeklySocial = 0; // 0–3
  int _weeklyWeight = 0; // 0–3
  int _weeklyExtraintestinal = 0; // 0–3
  int _weeklyMedication = 0; // 0–3
  bool _includeDailyDetails = false;
  bool _includeWeeklyQuality = false;

  bool _submitting = false;
  String? _lastResult;
  String _checkInVariant = 'A';
  List<Pro2SurveyRecord> _recentSurveys = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    try {
      final surveys = await AppServices.wearableSampleRepository
          .getRecentPro2Surveys(limit: 7);
      final profile = await AppServices.profileService.loadProfile();
      final variant = await AppServices.experimentService
          .variantFor(ExperimentService.checkInLayout)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => 'A');
      unawaited(
        AppServices.experimentService.logExposure(
          experimentKey: ExperimentService.checkInLayout,
          eventName: 'checkin_variant_seen',
          metadata: const {'screen': 'checkin'},
        ).timeout(const Duration(milliseconds: 300), onTimeout: () {}),
      );
      if (!mounted) return;
      final surveyDisease = surveys.isEmpty
          ? null
          : _normalizeDiseaseType(surveys.first.diseaseType);
      final profileDisease = _normalizeDiseaseType(profile.diseaseType);
      setState(() {
        _recentSurveys = surveys;
        _checkInVariant = variant;
        _diseaseType = surveyDisease ?? profileDisease ?? _diseaseType;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _normalizeDiseaseType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final upper = raw.trim().toUpperCase();
    if (upper == 'CD' || upper == 'UC' || upper == 'IC' || upper == 'IBS') {
      return upper;
    }
    return null;
  }

  // ── Score computation ──────────────────────────────────────────────────────

  String get _scoreVersion => switch (_diseaseType) {
        'UC' => Pro2ScoreService.ucV1BleedingStool,
        'IBS' => Pro2SurveyRecord.ibsSssV1,
        _ => Pro2ScoreService.defaultCdScoreVersion,
      };

  int get _cdScore => Pro2ScoreService.computeCdScore(
        abdominalPain: _cdPain,
        stoolFrequency: _cdStool,
        scoreVersion: _scoreVersion,
      ).round();
  int get _ucScore => _ucBleeding + _ucStool;
  int get _ibsSssScore => Pro2SurveyRecord.ibsSssTotal(
        painSeverity: _ibsPainSeverity,
        painDays: _ibsPainDays,
        bowelSatisfaction: _ibsBowelSatisfaction,
        lifeInterference: _ibsLifeInterference,
        bloatingSeverity: _ibsBloatingSeverity,
      ).round();
  int get _score => switch (_diseaseType) {
        'UC' => _ucScore,
        'IBS' => _ibsSssScore,
        _ => _cdScore,
      };

  bool get _isFlare => switch (_diseaseType) {
        'CD' => _cdScore >= 8,
        'IBS' => _ibsSssScore >= Pro2SurveyRecord.ibsSssFlareThreshold,
        // UC: score > 1 OR bleeding > 0 OR stool > 1
        _ => _ucScore > 1 || _ucBleeding > 0 || _ucStool > 1,
      };

  bool get _weeklyDue {
    final today = _startOfLocalDay(DateTime.now());
    for (final survey in _recentSurveys) {
      if (!IbdCheckInService.hasWeeklyQuality(survey)) continue;
      final surveyDate = DateTime.tryParse('${survey.surveyDate}T00:00:00');
      if (surveyDate == null) continue;
      if (today.difference(surveyDate).inDays < 7) {
        return false;
      }
    }
    return true;
  }

  Color _scoreColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_scoreLabel) {
      case 'Remission':
        return Colors.green.shade600;
      case 'Mild flare':
        return Colors.orange.shade700;
      default:
        return cs.error;
    }
  }

  String get _scoreLabel {
    if (_diseaseType == 'UC') {
      return Pro2ScoreService.describeUcSeverity(
        score: _ucScore.toDouble(),
        rectalBleeding: _ucBleeding,
        stoolFrequency: _ucStool,
      );
    }
    if (_diseaseType == 'IBS') {
      final total = _ibsSssScore;
      if (total < 75) return 'Minimal symptoms';
      if (total < 175) return 'Remission';
      if (total < 300) return 'Mild flare';
      if (total < 400) return 'Moderate flare';
      return 'Severe flare';
    }
    return Pro2ScoreService.describeCdSeverity(
      score: _cdScore.toDouble(),
      scoreVersion: _scoreVersion,
    );
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final now = DateTime.now().toUtc();
      final todayDate = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final record = Pro2SurveyRecord(
        surveyDate: todayDate,
        diseaseType: _diseaseType,
        cdAbdominalPain:
            _diseaseType == 'CD' || _diseaseType == 'IC' ? _cdPain : null,
        cdStoolFrequency:
            _diseaseType == 'CD' || _diseaseType == 'IC' ? _cdStool : null,
        ucRectalBleeding: _diseaseType == 'UC' ? _ucBleeding : null,
        ucStoolFrequency: _diseaseType == 'UC' ? _ucStool : null,
        pro2Score: _score.toDouble(),
        isFlare: _isFlare,
        scoreVersion: _scoreVersion,
        notes: IbdCheckInService.encodeNotes(
          diseaseType: _diseaseType,
          dailyCore: _dailyCoreJson(),
          dailyDetails: _includeDailyDetails ? _dailyDetailsJson() : const {},
          weeklyQuality:
              _includeWeeklyQuality ? _weeklyQualityJson() : const {},
          completedSections: [
            'core',
            if (_includeDailyDetails) 'daily_details',
            if (_includeWeeklyQuality) 'weekly_quality',
          ],
        ),
        createdAt: now,
      );

      final surveyId =
          await AppServices.wearableSampleRepository.insertPro2Survey(record);
      try {
        await AppServices.ragMemoryService.writeAndVerify(
          transactionId: 'checkin_tx_$surveyId',
          sourceType: 'pro2_survey',
          sourceId: '$surveyId',
          text: IbdCheckInService.memoryTextForSurvey(
            surveyId: surveyId,
            survey: record,
          ),
          metadata: IbdCheckInService.memoryMetadataForSurvey(
            surveyId: surveyId,
            survey: record,
          ),
        );
      } catch (_) {
        // Keep the primary check-in save path non-blocking when RAG indexing
        // is temporarily unavailable.
      }
      try {
        await AppServices.ragIndexService.indexCheckIn(surveyId, record);
      } catch (_) {
        // Vector RAG is best-effort beside the durable structured save.
      }

      // Recompute flare labels for the rolling 14-day window around today.
      try {
        await AppServices.analyticsRefreshService
            .refreshForCheckIn(surveyDate: todayDate)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Saving the user's check-in should not fail because analytics refresh
        // is unavailable or slow.
      }
      _refreshGuidance('checkin_saved');

      if (!mounted) return;
      final flags = IbdCheckInService.evidenceForSurvey(record)['red_flags']
          as List<Object?>;
      setState(() {
        _lastResult = flags.isEmpty
            ? 'Saved to Health > Check-ins. Gemma can use this in your brief and chat. Today looks like $_scoreLabel.'
            : 'Saved to Health > Check-ins. This may be worth contacting your GI team about. If symptoms feel severe, urgent, or unsafe, seek urgent care.';
        _cdPain = 0;
        _cdStool = 0;
        _cdUrgency = 0;
        _cdBloating = 0;
        _cdFatigue = 0;
        _cdBlood = 0;
        _cdPerianal = 0;
        _ucBleeding = 0;
        _ucStool = 0;
        _ucUrgency = 0;
        _ucIncomplete = 0;
        _ucNocturnal = 0;
        _ucPain = 0;
        _ibsPainSeverity = 0;
        _ibsPainDays = 0;
        _ibsBowelSatisfaction = 0;
        _ibsLifeInterference = 0;
        _ibsBloatingSeverity = 0;
        _weeklyActivity = 0;
        _weeklyFatigue = 0;
        _weeklySleep = 0;
        _weeklySocial = 0;
        _weeklyWeight = 0;
        _weeklyExtraintestinal = 0;
        _weeklyMedication = 0;
        _includeDailyDetails = false;
        _includeWeeklyQuality = false;
      });
      await _loadRecent();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              "We couldn't save your check-in. Please try again.",
            ),
            action: SnackBarAction(label: 'Retry', onPressed: _submit),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Guidance is cached background support; saving the check-in already won.
    }
  }

  String _formatDate(String dateStr) {
    final parts = dateStr.split('-');
    if (parts.length != 3) return dateStr;
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = int.tryParse(parts[1]) ?? 0;
    return '${months[month]} ${int.tryParse(parts[2]) ?? parts[2]}';
  }

  DateTime _startOfLocalDay(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  Map<String, Object?> _dailyCoreJson() {
    if (_diseaseType == 'UC') {
      return {
        'rectal_bleeding_0_3': _ucBleeding,
        'bathroom_frequency_0_3': _ucStool,
      };
    }
    if (_diseaseType == 'IBS') {
      return {
        'ibs_pain_severity_0_100': _ibsPainSeverity,
        'ibs_pain_days_0_10': _ibsPainDays,
        'ibs_bowel_satisfaction_0_100': _ibsBowelSatisfaction,
        'ibs_life_interference_0_100': _ibsLifeInterference,
        'ibs_bloating_severity_0_100': _ibsBloatingSeverity,
      };
    }
    return {'abdominal_pain_0_3': _cdPain, 'loose_stool_bucket': _cdStool};
  }

  Map<String, Object?> _dailyDetailsJson() {
    if (_diseaseType == 'UC') {
      return {
        'urgency_0_3': _ucUrgency,
        'incomplete_evacuation_0_3': _ucIncomplete,
        'nocturnal_bathroom_0_3': _ucNocturnal,
        'belly_or_rectal_pain_0_3': _ucPain,
      };
    }
    if (_diseaseType == 'IBS') {
      // IBS details: no additional fields beyond core; return empty for now.
      return const {};
    }
    return {
      'urgency_0_3': _cdUrgency,
      'bloating_0_3': _cdBloating,
      'fatigue_0_3': _cdFatigue,
      'blood_0_3': _cdBlood,
      'perianal_symptom_0_3': _cdPerianal,
    };
  }

  Map<String, Object?> _weeklyQualityJson() => {
        'activity_limit_0_3': _weeklyActivity,
        'fatigue_days_0_3': _weeklyFatigue,
        'sleep_impact_0_3': _weeklySleep,
        'social_impact_0_3': _weeklySocial,
        'weight_or_appetite_0_3': _weeklyWeight,
        'extraintestinal_0_3': _weeklyExtraintestinal,
        'medication_0_3': _weeklyMedication,
      };

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Text('Daily Check-In', style: tt.headlineMedium),
          const SizedBox(height: 4),
          Text(
            _checkInVariant == 'B'
                ? 'Two quick questions, plus optional details if today feels different.'
                : 'A quick check-in helps your score, confidence, and Gemma brief stay grounded.',
            style: tt.bodySmall?.copyWith(color: cs.outline),
          ),

          const SizedBox(height: 20),

          // ── Disease type selector ──────────────────────────────────────────
          _SectionHeader(
            title: 'Disease type',
            icon: Icons.medical_information_outlined,
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'CD', label: Text("Crohn's")),
              ButtonSegment(value: 'UC', label: Text('Colitis')),
              ButtonSegment(value: 'IBS', label: Text('IBS')),
            ],
            selected: {_diseaseType},
            onSelectionChanged: (set) => setState(() {
              _diseaseType = set.first;
            }),
          ),

          const SizedBox(height: 24),

          // ── Disease-specific questions ─────────────────────────────────────
          if (_diseaseType == 'UC')
            ..._ucQuestions(cs, tt)
          else if (_diseaseType == 'IBS')
            ..._ibsQuestions(cs, tt)
          else
            ..._cdQuestions(cs, tt), // CD and IC

          if (_weeklyDue) ...[
            const SizedBox(height: 12),
            _WeeklyQualitySection(
              expanded: _includeWeeklyQuality,
              onExpansionChanged: (value) =>
                  setState(() => _includeWeeklyQuality = value),
              activity: _weeklyActivity,
              fatigue: _weeklyFatigue,
              sleep: _weeklySleep,
              social: _weeklySocial,
              weight: _weeklyWeight,
              extraintestinal: _weeklyExtraintestinal,
              medication: _weeklyMedication,
              onActivityChanged: (v) => setState(() => _weeklyActivity = v),
              onFatigueChanged: (v) => setState(() => _weeklyFatigue = v),
              onSleepChanged: (v) => setState(() => _weeklySleep = v),
              onSocialChanged: (v) => setState(() => _weeklySocial = v),
              onWeightChanged: (v) => setState(() => _weeklyWeight = v),
              onExtraintestinalChanged: (v) =>
                  setState(() => _weeklyExtraintestinal = v),
              onMedicationChanged: (v) => setState(() => _weeklyMedication = v),
              colorScheme: cs,
              textTheme: tt,
            ),
          ],

          const SizedBox(height: 20),

          // ── Score display ──────────────────────────────────────────────────
          _ScoreCard(
            score: _score,
            label: _scoreLabel,
            color: _scoreColor(context),
          ),

          const SizedBox(height: 20),

          // ── Submit ─────────────────────────────────────────────────────────
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(_submitting ? 'Saving...' : 'Submit check-in'),
          ),
          TextButton(
            onPressed: _submitting
                ? null
                : () => setState(() => _lastResult = 'Skipped for today.'),
            child: const Text('Skip for today'),
          ),

          if (_lastResult != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.secondaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_lastResult!, style: tt.bodyMedium),
            ),
          ],

          // ── Recent check-ins ───────────────────────────────────────────────
          if (_recentSurveys.isNotEmpty) ...[
            const SizedBox(height: 28),
            _SectionHeader(
              title: 'Recent check-ins',
              icon: Icons.history_rounded,
            ),
            const SizedBox(height: 8),
            ..._recentSurveys.map(
              (s) => _RecentSurveyTile(survey: s, formatDate: _formatDate),
            ),
          ],

          const SizedBox(height: 24),
          Text(
            'Daily check-ins help compare symptom patterns over time. This is not a diagnosis.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── CD question widgets ────────────────────────────────────────────────────

  List<Widget> _cdQuestions(ColorScheme cs, TextTheme tt) {
    const painLabels = ['None', 'Mild', 'Moderate', 'Severe'];

    return [
      _SectionHeader(title: "Crohn's basics", icon: Icons.quiz_outlined),
      const SizedBox(height: 12),
      _ChoiceQuestion(
        question: 'Belly pain today?',
        value: _cdPain,
        labels: painLabels,
        onChanged: (v) => setState(() => _cdPain = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _ChoiceQuestion(
        question: 'Loose or watery stools today?',
        value: _cdStool,
        labels: const ['None', '1-3', '4-6', '7+'],
        onChanged: (v) => setState(() => _cdStool = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 12),
      _OptionalDetailsSection(
        expanded: _includeDailyDetails,
        onExpansionChanged: (value) =>
            setState(() => _includeDailyDetails = value),
        children: [
          _ChoiceQuestion(
            question: 'Bathroom urgency today?',
            value: _cdUrgency,
            labels: painLabels,
            onChanged: (v) => setState(() => _cdUrgency = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Bloating today?',
            value: _cdBloating,
            labels: painLabels,
            onChanged: (v) => setState(() => _cdBloating = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Fatigue today?',
            value: _cdFatigue,
            labels: painLabels,
            onChanged: (v) => setState(() => _cdFatigue = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Any blood in stool today?',
            value: _cdBlood,
            labels: const ['No', 'Streaks', 'Obvious', 'Mostly blood'],
            onChanged: (v) => setState(() => _cdBlood = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Any pain or drainage around the anus?',
            value: _cdPerianal,
            labels: const ['No', 'Mild discomfort', 'Pain', 'Drainage'],
            onChanged: (v) => setState(() => _cdPerianal = v),
            colorScheme: cs,
            textTheme: tt,
          ),
        ],
      ),
    ];
  }

  // ── UC question widgets ────────────────────────────────────────────────────

  List<Widget> _ucQuestions(ColorScheme cs, TextTheme tt) {
    const bleedingLabels = ['None', 'Streaks', 'Obvious', 'Mostly blood'];
    const stoolLabels = ['Normal', '1–2 more', '3–4 more', '5+ more'];

    return [
      _SectionHeader(title: 'Colitis basics', icon: Icons.quiz_outlined),
      const SizedBox(height: 12),
      _ChoiceQuestion(
        question: 'Any bleeding today?',
        value: _ucBleeding,
        labels: bleedingLabels,
        onChanged: (v) => setState(() => _ucBleeding = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _ChoiceQuestion(
        question: 'Bathroom trips compared to your usual?',
        value: _ucStool,
        labels: stoolLabels,
        onChanged: (v) => setState(() => _ucStool = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 12),
      _OptionalDetailsSection(
        expanded: _includeDailyDetails,
        onExpansionChanged: (value) =>
            setState(() => _includeDailyDetails = value),
        children: [
          _ChoiceQuestion(
            question: 'Urgency today?',
            value: _ucUrgency,
            labels: const ['None', 'Mild', 'Moderate', 'Severe'],
            onChanged: (v) => setState(() => _ucUrgency = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Feeling like you could not fully empty?',
            value: _ucIncomplete,
            labels: const ['None', 'Mild', 'Moderate', 'Severe'],
            onChanged: (v) => setState(() => _ucIncomplete = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Woke up at night to use the bathroom?',
            value: _ucNocturnal,
            labels: const ['No', 'Once', '2 times', '3+ times'],
            onChanged: (v) => setState(() => _ucNocturnal = v),
            colorScheme: cs,
            textTheme: tt,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Belly or rectal pain today?',
            value: _ucPain,
            labels: const ['None', 'Mild', 'Moderate', 'Severe'],
            onChanged: (v) => setState(() => _ucPain = v),
            colorScheme: cs,
            textTheme: tt,
          ),
        ],
      ),
    ];
  }

  // ── IBS question widgets (IBS-SSS, Rome IV / Francis 1997) ────────────────
  //
  // Five components, each mapped to a discrete slider:
  //   pain severity   0–100 (VAS; sliders in steps of 10)
  //   pain days       0–10  (days with pain in past 10 days)
  //   bowel habit dissatisfaction  0–100
  //   life interference            0–100
  //   bloating severity            0–100
  // Total 0–500; flare ≥175 (Rome IV active IBS threshold).

  List<Widget> _ibsQuestions(ColorScheme cs, TextTheme tt) {
    return [
      _SectionHeader(title: 'IBS symptom check', icon: Icons.quiz_outlined),
      const SizedBox(height: 8),
      Text(
        'Rate each on a scale from 0 (none) to 100 (worst imaginable).',
        style: tt.bodySmall?.copyWith(color: cs.outline),
      ),
      const SizedBox(height: 16),
      _SliderQuestion(
        question: 'Belly pain or discomfort — how bad has it been?',
        hint: '0 = no pain · 100 = worst imaginable',
        value: _ibsPainSeverity,
        min: 0,
        max: 100,
        divisions: 10,
        onChanged: (v) => setState(() => _ibsPainSeverity = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _SliderQuestion(
        question: 'How many days in the past 10 days did you have pain?',
        hint: '0 = no days · 10 = every day',
        value: _ibsPainDays,
        min: 0,
        max: 10,
        divisions: 10,
        onChanged: (v) => setState(() => _ibsPainDays = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _SliderQuestion(
        question: 'How unhappy are you with your bowel habits?',
        hint: '0 = completely happy · 100 = extremely unhappy',
        value: _ibsBowelSatisfaction,
        min: 0,
        max: 100,
        divisions: 10,
        onChanged: (v) => setState(() => _ibsBowelSatisfaction = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _SliderQuestion(
        question: 'How much is IBS interfering with your daily life?',
        hint: '0 = not at all · 100 = extremely',
        value: _ibsLifeInterference,
        min: 0,
        max: 100,
        divisions: 10,
        onChanged: (v) => setState(() => _ibsLifeInterference = v),
        colorScheme: cs,
        textTheme: tt,
      ),
      const SizedBox(height: 16),
      _SliderQuestion(
        question: 'Bloating or distension — how bad today?',
        hint: '0 = none · 100 = severe',
        value: _ibsBloatingSeverity,
        min: 0,
        max: 100,
        divisions: 10,
        onChanged: (v) => setState(() => _ibsBloatingSeverity = v),
        colorScheme: cs,
        textTheme: tt,
      ),
    ];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SectionHeader
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Text(title, style: tt.titleMedium?.copyWith(color: cs.primary)),
      ],
    );
  }
}

class _OptionalDetailsSection extends StatelessWidget {
  const _OptionalDetailsSection({
    required this.expanded,
    required this.onExpansionChanged,
    required this.children,
  });

  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        title: const Text('Add details'),
        subtitle: const Text('Optional, useful if today feels different.'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: children,
      ),
    );
  }
}

class _WeeklyQualitySection extends StatelessWidget {
  const _WeeklyQualitySection({
    required this.expanded,
    required this.onExpansionChanged,
    required this.activity,
    required this.fatigue,
    required this.sleep,
    required this.social,
    required this.weight,
    required this.extraintestinal,
    required this.medication,
    required this.onActivityChanged,
    required this.onFatigueChanged,
    required this.onSleepChanged,
    required this.onSocialChanged,
    required this.onWeightChanged,
    required this.onExtraintestinalChanged,
    required this.onMedicationChanged,
    required this.colorScheme,
    required this.textTheme,
  });

  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final int activity;
  final int fatigue;
  final int sleep;
  final int social;
  final int weight;
  final int extraintestinal;
  final int medication;
  final ValueChanged<int> onActivityChanged;
  final ValueChanged<int> onFatigueChanged;
  final ValueChanged<int> onSleepChanged;
  final ValueChanged<int> onSocialChanged;
  final ValueChanged<int> onWeightChanged;
  final ValueChanged<int> onExtraintestinalChanged;
  final ValueChanged<int> onMedicationChanged;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: colorScheme.secondaryContainer.withValues(alpha: 0.22),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        title: const Text('Weekly life impact check'),
        subtitle: const Text('Optional context for your GI summary.'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _ChoiceQuestion(
            question: 'Did symptoms limit normal activities this week?',
            value: activity,
            labels: const ['Not at all', 'A little', 'Some days', 'Most days'],
            onChanged: onActivityChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'How many days did fatigue affect you?',
            value: fatigue,
            labels: const ['0 days', '1-2 days', '3-4 days', '5+ days'],
            onChanged: onFatigueChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Did symptoms affect sleep this week?',
            value: sleep,
            labels: const ['No', '1 night', '2-3 nights', '4+ nights'],
            onChanged: onSleepChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Did symptoms stop you from going out?',
            value: social,
            labels: const ['No', 'A little', 'Some plans', 'Most plans'],
            onChanged: onSocialChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Any unintentional weight loss or low appetite?',
            value: weight,
            labels: const [
              'No',
              'Mild appetite drop',
              'Noticeable drop',
              'Weight loss',
            ],
            onChanged: onWeightChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Any joint pain, eye irritation, mouth sores, or rash?',
            value: extraintestinal,
            labels: const ['No', 'Mild', 'Moderate', 'Severe/new'],
            onChanged: onExtraintestinalChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          const SizedBox(height: 16),
          _ChoiceQuestion(
            question: 'Any medication side effects or missed doses?',
            value: medication,
            labels: const [
              'No',
              'Missed dose',
              'Possible side effect',
              'Concerning',
            ],
            onChanged: onMedicationChanged,
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ChoiceQuestion — labeled tap choices
// ─────────────────────────────────────────────────────────────────────────────

class _ChoiceQuestion extends StatelessWidget {
  const _ChoiceQuestion({
    required this.question,
    required this.value,
    required this.labels,
    required this.onChanged,
    required this.colorScheme,
    required this.textTheme,
  });

  final String question;
  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question, style: textTheme.bodyMedium),
        const SizedBox(height: 8),
        Semantics(
          label: question,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var index = 0; index < labels.length; index++)
                ChoiceChip(
                  label: Text(labels[index]),
                  selected: value == index,
                  onSelected: (_) => onChanged(index),
                  showCheckmark: false,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SliderQuestion — continuous 0–max integer slider used for IBS-SSS
// ─────────────────────────────────────────────────────────────────────────────

class _SliderQuestion extends StatelessWidget {
  const _SliderQuestion({
    required this.question,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.colorScheme,
    required this.textTheme,
  });

  final String question;
  final String hint;
  final int value;
  final int min;
  final int max;
  final int divisions;
  final ValueChanged<int> onChanged;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question, style: textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(
          hint,
          style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
        ),
        Semantics(
          label: '$question: $value',
          slider: true,
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            label: value.toString(),
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        Text(
          '$value / $max',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScoreCard — daily symptom score summary
// ─────────────────────────────────────────────────────────────────────────────

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({
    required this.score,
    required this.label,
    required this.color,
  });

  final int score;
  final String label;
  final Color color;

  // Returns the score's max value for contextual display (IBS-SSS: 500, others: 3).
  int get _maxScore => score > 10 ? 500 : 3;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // M3 Card with tonal elevation for the score panel.
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Score indicator badge — M3 tonal surface circle.
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$score',
                  style: tt.headlineSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Today\'s symptom score (/$_maxScore)',
                    style: tt.bodySmall?.copyWith(color: cs.outline),
                  ),
                  Text(
                    label,
                    style: tt.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // Semantic color indicator chip — accessible without color alone.
            Icon(
              score == 0 || label == 'Remission' || label == 'Minimal symptoms'
                  ? Icons.check_circle_outline_rounded
                  : Icons.warning_amber_rounded,
              color: color,
              size: 20,
              semanticLabel: label,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _RecentSurveyTile
// ─────────────────────────────────────────────────────────────────────────────

class _RecentSurveyTile extends StatelessWidget {
  const _RecentSurveyTile({required this.survey, required this.formatDate});

  final Pro2SurveyRecord survey;
  final String Function(String) formatDate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isFlare = survey.isFlare;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isFlare
                  ? cs.errorContainer.withValues(alpha: 0.5)
                  : cs.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              survey.pro2Score.toInt().toString(),
              style: tt.labelLarge?.copyWith(
                color: isFlare ? cs.error : cs.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formatDate(survey.surveyDate), style: tt.bodyMedium),
                Text(
                  '${survey.diseaseType} · ${survey.scoreVersion.contains("v2") ? "current scoring" : "legacy scoring"} · ${isFlare ? "Flare" : "Remission"}',
                  style: tt.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
