import 'dart:async';

import 'package:flutter/foundation.dart';

import 'local_model_runtime.dart';

/// Process-wide cache + broadcast for [LocalModelRuntimeStatus].
///
/// The native side enumerates 1500+ weight files on every `getRuntimeStatus`
/// call (a Swift-side validation cache softens the cost; this controller
/// removes the round-trip entirely for redundant callers). Multiple screens
/// subscribed to the runtime status used to issue independent platform-channel
/// calls on every rebuild; this controller funnels them through one call,
/// dedupes in-flight refreshes, and broadcasts the result through a
/// [ValueListenable] so every screen rebuilds from the same source of truth.
///
/// Use [refresh] when the caller needs the freshest possible value (post-
/// download, post-load, post-unload). Use [value] for any read where
/// "the most recent known status" is acceptable, which is true for almost
/// every UI read.
class RuntimeStatusController {
  RuntimeStatusController({
    required LocalModelRuntime runtime,
    Duration cacheTtl = const Duration(seconds: 5),
  })  : _runtime = runtime,
        _cacheTtl = cacheTtl;

  final LocalModelRuntime _runtime;
  final Duration _cacheTtl;
  final ValueNotifier<LocalModelRuntimeStatus?> _status = ValueNotifier(null);

  Future<LocalModelRuntimeStatus>? _inFlight;
  DateTime? _lastFetchedAt;

  /// Listenable view consumed by Flutter widgets via `ValueListenableBuilder`.
  ValueListenable<LocalModelRuntimeStatus?> get listenable => _status;

  /// Most-recently known status, or null if no fetch has ever completed.
  LocalModelRuntimeStatus? get value => _status.value;

  /// Returns the cached value if it is younger than [_cacheTtl]; otherwise
  /// triggers a single platform-channel refresh (deduped against any in-
  /// flight call) and resolves with the new value.
  Future<LocalModelRuntimeStatus> get({bool forceRefresh = false}) async {
    final cached = _status.value;
    final lastFetchedAt = _lastFetchedAt;
    final cacheStillFresh = cached != null &&
        lastFetchedAt != null &&
        DateTime.now().difference(lastFetchedAt) < _cacheTtl;
    if (!forceRefresh && cacheStillFresh) return cached;
    return refresh();
  }

  /// Force a refresh from the native runtime. Concurrent callers share one
  /// in-flight future so the platform channel is only hit once.
  Future<LocalModelRuntimeStatus> refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _runtime.getRuntimeStatus().then((status) {
      _status.value = status;
      _lastFetchedAt = DateTime.now();
      return status;
    }).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  /// Update the cache after callers have already obtained a status (for
  /// example as the return value of `loadBundledModel`). Avoids a duplicate
  /// round-trip.
  void publish(LocalModelRuntimeStatus status) {
    _status.value = status;
    _lastFetchedAt = DateTime.now();
  }

  /// Drop the cache so the next [get] forces a fresh fetch. Intended for
  /// post-install / post-wipe events where we know the runtime state moved.
  void invalidate() {
    _lastFetchedAt = null;
  }

  void dispose() {
    _status.dispose();
  }
}
