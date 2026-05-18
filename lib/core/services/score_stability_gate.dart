// =============================================================================
// ScoreStabilityGate — session-anchored flare risk display stability
// =============================================================================
// Prevents background Apple Health sync from mutating the score shown to the
// user mid-session. The displayed score is anchored at session start; it only
// updates when (a) a user action triggers the recompute, or (b) the background
// recompute produces a delta ≥ significantChangeThreshold (default 5 points).
//
// BUG-078: root cause was Timer.periodic (60s) → recomputeDates → rolling
// window averages shifting on every new HR/HRV sample, causing the score to
// change between "Check my flare risk" and "What changed today?" with no user
// action. This gate eliminates that class of drift.
// =============================================================================

import '../database/wearable_sample_repository.dart';
import 'diagnostic_log_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result value object
// ─────────────────────────────────────────────────────────────────────────────

class ScoreGateResult {
  const ScoreGateResult({
    required this.displayUpdated,
    required this.gateDecision,
    this.previousScore,
    this.newScore,
    this.delta,
  });

  /// Whether the displayed session snapshot was updated.
  final bool displayUpdated;

  /// 'passed'|'debounced'|'below_threshold'|'user_action_bypass'
  final String gateDecision;

  final double? previousScore;
  final double? newScore;
  final double? delta;
}

// ─────────────────────────────────────────────────────────────────────────────
// Gate
// ─────────────────────────────────────────────────────────────────────────────

class ScoreStabilityGate {
  ScoreStabilityGate({
    required WearableSampleRepository repository,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
    double significantChangeThreshold = 5.0,
    Duration debounceWindow = const Duration(seconds: 30),
  })  : _repo = repository,
        _log = diagnosticLogService,
        _now = nowProvider ?? (() => DateTime.now().toUtc()),
        _threshold = significantChangeThreshold,
        _debounceWindow = debounceWindow;

  final WearableSampleRepository _repo;
  final DiagnosticLogService? _log;
  final DateTime Function() _now;
  final double _threshold;
  final Duration _debounceWindow;

  // In-memory per-session last-pass timestamps.
  // Resets on app restart — correct behavior, new app launch = new session.
  final Map<String, DateTime> _lastPassTime = {};

  /// Called at session start (app foreground). Seeds the anchor with whatever
  /// score is currently in the DB for today; no-ops if called again with the
  /// same sessionId (idempotent).
  Future<void> startSession({required String sessionId}) async {
    // Check for existing snapshot to preserve idempotency
    final existing = await _repo.getDisplayedSessionScore(sessionId: sessionId);
    if (existing != null && _lastPassTime.containsKey(sessionId)) {
      // Already initialized for this session
      return;
    }
    // Anchor the current best score for this session
    final current = await _repo.getLatestUserFacingFlareRiskScore();
    if (current != null) {
      await _repo.upsertDisplayedScoreSnapshot(
        sessionId: sessionId,
        score: current,
        triggerReason: 'session_start',
        displayedAt: _now(),
      );
    }
    _lastPassTime[sessionId] = _now();
  }

  /// Evaluates whether a freshly recomputed score should update the
  /// session-displayed score. Returns a [ScoreGateResult] describing the
  /// decision and any side effects.
  Future<ScoreGateResult> evaluateRecomputed({
    required FlareRiskScoreRecord recomputed,
    required String sessionId,
    required String triggerReason,
    bool isUserAction = false,
  }) async {
    final now = _now();

    // ── 1. DEBOUNCE CHECK (skip when user-triggered) ───────────────────────
    if (!isUserAction) {
      final lastPass = _lastPassTime[sessionId];
      if (lastPass != null && now.difference(lastPass) < _debounceWindow) {
        await _log?.debug(
          'score_recomputed_debounced',
          category: DiagnosticLogService.categoryHealthSync,
          metadata: {
            'session_id': sessionId,
            'trigger_reason': triggerReason,
            'debounce_remaining_ms':
                (_debounceWindow - now.difference(lastPass)).inMilliseconds,
          },
        );
        return const ScoreGateResult(
          displayUpdated: false,
          gateDecision: 'debounced',
        );
      }
    }

    // ── 2. FETCH ANCHOR ────────────────────────────────────────────────────
    final anchor = await _repo.getDisplayedSessionScore(
      sessionId: sessionId,
      dateLocal: recomputed.dateLocal,
    );

    // ── 3. USER ACTION BYPASS ──────────────────────────────────────────────
    if (isUserAction) {
      await _repo.upsertDisplayedScoreSnapshot(
        sessionId: sessionId,
        score: recomputed,
        triggerReason: 'user_action',
        userActionType: triggerReason,
        displayedAt: now,
      );
      _lastPassTime[sessionId] = now;
      await _log?.debug(
        'score_updated_user_action',
        category: DiagnosticLogService.categoryHealthSync,
        metadata: {
          'session_id': sessionId,
          'trigger_reason': triggerReason,
          'new_score': recomputed.riskScore,
          'previous_score': anchor?.riskScore,
        },
      );
      return ScoreGateResult(
        displayUpdated: true,
        gateDecision: 'user_action_bypass',
        previousScore: anchor?.riskScore,
        newScore: recomputed.riskScore,
        delta: anchor != null
            ? (recomputed.riskScore - anchor.riskScore).abs()
            : null,
      );
    }

    // ── 4. FIRST RUN (no anchor yet for this session) ──────────────────────
    if (anchor == null) {
      await _repo.upsertDisplayedScoreSnapshot(
        sessionId: sessionId,
        score: recomputed,
        triggerReason: 'session_start',
        displayedAt: now,
      );
      _lastPassTime[sessionId] = now;
      return ScoreGateResult(
        displayUpdated: true,
        gateDecision: 'passed',
        newScore: recomputed.riskScore,
      );
    }

    // ── 5. THRESHOLD CHECK ─────────────────────────────────────────────────
    final delta = (recomputed.riskScore - anchor.riskScore).abs();
    if (delta < _threshold) {
      await _log?.debug(
        'score_recomputed_no_change',
        category: DiagnosticLogService.categoryHealthSync,
        metadata: {
          'session_id': sessionId,
          'delta': delta,
          'trigger_reason': triggerReason,
          'anchor_score': anchor.riskScore,
          'recomputed_score': recomputed.riskScore,
        },
      );
      return ScoreGateResult(
        displayUpdated: false,
        gateDecision: 'below_threshold',
        previousScore: anchor.riskScore,
        newScore: recomputed.riskScore,
        delta: delta,
      );
    }

    // ── 6. SIGNIFICANT CHANGE ──────────────────────────────────────────────
    await _repo.upsertDisplayedScoreSnapshot(
      sessionId: sessionId,
      score: recomputed,
      triggerReason: 'threshold_exceeded',
      displayedAt: now,
    );
    _lastPassTime[sessionId] = now;
    await _log?.debug(
      'score_changed',
      category: DiagnosticLogService.categoryHealthSync,
      metadata: {
        'session_id': sessionId,
        'delta': delta,
        'trigger_reason': triggerReason,
        'previous_score': anchor.riskScore,
        'new_score': recomputed.riskScore,
      },
    );
    return ScoreGateResult(
      displayUpdated: true,
      gateDecision: 'passed',
      previousScore: anchor.riskScore,
      newScore: recomputed.riskScore,
      delta: delta,
    );
  }

  /// Returns the current session-anchored score for display in chat/home.
  Future<FlareRiskScoreRecord?> getDisplayedScore({
    required String sessionId,
  }) async {
    return _repo.getDisplayedSessionScore(sessionId: sessionId);
  }
}
