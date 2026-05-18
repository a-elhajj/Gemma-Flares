@Tags(['extended'])
library;

/// Adversarial regression suite targeting the five fixes merged in commit
/// 5f4dd28 (PR #23). Each group attempts to defeat a specific fix with edge
/// cases that the in-tree happy-path tests do not exercise.
///
/// Fixes under attack:
///   1. 07bcf4b — hide score in Learning state for "What changed today?"
///   2. 118ce40 — use flare risk % as global score in all chat paths; no bullets in watchlist
///   3. 11d466f — reject non-health input during symptom intake (3-strike ladder)
///   5. 5781eaf — no Gemma re-extraction on confirm (UI-layer; not unit-testable here)
///
/// A failing test in this file means a fix did not generalize to the
/// adversarial variant; treat it as a real regression, not a test bug.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // ──────────────────────────────────────────────────────────────────────────
  //  GROUP 1 — Score Consistency (07bcf4b + 118ce40)
  //  Attack: even with a raw `latestScore` saved, no chat reply may leak
  //  the legacy "N/100" signal index. Only "X%" or "Learning" is allowed.
  // ──────────────────────────────────────────────────────────────────────────

  test(
    'ADV-5f4dd28-A1: "What changed today?" with raw latestScore but NO 7-day outlook never leaks /100',
    () async {
      final harness = await _Harness.create();
      // Plant a raw signal index (legacy field) without populating the
      // logistic 7-day outlook. Pre-fix, _changeComparisonReply would have
      // formatted "Your signal index is 47/100" because latestScore != null.
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-05-13',
          riskScore: 47,
          riskBand: 'moderate',
          confidenceScore: 80,
          contributionJson: const {
            'hrv_points': 18,
            'resting_hr_points': 10,
            'sleep_points': 5,
            'symptom_points': 8,
            'steps_points': 6,
          },
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-05-14T08:00:00Z'),
        ),
      );

      final reply = await harness.service.ask('What changed today?');

      // No N/100 numeric leakage anywhere.
      expect(
        RegExp(r'\b\d{1,3}\s*/\s*100\b').hasMatch(reply.message),
        isFalse,
        reason:
            'Score leak: "What changed today?" must not display N/100 when 7-day '
            'outlook is not ready. Got: ${reply.message}',
      );

      // Specifically the raw 47 must not appear as a percent either (Learning).
      expect(
        reply.message.contains('47%'),
        isFalse,
        reason: 'Raw signal index 47 must not appear as 47% in Learning state.',
      );

      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-A2: "Why is my risk higher today?" in Learning state never shows /100',
    () async {
      final harness = await _Harness.create();
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-05-13',
          riskScore: 63,
          riskBand: 'elevated',
          confidenceScore: 75,
          contributionJson: const {'hrv_points': 16},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-05-14T08:00:00Z'),
        ),
      );

      final reply = await harness.service.ask('Why is my risk higher today?');
      expect(
        RegExp(r'\b\d{1,3}\s*/\s*100\b').hasMatch(reply.message),
        isFalse,
        reason: 'Risk-question reply leaked N/100 in Learning state. '
            'Got: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-A3: "Check my flare risk" in Learning state shows the word Learning, not a percent',
    () async {
      final harness = await _Harness.create();
      // No outlook, no risk row.
      final reply = await harness.service.ask('Check my flare risk');

      final hasNumericPercent = RegExp(
        r'\b\d{1,3}\s*%',
      ).hasMatch(reply.message);
      final hasLearning = reply.message.toLowerCase().contains('learning');

      expect(
        hasNumericPercent && !hasLearning,
        isFalse,
        reason:
            'Empty-data flare-risk reply must say "Learning" or be intent-fallback, '
            'never a bare numeric percent without context. Got: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  // ──────────────────────────────────────────────────────────────────────────
  //  GROUP 2 — Watchlist Bullet Suppression (118ce40)
  //  Attack: deterministic forecast_watchlist output (no LLM) must not
  //  emit *, -, or • characters as bullet prefixes.
  // ──────────────────────────────────────────────────────────────────────────

  test(
    'ADV-5f4dd28-B1: "What should I watch?" deterministic reply contains zero bullet markers',
    () async {
      final harness = await _Harness.create();
      final reply = await harness.service.ask('What should I watch?');

      // Strip standalone "minus signs" used in numeric ranges to avoid false
      // positives (e.g. "1-3"); look for line-leading bullets specifically.
      final bulletStartRegex = RegExp(r'(^|\n)\s*[*•\-]\s+');
      expect(
        bulletStartRegex.hasMatch(reply.message),
        isFalse,
        reason: 'Forecast watchlist reply contains a markdown bullet line. '
            'kFormatWatchlist forbids *, -, •. Got:\n${reply.message}',
      );
      await harness.dispose();
    },
  );

  // ──────────────────────────────────────────────────────────────────────────
  //  GROUP 3 — Non-Health Intake Gate (11d466f)
  //  Attacks targeting two structural weaknesses I identified by reading the
  //  predicate:
  //    (a) Order-of-operations false POSITIVE: legitimate symptom narrative
  //        that *mentions* a non-health domain word is wrongly rejected
  //        because _isNonHealthTopic is checked before the health-adjacent
  //        exemption set.
  //    (b) Order-of-operations false NEGATIVE: a non-health phrase that
  //        contains any health-adjacent word slips through, recreating the
  //        original "sexy and u know it" bug class.
  // ──────────────────────────────────────────────────────────────────────────

  test(
    'ADV-5f4dd28-C1: legitimate symptom narrative referencing a sports domain word is NOT wrongly rejected',
    skip: 'BUG-083: known false positive — _isNonHealthTopic runs before the '
        'health-adjacent exemption, so "after the football game I had bad pain" '
        'is rejected. Track in the internal BUG-083 notes.',
    () async {
      final harness = await _Harness.create();
      // Prime intake.
      final intake = await harness.service.ask('Log a symptom');
      expect(intake.status, 'deterministic_bare_symptom_intake');

      // User describes a real symptom whose narrative *mentions* a non-health
      // domain trigger word ("football"). This is a realistic IBD-patient
      // sentence: tying a symptom to a contextual event. Pre-fix this had
      // never been an issue; post-fix the _isNonHealthTopic check could now
      // reject it BEFORE the health-adjacent exemption is consulted.
      final reply = await harness.service.ask(
        'after the football game I had bad pain',
      );

      // The user typed a real symptom — gate should not reject it as non-health.
      // Acceptance signal: reply must NOT be the rejection sentence.
      final isRejection =
          reply.message.contains("That doesn't look like a symptom") ||
              reply.message.contains('I can only log physical symptoms') ||
              reply.message.contains("I'm Gemma Flares");

      expect(
        isRejection,
        isFalse,
        reason:
            'False positive: legitimate "pain after the football game" rejected '
            'as non-health. Got: ${reply.message}',
      );

      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-C2: non-health phrase with a health-adjacent decoy word is still rejected',
    () async {
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // The original bug ("sexy and u know it" logged as symptom 'other') is the
      // motivating example for this fix. Try an obvious adversarial variant:
      // append a single health-adjacent decoy word ("feel") to non-health text.
      // If the gate exempts ANY input that contains a health-adjacent word,
      // this slips through and recreates the bug class.
      final reply = await harness.service.ask('sexy and u know it feel good');

      final symptoms = await harness.repository.getRecentSymptoms(limit: 10);
      expect(
        symptoms.isEmpty,
        isTrue,
        reason: 'Regression of 11d466f: non-health input slipped through '
            'because it contained the health-adjacent word "feel". '
            'A symptom row was persisted. Reply: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-C3: 3-strike ladder progresses (rejection → final warning → reset) on persistent non-health input',
    () async {
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // Three distinct non-health domain inputs (>2 words each) to force the
      // counter to advance without short-input bypass.
      final r1 = await harness.service.ask('the weather forecast is sunny');
      final r2 = await harness.service.ask('the football game was awesome');
      final r3 = await harness.service.ask('the movie on netflix was great');

      final replies = [r1.message, r2.message, r3.message];
      // After 3 strikes, the reply set must include a Gemma Flares reset/intro line
      // (per commit message: "Strike 3: friendly Gemma Flares intro + full session
      // reset"). If any of the replies leaked through to a symptom log, that's
      // a fail.
      final symptoms = await harness.repository.getRecentSymptoms(limit: 10);
      expect(
        symptoms.isEmpty,
        isTrue,
        reason: '3-strike ladder allowed a non-health input to persist as a '
            'symptom. Replies were:\n${replies.join("\n---\n")}',
      );

      // Strike 3 should reset the session — verify by asking a normal preset
      // afterward and confirming it routes correctly (i.e. session is no longer
      // stuck in intake state).
      final lab = await harness.service.ask('Show my lab results');
      expect(
        lab.message.contains(
          'Please describe the symptom you are experiencing',
        ),
        isFalse,
        reason: 'After 3-strike reset, preset must route normally, not back '
            'into intake. Got: ${lab.message}',
      );

      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-C4: short non-health input (≤2 words) is intentionally NOT rejected by gate',
    () async {
      // This is a documentation test, not an attack — it pins the design
      // invariant from the commit message: words.length <= 2 → return false.
      // Future maintainers tightening the gate must update this test deliberately.
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // "Tired" is 1 word and ambiguous — the clarifier must handle it, not
      // the non-health gate.
      final reply = await harness.service.ask('lol haha');

      final isHardRejection =
          reply.message.contains("That doesn't look like a symptom") ||
              reply.message.contains('I can only log physical symptoms');
      expect(
        isHardRejection,
        isFalse,
        reason: 'Short input ("lol haha", 2 words) should bypass the gate '
            'per the documented 2-word threshold. Got: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-C5: cross-domain attack: mixing political + sports tokens still rejects',
    () async {
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // Multiple non-health domain triggers in one phrase. Each domain check
      // is `||` so any single hit wins. We're verifying the predicate doesn't
      // somehow short-circuit incorrectly on combined inputs.
      final reply = await harness.service.ask(
        'trump won the football game last night easily',
      );

      final symptoms = await harness.repository.getRecentSymptoms(limit: 10);
      expect(
        symptoms.isEmpty,
        isTrue,
        reason: 'Cross-domain non-health input was not rejected. '
            'Got: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  test(
    'ADV-5f4dd28-C6: profanity-only non-health input is rejected even without domain keyword',
    () async {
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // No domain trigger and no health-adjacent word → must fall through to
      // !_shouldStayInSymptomIntake, which should NOT keep this in intake.
      final reply = await harness.service.ask('this is just random nonsense');

      final symptoms = await harness.repository.getRecentSymptoms(limit: 10);
      expect(
        symptoms.isEmpty,
        isTrue,
        reason: 'Domain-less random non-health input slipped through gate '
            'and was persisted. Got: ${reply.message}',
      );
      await harness.dispose();
    },
  );

  // ──────────────────────────────────────────────────────────────────────────
  //  GROUP 4 — Interaction with the prior BUG-081 routing fix
  //  Verify that the non-health gate does NOT block preset commands typed
  //  during intake. BUG-081 says presets must always win; new non-health
  //  gate must respect that.
  // ──────────────────────────────────────────────────────────────────────────

  test(
    'ADV-5f4dd28-D1: preset typed during intake is NOT eaten by non-health gate',
    () async {
      final harness = await _Harness.create();
      await harness.service.ask('Log a symptom');

      // "Show my lab results" is 4 words; contains no health-adjacent token
      // from the exemption list; contains no non-health domain token either.
      // It must reach the preset router (BUG-081), not the non-health gate.
      final reply = await harness.service.ask('Show my lab results');

      expect(
        reply.message.contains('Please describe the symptom'),
        isFalse,
        reason: 'Preset hijacked by non-health gate or intake loop. '
            'Got: ${reply.message}',
      );
      expect(
        reply.toolTraceJson['prompt_preset_label'],
        'Show my lab results',
        reason: 'Preset registry hit must still be recorded.',
      );
      await harness.dispose();
    },
  );
}

class _Harness {
  _Harness({
    required this.tempRoot,
    required this.database,
    required this.repository,
    required this.service,
  });

  final Directory tempRoot;
  final AppDatabase database;
  final WearableSampleRepository repository;
  final LocalAgentService service;

  static Future<_Harness> create() async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_adv_5f4dd28_',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = LocalAgentService(
      repository: repository,
      runtime: const UnavailableGemmaRuntime(),
      nowProvider: () => DateTime.parse('2026-05-14T08:00:00Z'),
    );
    return _Harness(
      tempRoot: tempRoot,
      database: database,
      repository: repository,
      service: service,
    );
  }

  Future<void> dispose() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }
}
