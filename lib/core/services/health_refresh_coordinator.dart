import 'dart:async';

import 'diagnostic_log_service.dart';
import 'guidance_service.dart';
import 'health_rag_sync_service.dart';
import 'health_sync_service.dart';
import 'score_stability_gate.dart';
import 'system_status_service.dart';

class HealthRefreshCoordinator {
  HealthRefreshCoordinator({
    required HealthSyncService healthSyncService,
    required GuidanceService guidanceService,
    required SystemStatusService systemStatusService,
    HealthRagSyncService? healthRagSyncService,
    DiagnosticLogService? diagnosticLogService,
    ScoreStabilityGate? scoreStabilityGate,
    Duration interval = const Duration(minutes: 1),
    Duration minimumGap = const Duration(seconds: 45),
    Future<HealthSyncRunResult> Function(DateTime now)?
        incrementalSyncRunnerOverride,
    Future<void> Function(String reason, bool allowModel)?
        guidanceRefreshRunnerOverride,
    Future<bool> Function()? authorizationCheckOverride,
    DateTime Function()? nowProvider,
  })  : _healthSyncService = healthSyncService,
        _guidanceService = guidanceService,
        _systemStatusService = systemStatusService,
        _healthRagSyncService = healthRagSyncService,
        _diagnosticLogService = diagnosticLogService,
        _scoreStabilityGate = scoreStabilityGate,
        _interval = interval,
        _minimumGap = minimumGap,
        _incrementalSyncRunnerOverride = incrementalSyncRunnerOverride,
        _guidanceRefreshRunnerOverride = guidanceRefreshRunnerOverride,
        _authorizationCheckOverride = authorizationCheckOverride,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final HealthSyncService _healthSyncService;
  final GuidanceService _guidanceService;
  final SystemStatusService _systemStatusService;
  final HealthRagSyncService? _healthRagSyncService;
  final DiagnosticLogService? _diagnosticLogService;
  final ScoreStabilityGate? _scoreStabilityGate;
  final Duration _interval;
  final Duration _minimumGap;
  final Future<HealthSyncRunResult> Function(DateTime now)?
      _incrementalSyncRunnerOverride;
  final Future<void> Function(String reason, bool allowModel)?
      _guidanceRefreshRunnerOverride;
  final Future<bool> Function()? _authorizationCheckOverride;
  final DateTime Function() _nowProvider;

  Timer? _timer;
  bool _running = false;
  Future<void>? _inFlightRefresh;
  DateTime? _lastStartedAt;
  String? _currentSessionId;

  /// The current session ID, used by home_screen to fetch session-anchored score.
  String? get currentSessionId => _currentSessionId;

  Future<void> start({String? sessionId}) async {
    _currentSessionId = sessionId;
    if (sessionId != null) {
      await _scoreStabilityGate?.startSession(sessionId: sessionId);
    }
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      refreshNow(reason: 'foreground_timer');
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refreshNow({String reason = 'manual'}) async {
    final existing = _inFlightRefresh;
    if (existing != null) {
      await _recordSkip(reason: reason, skipReason: 'already_running_joined');
      return existing;
    }
    final future = _refreshNowInternal(reason: reason);
    _inFlightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh, future)) _inFlightRefresh = null;
    });
  }

  Future<void> _refreshNowInternal({required String reason}) async {
    final now = _nowProvider();
    final startedAt = now;
    if (_running) {
      await _recordSkip(reason: reason, skipReason: 'already_running');
      return;
    }
    final lastStartedAt = _lastStartedAt;
    if (lastStartedAt != null &&
        now.difference(lastStartedAt).abs() < _minimumGap) {
      await _recordSkip(reason: reason, skipReason: 'debounced');
      return;
    }

    _running = true;
    final hasAuthorizedAccess = await (_authorizationCheckOverride?.call() ??
        _healthSyncService.hasAuthorizedHealthAccess());
    if (!hasAuthorizedAccess) {
      await _recordSkip(
        reason: reason,
        skipReason: 'health_access_unavailable',
      );
      _running = false;
      return;
    }

    _lastStartedAt = now;
    try {
      final systemStatus = await _systemStatusService.getStatus();
      if (systemStatus.lowPowerModeEnabled) {
        await _recordSkip(
          reason: reason,
          skipReason: 'low_power_mode',
          metadata: {'system_status': systemStatus.toJson()},
        );
        return;
      }
      if (systemStatus.shouldSkipRefreshForThermal) {
        await _recordSkip(
          reason: reason,
          skipReason: 'thermal_${systemStatus.thermalState}',
          metadata: {'system_status': systemStatus.toJson()},
        );
        return;
      }
      final result = await (_incrementalSyncRunnerOverride?.call(now) ??
          _healthSyncService.runIncrementalSync(
            metrics: HealthSyncService.allProductionMetrics,
            now: now,
            sessionId: _currentSessionId,
            triggerReason: reason,
            isUserAction: _isUserActionReason(reason),
          ));
      final ragWrites = await _indexSyncedHealthInRag(
        result: result,
        reason: reason,
      );
      if (_guidanceRefreshRunnerOverride != null) {
        await _guidanceRefreshRunnerOverride(
          'health_refresh_$reason',
          !result.hasFailures &&
              !systemStatus.shouldAvoidModelGeneration &&
              _allowsAutomaticModelGeneration(reason),
        );
      } else {
        await _guidanceService.refreshLatestGuidance(
          reason: 'health_refresh_$reason',
          allowModel: !result.hasFailures &&
              !systemStatus.shouldAvoidModelGeneration &&
              _allowsAutomaticModelGeneration(reason),
        );
      }
      await _diagnosticLogService?.info(
        'foreground_refresh_completed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Foreground Health refresh completed.',
        metadata: {
          'reason': reason,
          'has_failures': result.hasFailures,
          'metric_count': result.metricResults.length,
          'rag_transaction_count': ragWrites,
          'system_status': systemStatus.toJson(),
          'duration_ms': _nowProvider().difference(startedAt).inMilliseconds,
        },
      );
    } catch (error, stackTrace) {
      try {
        if (_guidanceRefreshRunnerOverride != null) {
          await _guidanceRefreshRunnerOverride(
            'health_refresh_failed_$reason',
            false,
          );
        } else {
          await _guidanceService.refreshLatestGuidance(
            reason: 'health_refresh_failed_$reason',
            allowModel: false,
          );
        }
      } catch (_) {
        // Diagnostics below preserve the original sync failure.
      }
      await _diagnosticLogService?.error(
        'foreground_refresh_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Foreground Health refresh failed.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason},
      );
    } finally {
      _running = false;
    }
  }

  bool _allowsAutomaticModelGeneration(String reason) {
    return reason == 'manual';
  }

  /// Returns true for reasons that represent explicit user-initiated actions.
  /// These bypass the score stability gate's threshold check.
  static bool _isUserActionReason(String reason) {
    return const {
      'lab_logged',
      'symptom_logged',
      'checkin_submitted',
      'explicit_refresh',
    }.contains(reason);
  }

  Future<int> _indexSyncedHealthInRag({
    required HealthSyncRunResult result,
    required String reason,
  }) async {
    final service = _healthRagSyncService;
    if (service == null) return 0;
    try {
      final writes = await service.indexSyncRun(result: result, reason: reason);
      return writes.length;
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'foreground_refresh_rag_index_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Synced Health data could not be written to local RAG.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason},
      );
      return 0;
    }
  }

  Future<void> _recordSkip({
    required String reason,
    required String skipReason,
    Map<String, Object?> metadata = const {},
  }) {
    return _diagnosticLogService?.debug(
          'foreground_refresh_skipped',
          category: DiagnosticLogService.categoryHealthSync,
          message: 'Foreground Health refresh skipped.',
          metadata: {'reason': reason, 'skip_reason': skipReason, ...metadata},
        ) ??
        Future.value();
  }
}
