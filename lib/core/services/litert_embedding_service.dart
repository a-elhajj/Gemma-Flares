// =============================================================================
// LiteRtEmbeddingService — on-device TFLite embedding for iOS production.
// =============================================================================
// Primary path : Flutter MethodChannel → native TFLite model inference
//                (all-MiniLM-L6-v2, 384-dim, bundled as assets/models/embedding.tflite)
// Fallback path: DeterministicEmbeddingService — zero-dependency pure Dart.
//
// Fallback fires when:
//   • Running in CI / simulator (MissingPluginException)
//   • TFLite model not loaded yet (cold start, model not installed)
//   • Native returns an error or empty vector
//
// Channel protocol (com.gutguard/litert_embedding):
//   embed({'text': String}) → {'vector': List<double>, 'dim': int}
//   getStatus()            → {'loaded': bool, 'dim': int, 'model': String}
//
// Thread safety: the MethodChannel is called serially — one embed at a time.
// Concurrent calls are queued by the Flutter engine automatically.
// =============================================================================

import 'package:flutter/services.dart';

import 'deterministic_embedding_service.dart';
import 'embedding_service.dart';

class LiteRtEmbeddingService extends EmbeddingService {
  LiteRtEmbeddingService({
    MethodChannel? channel,
    EmbeddingService? fallback,
    int nativeDimensions = 384,
    bool allowDeterministicFallback = true,
  })  : _channel =
            channel ?? const MethodChannel('com.gutguard/litert_embedding'),
        _fallback = fallback ?? DeterministicEmbeddingService(dimensions: 384),
        _nativeDimensions = nativeDimensions,
        _allowDeterministicFallback = allowDeterministicFallback;

  final MethodChannel _channel;
  final EmbeddingService _fallback;
  final int _nativeDimensions;
  final bool _allowDeterministicFallback;

  bool _nativeAvailable = true; // optimistic; cleared on first MissingPlugin
  String _activeProvider = 'initializing';
  int _fallbackCount = 0;
  String? _lastFallbackReason;

  @override
  int get dimensions => _nativeDimensions;

  /// Which provider is currently serving embeddings.
  /// 'litert-tflite', 'deterministic', or 'initializing'.
  String get activeProvider => _activeProvider;

  @override
  String get providerName => _activeProvider;

  @override
  bool get isDeterministicFallbackActive => _activeProvider == 'deterministic';

  int get fallbackCount => _fallbackCount;
  String? get lastFallbackReason => _lastFallbackReason;

  @override
  Future<List<double>> embed(String text) async {
    if (!_nativeAvailable) {
      return _fallbackEmbed(text, reason: 'native_previously_unavailable');
    }

    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'embed',
        {'text': text},
      );

      final vector = _parseVector(raw);
      if (vector == null || vector.isEmpty) {
        return _fallbackEmbed(text, reason: 'native_empty_vector');
      }

      _activeProvider = 'litert-tflite';
      return vector;
    } on MissingPluginException {
      _nativeAvailable = false;
      return _fallbackEmbed(text, reason: 'native_missing_plugin');
    } on PlatformException catch (error) {
      // Transient error (model loading, OOM) — don't permanently disable native.
      return _fallbackEmbed(text, reason: 'native_platform_${error.code}');
    }
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    if (!_nativeAvailable) {
      return _fallbackEmbedBatch(texts,
          reason: 'native_previously_unavailable');
    }

    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'embedBatch',
        {'texts': texts},
      );

      if (raw == null || raw.isEmpty) {
        return _fallbackEmbedBatch(texts, reason: 'native_empty_batch');
      }

      final results = <List<double>>[];
      for (final item in raw) {
        if (item is List) {
          results.add(item.cast<double>());
        } else {
          // Fall back for this batch if any entry is malformed.
          return _fallbackEmbedBatch(texts, reason: 'native_malformed_batch');
        }
      }
      _activeProvider = 'litert-tflite';
      return results;
    } on MissingPluginException {
      _nativeAvailable = false;
      return _fallbackEmbedBatch(texts, reason: 'native_missing_plugin');
    } on PlatformException catch (error) {
      return _fallbackEmbedBatch(texts,
          reason: 'native_platform_${error.code}');
    }
  }

  /// Query native TFLite status. Returns null if unavailable.
  Future<Map<String, dynamic>?> getStatus() async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('getStatus');
    } on MissingPluginException {
      _nativeAvailable = false;
      return null;
    } on PlatformException {
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<List<double>> _fallbackEmbed(
    String text, {
    required String reason,
  }) async {
    _fallbackCount += 1;
    _lastFallbackReason = reason;
    if (!_allowDeterministicFallback) {
      throw StateError(
        'Deterministic embedding fallback is disabled for this build: $reason',
      );
    }
    _activeProvider = 'deterministic';
    return _fallback.embed(text);
  }

  Future<List<List<double>>> _fallbackEmbedBatch(
    List<String> texts, {
    required String reason,
  }) async {
    _fallbackCount += texts.length;
    _lastFallbackReason = reason;
    if (!_allowDeterministicFallback) {
      throw StateError(
        'Deterministic embedding fallback is disabled for this build: $reason',
      );
    }
    _activeProvider = 'deterministic';
    return _fallback.embedBatch(texts);
  }

  static List<double>? _parseVector(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final v = raw['vector'];
    if (v is List) return v.cast<double>();
    return null;
  }
}
