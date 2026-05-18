import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/wearable_sample_repository.dart';
import 'diagnostic_log_service.dart';
import 'health_refresh_coordinator.dart';

class AppReadinessState {
  const AppReadinessState({
    required this.phase,
    required this.isRefreshing,
    required this.reason,
    this.lastSyncAt,
    this.lastCompletedAt,
    this.fastPathTimedOut = false,
    this.hadError = false,
    this.errorMessage,
  });

  final String phase;
  final bool isRefreshing;
  final String reason;
  final DateTime? lastSyncAt;
  final DateTime? lastCompletedAt;
  final bool fastPathTimedOut;
  final bool hadError;
  final String? errorMessage;

  bool get isStaleBySla => lastSyncAt == null;

  AppReadinessState copyWith({
    String? phase,
    bool? isRefreshing,
    String? reason,
    DateTime? lastSyncAt,
    DateTime? lastCompletedAt,
    bool? fastPathTimedOut,
    bool? hadError,
    String? errorMessage,
  }) {
    return AppReadinessState(
      phase: phase ?? this.phase,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      reason: reason ?? this.reason,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
      fastPathTimedOut: fastPathTimedOut ?? this.fastPathTimedOut,
      hadError: hadError ?? this.hadError,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class AppReadinessService {
  AppReadinessService({
    required HealthRefreshCoordinator healthRefreshCoordinator,
    required WearableSampleRepository repository,
    DiagnosticLogService? diagnosticLogService,
    Duration fastPathTimeout = const Duration(seconds: 3),
    Future<bool> Function()? shouldRefreshForOpen,
    DateTime Function()? nowProvider,
  })  : _healthRefreshCoordinator = healthRefreshCoordinator,
        _repository = repository,
        _diagnosticLogService = diagnosticLogService,
        _fastPathTimeout = fastPathTimeout,
        _shouldRefreshForOpen = shouldRefreshForOpen,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        state = ValueNotifier<AppReadinessState>(
          const AppReadinessState(
            phase: 'idle',
            isRefreshing: false,
            reason: 'idle',
          ),
        );

  final HealthRefreshCoordinator _healthRefreshCoordinator;
  final WearableSampleRepository _repository;
  final DiagnosticLogService? _diagnosticLogService;
  final Duration _fastPathTimeout;
  final Future<bool> Function()? _shouldRefreshForOpen;
  final DateTime Function() _nowProvider;

  final ValueNotifier<AppReadinessState> state;

  static const _lastOpenReadyRefreshSettingKey =
      'last_successful_open_ready_refresh_at';
  static const _openReadyRefreshCooldown = Duration(minutes: 5);

  Future<void>? _runningRefresh;

  Future<void> refreshForOpen({required String reason}) async {
    final existing = _runningRefresh;
    if (existing != null) {
      await _diagnosticLogService?.debug(
        'open_ready_refresh_joined',
        category: DiagnosticLogService.categoryHealthSync,
        message:
            'Joined an existing open-ready refresh instead of starting another.',
        metadata: {'reason': reason, 'active_reason': state.value.reason},
      );
      return existing;
    }
    final future = _refreshForOpenInternal(reason: reason);
    _runningRefresh = future;
    return future.whenComplete(() {
      if (identical(_runningRefresh, future)) _runningRefresh = null;
    });
  }

  Future<void> _refreshForOpenInternal({required String reason}) async {
    final startedAt = _nowProvider();
    DateTime? priorSyncAt;
    try {
      final priorSync = await _repository.getSyncState('apple_health');
      priorSyncAt = priorSync?.lastSyncAt?.toUtc();
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'open_ready_prior_sync_lookup_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Could not load prior sync state before open-ready refresh.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason},
      );
    }

    final shouldRefresh =
        await (_shouldRefreshForOpen?.call() ?? Future<bool>.value(true));
    if (!shouldRefresh) {
      await _publishSkippedReady(
        reason: reason,
        startedAt: startedAt,
        priorSyncAt: priorSyncAt,
        skipReason: 'health_access_unavailable',
      );
      return;
    }

    if (await _hasRecentSuccessfulOpenReadyRefresh(startedAt)) {
      await _publishSkippedReady(
        reason: reason,
        startedAt: startedAt,
        priorSyncAt: priorSyncAt,
        skipReason: 'recent_open_ready_refresh',
      );
      return;
    }

    state.value = AppReadinessState(
      phase: 'refreshing',
      isRefreshing: true,
      reason: reason,
      lastSyncAt: priorSyncAt,
    );

    final refreshFuture = _healthRefreshCoordinator.refreshNow(
      reason: 'open_ready_$reason',
    );

    try {
      await refreshFuture.timeout(_fastPathTimeout);
      await _publishReady(
        phase: 'ready',
        reason: reason,
        startedAt: startedAt,
        timedOut: false,
      );
    } on TimeoutException {
      state.value = state.value.copyWith(
        phase: 'refreshing_background',
        isRefreshing: true,
        reason: reason,
        fastPathTimedOut: true,
      );
      unawaited(
        _finishInBackground(
          reason: reason,
          startedAt: startedAt,
          refreshFuture: refreshFuture,
        ),
      );
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'open_ready_refresh_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Open-ready refresh pipeline failed.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason},
      );
      state.value = state.value.copyWith(
        phase: 'failed',
        isRefreshing: false,
        reason: reason,
        hadError: true,
        errorMessage: error.runtimeType.toString(),
      );
    }
  }

  Future<void> _publishSkippedReady({
    required String reason,
    required DateTime startedAt,
    required DateTime? priorSyncAt,
    required String skipReason,
  }) async {
    final completedAt = _nowProvider();
    state.value = AppReadinessState(
      phase: 'ready_without_refresh',
      isRefreshing: false,
      reason: reason,
      lastSyncAt: priorSyncAt,
      lastCompletedAt: completedAt,
    );
    await _diagnosticLogService?.info(
      'open_ready_refresh_skipped',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Open-ready refresh skipped before foreground sync.',
      metadata: {
        'reason': reason,
        'skip_reason': skipReason,
        'duration_ms': completedAt.difference(startedAt).inMilliseconds,
      },
    );
  }

  Future<void> _finishInBackground({
    required String reason,
    required DateTime startedAt,
    required Future<void> refreshFuture,
  }) async {
    try {
      await refreshFuture;
      await _publishReady(
        phase: 'ready_after_background',
        reason: reason,
        startedAt: startedAt,
        timedOut: true,
      );
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'open_ready_refresh_background_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Background completion for open-ready refresh failed.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason},
      );
      state.value = state.value.copyWith(
        phase: 'failed',
        isRefreshing: false,
        reason: reason,
        hadError: true,
        errorMessage: error.runtimeType.toString(),
      );
    } finally {
      _runningRefresh = null;
    }
  }

  Future<void> _publishReady({
    required String phase,
    required String reason,
    required DateTime startedAt,
    required bool timedOut,
  }) async {
    DateTime? syncedAt;
    try {
      final syncState = await _repository.getSyncState('apple_health');
      syncedAt = syncState?.lastSyncAt?.toUtc();
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'open_ready_post_sync_lookup_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Could not load sync state after open-ready refresh.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason, 'phase': phase},
      );
    }
    final completedAt = _nowProvider();
    state.value = AppReadinessState(
      phase: phase,
      isRefreshing: false,
      reason: reason,
      lastSyncAt: syncedAt,
      lastCompletedAt: completedAt,
      fastPathTimedOut: timedOut,
    );
    await _diagnosticLogService?.info(
      'open_ready_refresh_completed',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Open-ready refresh pipeline completed.',
      metadata: {
        'reason': reason,
        'phase': phase,
        'fast_path_timeout': timedOut,
        'duration_ms': completedAt.difference(startedAt).inMilliseconds,
      },
    );
    try {
      await _repository.upsertAppSettingJson(
        key: _lastOpenReadyRefreshSettingKey,
        value: completedAt.toUtc().toIso8601String(),
      );
    } catch (error, stackTrace) {
      await _diagnosticLogService?.error(
        'open_ready_timestamp_persist_failed',
        category: DiagnosticLogService.categoryHealthSync,
        message: 'Could not persist successful open-ready refresh timestamp.',
        error: error,
        stackTrace: stackTrace,
        metadata: {'reason': reason, 'phase': phase},
      );
    }
  }

  Future<bool> _hasRecentSuccessfulOpenReadyRefresh(DateTime now) async {
    try {
      final raw = await _repository.getAppSettingJson(
        _lastOpenReadyRefreshSettingKey,
      );
      if (raw is! String || raw.trim().isEmpty) return false;
      final last = DateTime.tryParse(raw)?.toUtc();
      if (last == null || last.isAfter(now.toUtc())) return false;
      return now.toUtc().difference(last) < _openReadyRefreshCooldown;
    } catch (_) {
      return false;
    }
  }
}
