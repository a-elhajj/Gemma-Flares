// model_readiness_service.dart
// Reactive model-load state for the UI badge and chat availability checks.
//
// Call warmLoad() on cold start and every foreground resume. Any widget
// that needs to react to model state subscribes via ListenableBuilder.

import 'package:flutter/foundation.dart';

import 'local_model_runtime.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum ModelReadinessState {
  /// warmLoad() has been called but not yet completed.
  loading,

  /// LiteRT-LM engine is in RAM and ready to generate.
  ready,

  /// Model file is not on disk. Restart the app to re-trigger the wizard.
  missing,

  /// File exists but the engine failed to initialise (corrupt or OOM).
  corrupt,
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class ModelReadinessService extends ChangeNotifier {
  ModelReadinessState _state = ModelReadinessState.loading;
  ModelReadinessState get state => _state;

  bool get isReady => _state == ModelReadinessState.ready;
  bool get isBroken =>
      _state == ModelReadinessState.missing ||
      _state == ModelReadinessState.corrupt;

  // One-flight guard: concurrent callers share the in-flight future rather
  // than issuing redundant native load requests.
  Future<void>? _inFlight;

  /// Attempts to warm-load the model into RAM. Safe to call concurrently and
  /// on every foreground resume. Updates [state] and notifies listeners.
  Future<void> warmLoad(LocalModelRuntime runtime) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final f = _warmLoadInternal(runtime);
    _inFlight = f;
    return f.whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
  }

  Future<void> _warmLoadInternal(LocalModelRuntime runtime) async {
    _update(ModelReadinessState.loading);
    try {
      final status = await runtime.getRuntimeStatus();
      if (status.isModelLoaded) {
        _update(ModelReadinessState.ready);
        return;
      }
      if (!status.isBundledModelPresent) {
        // File not on disk — setup wizard must re-run on next cold start.
        _update(ModelReadinessState.missing);
        return;
      }
      await runtime.loadLocalModel(profile: 'phone_balanced');
      _update(ModelReadinessState.ready);
    } catch (_) {
      // File present but engine init failed: OOM, Metal shader error, etc.
      _update(ModelReadinessState.corrupt);
    }
  }

  void _update(ModelReadinessState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }
}
