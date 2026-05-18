// =============================================================================
// EmbeddingService — abstract interface for text-to-vector embedding.
// =============================================================================
// All implementations must:
//   • Return L2-normalized unit vectors (cosine similarity ≡ dot product).
//   • Be deterministic: same text → same vector, always.
//   • Be thread-safe: concurrent calls must not corrupt each other's output.
//   • Return `dimensions`-length vectors, no more, no less.
//
// Production path  : LiteRtEmbeddingService  (TFLite model on iOS, 384-dim)
// Test / CI path   : DeterministicEmbeddingService (pure Dart, 384-dim)
// =============================================================================

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Abstract interface
// ---------------------------------------------------------------------------

abstract class EmbeddingService {
  /// Number of dimensions in every vector returned by [embed].
  int get dimensions;

  /// Human-readable provider currently serving embeddings.
  String get providerName => runtimeType.toString();

  /// True when this service is using a deterministic/test fallback instead of
  /// a production embedding model. Production retrieval should surface this in
  /// readiness/telemetry and may block it entirely.
  bool get isDeterministicFallbackActive => false;

  /// Embed [text] into a unit-length L2-normalized vector.
  /// Returns a list of length [dimensions].
  Future<List<double>> embed(String text);

  /// Embed multiple texts. Default: sequential calls to [embed].
  /// Subclasses may batch for efficiency.
  Future<List<List<double>>> embedBatch(List<String> texts) =>
      Future.wait(texts.map(embed));

  // ── Static utilities ──────────────────────────────────────────────────────

  /// Cosine similarity between two L2-normalized vectors.
  /// Clamped to [-1, 1] to guard against floating-point drift.
  static double cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length, 'Vector dimensions must match');
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }

  /// L2-normalize [v] in place. Returns [v] for chaining.
  /// If the vector is all-zero, returns a zero vector (safe no-op).
  static List<double> l2Normalize(List<double> v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm < 1e-12) return v;
    final inv = 1.0 / math.sqrt(norm);
    for (var i = 0; i < v.length; i++) {
      v[i] *= inv;
    }
    return v;
  }

  /// Euclidean distance between two vectors.
  static double euclideanDistance(List<double> a, List<double> b) {
    assert(a.length == b.length);
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}

// ---------------------------------------------------------------------------
// Shared embedding result wrapper
// ---------------------------------------------------------------------------

class EmbeddingResult {
  const EmbeddingResult({
    required this.text,
    required this.vector,
    required this.providerName,
  });

  final String text;
  final List<double> vector;
  final String providerName;

  double similarityTo(EmbeddingResult other) =>
      EmbeddingService.cosineSimilarity(vector, other.vector);
}
