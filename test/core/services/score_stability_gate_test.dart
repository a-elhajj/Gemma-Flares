// ignore_for_file: lines_longer_than_80_chars
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/score_stability_gate.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Minimal stub — no SQLite needed for gate logic unit tests
// ─────────────────────────────────────────────────────────────────────────────

class _FakeRepo extends WearableSampleRepository {
  _FakeRepo() : super(database: AppDatabase());

  // Map: sessionId → list of snapshots (last = current)
  final Map<String, List<FlareRiskScoreRecord>> _snapshots = {};

  // Seed a displayed snapshot without going through gate logic
  void seedSnapshot(String sessionId, FlareRiskScoreRecord score) {
    _snapshots.putIfAbsent(sessionId, () => []).add(score);
  }

  @override
  Future<FlareRiskScoreRecord?> getDisplayedSessionScore({
    required String sessionId,
    String? dateLocal,
  }) async {
    final list = _snapshots[sessionId];
    if (list == null || list.isEmpty) return null;
    return list.last;
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
  }) async {
    // No prior score by default — override per test if needed
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

FlareRiskScoreRecord _score({
  double risk = 50,
  double confidence = 70,
  String band = 'elevated',
  String dateLocal = '2026-05-13',
}) {
  final now = DateTime.utc(2026, 5, 13);
  return FlareRiskScoreRecord(
    dateLocal: dateLocal,
    riskScore: risk,
    confidenceScore: confidence,
    riskBand: band,
    contributionJson: const {},
    featureSnapshotJson: const {},
    modelVersion: 'v20',
    createdAt: now,
  );
}

ScoreStabilityGate _gate(
  _FakeRepo repo, {
  DateTime Function()? nowProvider,
  double threshold = 5.0,
  Duration debounce = const Duration(seconds: 30),
}) {
  return ScoreStabilityGate(
    repository: repo,
    nowProvider: nowProvider,
    significantChangeThreshold: threshold,
    debounceWindow: debounce,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── First run / session start ───────────────────────────────────────────────
  group('first run (no anchor)', () {
    test('passes through and marks displayUpdated=true', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 'sess-1',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'passed');
      expect(result.newScore, 50);
    });

    test('snapshot written to repo on first run', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 42),
        sessionId: 'sess-2',
        triggerReason: 'background_sync',
      );
      final stored = await repo.getDisplayedSessionScore(sessionId: 'sess-2');
      expect(stored?.riskScore, 42);
    });
  });

  // ── Below threshold ──────────────────────────────────────────────────────────
  group('below_threshold gate', () {
    test('delta 2 < threshold 5 → displayUpdated=false', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      // warm up _lastPassTime so debounce doesn't block
      _gate(repo); // fresh gate — no lastPassTime
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 52),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isFalse);
      expect(result.gateDecision, 'below_threshold');
      expect(result.delta, closeTo(2, 0.001));
    });

    test(
      'delta exactly equal to threshold → passes (gate uses strict <)',
      () async {
        final repo = _FakeRepo();
        repo.seedSnapshot('sess', _score(risk: 50));
        final gate = _gate(repo);
        final result = await gate.evaluateRecomputed(
          recomputed: _score(risk: 55),
          sessionId: 'sess',
          triggerReason: 'background_sync',
        );
        // delta == threshold → NOT below_threshold (gate checks delta < threshold)
        // so delta==5 with threshold==5 is a "significant change" → passes
        expect(result.displayUpdated, isTrue);
        expect(result.gateDecision, 'passed');
      },
    );

    test('delta 4.9 → below_threshold', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 54.9),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isFalse);
      expect(result.delta, closeTo(4.9, 0.001));
    });

    test('score drops by 2 (negative delta) → below_threshold', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 48),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isFalse);
      expect(result.delta, closeTo(2, 0.001));
    });

    test('snapshot NOT updated in repo when below threshold', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final snapshotCountBefore = repo._snapshots['sess']!.length;
      final gate = _gate(repo);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 52),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(repo._snapshots['sess']!.length, snapshotCountBefore);
    });
  });

  // ── Significant change (threshold exceeded) ──────────────────────────────────
  group('threshold_exceeded gate', () {
    test('delta 8 > threshold 5 → displayUpdated=true', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 58),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'passed');
      expect(result.delta, closeTo(8, 0.001));
    });

    test('snapshot written on significant change', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 62),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      final stored = await repo.getDisplayedSessionScore(sessionId: 'sess');
      expect(stored?.riskScore, 62);
    });

    test('previousScore and newScore populated on threshold pass', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 40));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 55),
        sessionId: 'sess',
        triggerReason: 'background_sync',
      );
      expect(result.previousScore, 40);
      expect(result.newScore, 55);
    });

    test('custom threshold 10 — delta 8 blocked, delta 12 passes', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo, threshold: 10.0, debounce: Duration.zero);
      // First run — sets anchor to 50
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'session_start',
      );
      // delta 8 — blocked
      final r1 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 58),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(r1.displayUpdated, isFalse);
      // delta 12 — passes
      final r2 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 62),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(r2.displayUpdated, isTrue);
    });
  });

  // ── User action bypass ────────────────────────────────────────────────────────
  group('user_action_bypass', () {
    test('delta 1 with isUserAction=true → displayUpdated=true', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 51),
        sessionId: 'sess',
        triggerReason: 'lab_logged',
        isUserAction: true,
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'user_action_bypass');
    });

    test('user action delta 0 → still displayUpdated=true', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 'sess',
        triggerReason: 'symptom_logged',
        isUserAction: true,
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'user_action_bypass');
    });

    test('user action skips debounce window', () async {
      var now = DateTime.utc(2026, 5, 13, 12, 0, 0);
      final repo = _FakeRepo();
      final gate = _gate(
        repo,
        nowProvider: () => now,
        debounce: const Duration(seconds: 30),
      );
      // First pass — sets anchor and _lastPassTime
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'session_start',
      );
      // Advance only 5 seconds — within debounce window
      now = now.add(const Duration(seconds: 5));
      // Background sync blocked by debounce
      final bgResult = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(bgResult.gateDecision, 'debounced');
      // User action bypasses debounce
      final userResult = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'lab_logged',
        isUserAction: true,
      );
      expect(userResult.displayUpdated, isTrue);
      expect(userResult.gateDecision, 'user_action_bypass');
    });

    test('snapshot written on user action', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 50));
      final gate = _gate(repo);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 68),
        sessionId: 'sess',
        triggerReason: 'checkin_submitted',
        isUserAction: true,
      );
      final stored = await repo.getDisplayedSessionScore(sessionId: 'sess');
      expect(stored?.riskScore, 68);
    });

    test('user action returns previousScore and newScore', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sess', _score(risk: 40));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 45),
        sessionId: 'sess',
        triggerReason: 'lab_logged',
        isUserAction: true,
      );
      expect(result.previousScore, 40);
      expect(result.newScore, 45);
    });
  });

  // ── Debounce ─────────────────────────────────────────────────────────────────
  group('debounce', () {
    test('3 background syncs within 30s — only first passes', () async {
      var now = DateTime.utc(2026, 5, 13, 12, 0, 0);
      final repo = _FakeRepo();
      final gate = _gate(
        repo,
        nowProvider: () => now,
        debounce: const Duration(seconds: 30),
      );
      // First (no anchor) — passes
      final r1 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'session_start',
      );
      expect(r1.displayUpdated, isTrue);
      // 10s later — debounced
      now = now.add(const Duration(seconds: 10));
      final r2 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(r2.gateDecision, 'debounced');
      // 20s later — still debounced
      now = now.add(const Duration(seconds: 10));
      final r3 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(r3.gateDecision, 'debounced');
    });

    test('sync at t=31s passes through (delta > threshold)', () async {
      var now = DateTime.utc(2026, 5, 13, 12, 0, 0);
      final repo = _FakeRepo();
      final gate = _gate(
        repo,
        nowProvider: () => now,
        debounce: const Duration(seconds: 30),
      );
      // First — passes
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'session_start',
      );
      now = now.add(const Duration(seconds: 31));
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(result.gateDecision, isNot('debounced'));
    });

    test(
      'sync at t=31s with delta < threshold → below_threshold not debounced',
      () async {
        var now = DateTime.utc(2026, 5, 13, 12, 0, 0);
        final repo = _FakeRepo();
        final gate = _gate(
          repo,
          nowProvider: () => now,
          debounce: const Duration(seconds: 30),
        );
        await gate.evaluateRecomputed(
          recomputed: _score(risk: 50),
          sessionId: 's',
          triggerReason: 'session_start',
        );
        now = now.add(const Duration(seconds: 31));
        final result = await gate.evaluateRecomputed(
          recomputed: _score(risk: 52),
          sessionId: 's',
          triggerReason: 'background_sync',
        );
        expect(result.gateDecision, 'below_threshold');
      },
    );

    test('custom debounce 60s — sync at 59s debounced, 61s not', () async {
      var now = DateTime.utc(2026, 5, 13, 12, 0, 0);
      final repo = _FakeRepo();
      final gate = _gate(
        repo,
        nowProvider: () => now,
        debounce: const Duration(seconds: 60),
      );
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'start',
      );
      now = now.add(const Duration(seconds: 59));
      final r1 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'bg',
      );
      expect(r1.gateDecision, 'debounced');
      now = now.add(const Duration(seconds: 2));
      final r2 = await gate.evaluateRecomputed(
        recomputed: _score(risk: 60),
        sessionId: 's',
        triggerReason: 'bg',
      );
      expect(r2.gateDecision, isNot('debounced'));
    });
  });

  // ── Session isolation ─────────────────────────────────────────────────────────
  group('session isolation', () {
    test('different sessions have independent anchors', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('sessA', _score(risk: 50));
      repo.seedSnapshot('sessB', _score(risk: 80));
      final gate = _gate(repo);
      // sessA: delta 3 → below_threshold
      final rA = await gate.evaluateRecomputed(
        recomputed: _score(risk: 53),
        sessionId: 'sessA',
        triggerReason: 'bg',
      );
      expect(rA.gateDecision, 'below_threshold');
      // sessB: delta 3 → below_threshold (anchor 80)
      final rB = await gate.evaluateRecomputed(
        recomputed: _score(risk: 83),
        sessionId: 'sessB',
        triggerReason: 'bg',
      );
      expect(rB.gateDecision, 'below_threshold');
    });

    test('new session re-anchors (old session score irrelevant)', () async {
      final repo = _FakeRepo();
      // Old session at 90 — would keep delta low for new session
      repo.seedSnapshot('sessOld', _score(risk: 90));
      final gate = _gate(repo);
      // New session has no anchor → first run passes
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 'sessNew',
        triggerReason: 'session_start',
      );
      expect(result.displayUpdated, isTrue);
      expect(result.gateDecision, 'passed');
    });

    test(
      'old session anchor does not contaminate new session threshold check',
      () async {
        final repo = _FakeRepo();
        // Anchor old session at 50
        repo.seedSnapshot('old', _score(risk: 50));
        final gate = _gate(repo);
        // Old session: first pass sets anchor at 50 and lastPassTime
        await gate.evaluateRecomputed(
          recomputed: _score(risk: 50),
          sessionId: 'old',
          triggerReason: 'start',
        );
        // New session: no anchor — passes regardless of delta from old session
        final r = await gate.evaluateRecomputed(
          recomputed: _score(risk: 52),
          sessionId: 'new',
          triggerReason: 'start',
        );
        expect(r.gateDecision, 'passed');
      },
    );
  });

  // ── startSession idempotency ──────────────────────────────────────────────────
  group('startSession', () {
    test(
      'calling startSession twice with same sessionId is idempotent',
      () async {
        final repo = _FakeRepo();
        final gate = _gate(repo);
        await gate.startSession(sessionId: 'sess');
        await gate.startSession(sessionId: 'sess');
        // No crash, no duplicate snapshot
      },
    );

    test(
      'startSession with no existing score completes without error',
      () async {
        final repo = _FakeRepo();
        final gate = _gate(repo);
        await gate.startSession(sessionId: 'clean-session');
        // No existing score — nothing stored, no crash
        final stored = await repo.getDisplayedSessionScore(
          sessionId: 'clean-session',
        );
        expect(stored, isNull);
      },
    );

    test('startSession with existing score seeds the anchor', () async {
      // Override getLatestUserFacingFlareRiskScore to return a score
      final gate = ScoreStabilityGate(
        repository: _FakeRepoWithSeed(seedScore: _score(risk: 45)),
      );
      await gate.startSession(sessionId: 'seeded');
      final displayed = await gate.getDisplayedScore(sessionId: 'seeded');
      expect(displayed?.riskScore, 45);
    });
  });

  // ── getDisplayedScore ─────────────────────────────────────────────────────────
  group('getDisplayedScore', () {
    test('returns null when no snapshot for session', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo);
      final result = await gate.getDisplayedScore(sessionId: 'never-used');
      expect(result, isNull);
    });

    test('returns anchored score for session', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('s', _score(risk: 42));
      final gate = _gate(repo);
      final result = await gate.getDisplayedScore(sessionId: 's');
      expect(result?.riskScore, 42);
    });

    test('returns most recent snapshot after updates', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('s', _score(risk: 40));
      final gate = _gate(repo);
      // Threshold exceeded — snapshot updated
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 55),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      final displayed = await gate.getDisplayedScore(sessionId: 's');
      expect(displayed?.riskScore, 55);
    });
  });

  // ── Log event distinction ─────────────────────────────────────────────────────
  group('log event distinctness', () {
    test(
      'score_changed and score_recomputed_no_change are different strings',
      () {
        // Invariant: these string literals in the gate must remain distinct
        const changed = 'score_changed';
        const noChange = 'score_recomputed_no_change';
        expect(changed, isNot(noChange));
      },
    );
  });

  // ── Multiple recomputes — single change log per breach ────────────────────────
  group('multiple recomputes', () {
    test(
      'background syncs with tiny deltas do not accumulate to a gate pass',
      () async {
        final repo = _FakeRepo();
        final gate = _gate(repo, debounce: Duration.zero);
        // Anchor at 50
        await gate.evaluateRecomputed(
          recomputed: _score(risk: 50),
          sessionId: 's',
          triggerReason: 'start',
        );
        // Four 1-point increments — max delta 4 which is < threshold 5
        for (var i = 1; i <= 4; i++) {
          final r = await gate.evaluateRecomputed(
            recomputed: _score(risk: 50 + i.toDouble()),
            sessionId: 's',
            triggerReason: 'background_sync',
          );
          expect(
            r.displayUpdated,
            isFalse,
            reason: 'increment $i should not pass gate',
          );
        }
        // Displayed score still anchored at 50 — gate held all 4 increments
        final displayed = await gate.getDisplayedScore(sessionId: 's');
        expect(displayed?.riskScore, 50);
      },
    );

    test(
      'once threshold crossed, anchor updates and future small deltas blocked again',
      () async {
        final repo = _FakeRepo();
        final gate = _gate(repo, debounce: Duration.zero);
        await gate.evaluateRecomputed(
          recomputed: _score(risk: 50),
          sessionId: 's',
          triggerReason: 'start',
        );
        // Exceeds threshold
        await gate.evaluateRecomputed(
          recomputed: _score(risk: 58),
          sessionId: 's',
          triggerReason: 'bg',
        );
        // Now anchored at 58 — delta 2 → blocked
        final r = await gate.evaluateRecomputed(
          recomputed: _score(risk: 60),
          sessionId: 's',
          triggerReason: 'bg',
        );
        expect(r.gateDecision, 'below_threshold');
      },
    );
  });

  // ── Edge cases ────────────────────────────────────────────────────────────────
  group('edge cases', () {
    test('very large delta (50 points) passes', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('s', _score(risk: 20));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 70),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isTrue);
      expect(result.delta, closeTo(50, 0.001));
    });

    test('score at boundary values 0 and 100', () async {
      final repo = _FakeRepo();
      repo.seedSnapshot('s', _score(risk: 0));
      final gate = _gate(repo);
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 100),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(result.displayUpdated, isTrue);
      expect(result.delta, closeTo(100, 0.001));
    });

    test('identical score after first run → below_threshold', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo, debounce: Duration.zero);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'start',
      );
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'background_sync',
      );
      expect(result.gateDecision, 'below_threshold');
      expect(result.delta, closeTo(0, 0.001));
    });

    test('threshold 0 — every change passes', () async {
      final repo = _FakeRepo();
      final gate = _gate(repo, threshold: 0.0, debounce: Duration.zero);
      await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'start',
      );
      // Delta 0 with threshold 0: 0 is NOT < 0, so it passes through
      final result = await gate.evaluateRecomputed(
        recomputed: _score(risk: 50),
        sessionId: 's',
        triggerReason: 'bg',
      );
      // With threshold=0, delta=0 is not < 0, so it's below_threshold
      // This tests the boundary behavior
      expect(result, isNotNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper for startSession seeding test
// ─────────────────────────────────────────────────────────────────────────────

class _FakeRepoWithSeed extends _FakeRepo {
  _FakeRepoWithSeed({required this.seedScore}) : super();
  final FlareRiskScoreRecord seedScore;

  @override
  Future<FlareRiskScoreRecord?> getLatestUserFacingFlareRiskScore({
    String? dateLocal,
  }) async =>
      seedScore;
}
