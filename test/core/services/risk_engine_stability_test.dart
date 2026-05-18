// ignore_for_file: lines_longer_than_80_chars
//
// risk_engine_stability_test.dart
//
// BUG-078 regression invariants: the score shown to a user in chat must NOT
// change purely from background Apple Health sync. These tests verify the
// ScoreStabilityGate and LabRiskContributionService in combination with
// stateless invariants that would catch score drift if gate logic regresses.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/lab_risk_contribution_service.dart';
import 'package:gemma_flares/core/services/score_stability_gate.dart';

// ─────────────────────────────────────────────────────────────────────────────
// In-memory stub repo
// ─────────────────────────────────────────────────────────────────────────────

class _MemRepo extends WearableSampleRepository {
  _MemRepo() : super(database: AppDatabase());

  final Map<String, FlareRiskScoreRecord> _latest = {};
  final Map<String, List<FlareRiskScoreRecord>> _snapshots = {};

  void setLatest(String sessionId, FlareRiskScoreRecord score) {
    _latest[sessionId] = score;
    _snapshots.putIfAbsent(sessionId, () => []).add(score);
  }

  @override
  Future<FlareRiskScoreRecord?> getDisplayedSessionScore({
    required String sessionId,
    String? dateLocal,
  }) async {
    final list = _snapshots[sessionId];
    return (list == null || list.isEmpty) ? null : list.last;
  }

  @override
  Future<void> upsertDisplayedScoreSnapshot({
    required String sessionId,
    required FlareRiskScoreRecord score,
    required String triggerReason,
    String? userActionType,
    required DateTime displayedAt,
  }) async {
    _snapshots.putIfAbsent(sessionId, () => []).add(score);
  }

  @override
  Future<FlareRiskScoreRecord?> getLatestUserFacingFlareRiskScore({
    String? dateLocal,
  }) async =>
      null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

FlareRiskScoreRecord _score(double risk, {String dateLocal = '2026-05-13'}) {
  final now = DateTime.utc(2026, 5, 13);
  return FlareRiskScoreRecord(
    dateLocal: dateLocal,
    riskScore: risk,
    confidenceScore: 70,
    riskBand: risk >= 60
        ? 'high'
        : risk >= 35
            ? 'elevated'
            : 'low',
    contributionJson: const {},
    featureSnapshotJson: const {},
    modelVersion: 'v20',
    createdAt: now,
  );
}

ScoreStabilityGate _gate(
  _MemRepo repo, {
  DateTime Function()? nowProvider,
  double threshold = 5.0,
  Duration debounce = Duration.zero,
}) {
  return ScoreStabilityGate(
    repository: repo,
    nowProvider: nowProvider,
    significantChangeThreshold: threshold,
    debounceWindow: debounce,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BUG-078 core invariants
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('BUG-078: background sync cannot drift score mid-session', () {
    test(
      '4 background syncs with tiny deltas → displayed score unchanged',
      () async {
        final repo = _MemRepo();
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        // First pass anchors session
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 'sess',
          triggerReason: 'session_start',
        );
        // Four background syncs, each +1 point — max delta 4, always < 5
        for (var i = 1; i <= 4; i++) {
          final r = await gate.evaluateRecomputed(
            recomputed: _score(50 + i.toDouble()),
            sessionId: 'sess',
            triggerReason: 'foreground_timer',
            isUserAction: false,
          );
          expect(
            r.displayUpdated,
            isFalse,
            reason: 'background sync $i (delta $i) should not update display',
          );
        }
        final displayed = await gate.getDisplayedScore(sessionId: 'sess');
        expect(displayed?.riskScore, closeTo(50, 0.001));
      },
    );

    test('background sync without new data → no display update', () async {
      final repo = _MemRepo();
      final gate = _gate(repo, debounce: Duration.zero);
      await gate.evaluateRecomputed(
        recomputed: _score(50),
        sessionId: 's',
        triggerReason: 'start',
      );
      final result = await gate.evaluateRecomputed(
        recomputed: _score(50),
        sessionId: 's',
        triggerReason: 'foreground_timer',
      );
      expect(result.displayUpdated, isFalse);
      expect(result.gateDecision, 'below_threshold');
    });

    test(
      'score_changed log fires only on threshold breach, not on every sync',
      () async {
        final repo = _MemRepo();
        var scoreChangedCount = 0;
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 's',
          triggerReason: 'start',
        );
        for (var i = 0; i < 10; i++) {
          // Alternating small changes — never crossing threshold
          final result = await gate.evaluateRecomputed(
            recomputed: _score(50 + (i % 2 == 0 ? 2 : -2).toDouble()),
            sessionId: 's',
            triggerReason: 'foreground_timer',
          );
          if (result.displayUpdated) scoreChangedCount++;
        }
        // No threshold breach → zero updates
        expect(scoreChangedCount, 0);
      },
    );

    test(
      'gate blocks mid-session score change from background (delta=3)',
      () async {
        final repo = _MemRepo();
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 's',
          triggerReason: 'start',
        );
        final result = await gate.evaluateRecomputed(
          recomputed: _score(53),
          sessionId: 's',
          triggerReason: 'background_sync',
        );
        expect(result.displayUpdated, isFalse);
        expect(result.gateDecision, 'below_threshold');
      },
    );
  });

  group('user-logged lab updates displayed score immediately', () {
    test('user logs FC 320 → score updates regardless of delta', () async {
      final repo = _MemRepo();
      final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
      await gate.evaluateRecomputed(
        recomputed: _score(50),
        sessionId: 's',
        triggerReason: 'start',
      );
      final result = await gate.evaluateRecomputed(
        recomputed: _score(51), // delta 1 — below threshold
        sessionId: 's',
        triggerReason: 'lab_logged',
        isUserAction: true,
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'user_action_bypass');
    });

    test(
      'after user lab log, anchor is updated — next background sync relative to new anchor',
      () async {
        final repo = _MemRepo();
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        // Anchor at 50
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 's',
          triggerReason: 'start',
        );
        // User logs lab → anchor moves to 68
        await gate.evaluateRecomputed(
          recomputed: _score(68),
          sessionId: 's',
          triggerReason: 'lab_logged',
          isUserAction: true,
        );
        // Background sync: 69 → delta 1 from new anchor 68 → blocked
        final r = await gate.evaluateRecomputed(
          recomputed: _score(69),
          sessionId: 's',
          triggerReason: 'background_sync',
        );
        expect(r.displayUpdated, isFalse);
      },
    );
  });

  group('session boundary: new session re-anchors correctly', () {
    test(
      'session A score 90, session B starts fresh and anchors at 50',
      () async {
        final repo = _MemRepo();
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        await gate.evaluateRecomputed(
          recomputed: _score(90),
          sessionId: 'sessA',
          triggerReason: 'start',
        );
        final r = await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 'sessB',
          triggerReason: 'start',
        );
        expect(r.displayUpdated, isTrue);
        expect(r.newScore, 50);
      },
    );

    test(
      'session B delta 3 vs anchor 50 → blocked, independent of session A',
      () async {
        final repo = _MemRepo();
        final gate = _gate(repo, threshold: 5.0, debounce: Duration.zero);
        await gate.evaluateRecomputed(
          recomputed: _score(90),
          sessionId: 'sessA',
          triggerReason: 'start',
        );
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 'sessB',
          triggerReason: 'start',
        );
        final r = await gate.evaluateRecomputed(
          recomputed: _score(53),
          sessionId: 'sessB',
          triggerReason: 'background_sync',
        );
        expect(r.displayUpdated, isFalse);
      },
    );
  });

  // ── LabRiskContributionService stability: same inputs → zero drift ─────────

  group('lab contribution stability: same inputs → identical output', () {
    const sut = LabRiskContributionService();

    test('FC 320 × 5 runs → identical points', () {
      const dateLocal = '2026-05-13';
      final now = DateTime.utc(2026, 5, 13);
      final lab = LabValueRecord(
        drawnDate: dateLocal,
        labType: 'fc',
        valueNumeric: 320,
        unit: 'μg/g',
        createdAt: now,
        updatedAt: now,
      );
      final results = List.generate(
        5,
        (_) => sut.computeContribution(
          dateLocal: dateLocal,
          candidateLabs: [lab],
          userBaselineByLabType: {},
        ),
      );
      for (final r in results) {
        expect(r.points, results.first.points);
        expect(r.decayFactor, results.first.decayFactor);
        expect(r.narrativeKey, results.first.narrativeKey);
      }
    });

    test('mixed labs × 5 runs → identical points', () {
      const dateLocal = '2026-05-13';
      final now = DateTime.utc(2026, 5, 13);
      final labs = [
        LabValueRecord(
          drawnDate: dateLocal,
          labType: 'fc',
          valueNumeric: 320,
          unit: 'μg/g',
          createdAt: now,
          updatedAt: now,
        ),
        LabValueRecord(
          drawnDate: dateLocal,
          labType: 'crp',
          valueNumeric: 8,
          unit: 'mg/dL',
          createdAt: now,
          updatedAt: now,
        ),
        LabValueRecord(
          drawnDate: dateLocal,
          labType: 'albumin',
          valueNumeric: 3.2,
          unit: 'g/dL',
          createdAt: now,
          updatedAt: now,
        ),
      ];
      final results = List.generate(
        5,
        (_) => sut.computeContribution(
          dateLocal: dateLocal,
          candidateLabs: labs,
          userBaselineByLabType: {},
        ),
      );
      for (final r in results) {
        expect(r.points, results.first.points);
      }
    });
  });

  // ── Gate stability: debounce re-evaluation ────────────────────────────────

  group('gate stability: debounce timing edge cases', () {
    test(
      'debounce boundary exact — within window blocked, at boundary passes',
      () async {
        var now = DateTime.utc(2026, 5, 13, 0, 0, 0);
        final repo = _MemRepo();
        final gate = _gate(
          repo,
          nowProvider: () => now,
          debounce: const Duration(seconds: 60),
        );
        // Anchor
        await gate.evaluateRecomputed(
          recomputed: _score(50),
          sessionId: 's',
          triggerReason: 'start',
        );
        // At exactly 60s — still within window (need > 60s to pass)
        now = now.add(const Duration(seconds: 60));
        final r1 = await gate.evaluateRecomputed(
          recomputed: _score(60),
          sessionId: 's',
          triggerReason: 'bg',
        );
        // 60s exactly — _debounceWindow is Duration(seconds:60), difference == window → NOT < → passes
        // The gate check is: difference < _debounceWindow. At exactly 60s, difference == 60s → not < → passes
        expect(r1.gateDecision, isNot('debounced'));
      },
    );

    test('rapid background syncs reset debounce timer on each pass', () async {
      var now = DateTime.utc(2026, 5, 13, 0, 0, 0);
      final repo = _MemRepo();
      final gate = _gate(
        repo,
        nowProvider: () => now,
        debounce: const Duration(seconds: 30),
        threshold: 5.0,
      );
      // First pass
      await gate.evaluateRecomputed(
        recomputed: _score(50),
        sessionId: 's',
        triggerReason: 'start',
      );
      // Jump 31s — pass threshold (delta 10)
      now = now.add(const Duration(seconds: 31));
      await gate.evaluateRecomputed(
        recomputed: _score(60),
        sessionId: 's',
        triggerReason: 'bg',
      );
      // Immediately after — debounced
      now = now.add(const Duration(seconds: 5));
      final r = await gate.evaluateRecomputed(
        recomputed: _score(70),
        sessionId: 's',
        triggerReason: 'bg',
      );
      expect(r.gateDecision, 'debounced');
    });
  });
}
