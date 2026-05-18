// =============================================================================
// DeterministicEmbeddingService — pure-Dart, CI-safe embedding implementation.
// =============================================================================
// Uses character n-gram hashing with a fixed random projection to produce
// 384-dimensional L2-normalized embeddings. No model file, no platform
// channel, no I/O — safe to use in any Flutter test environment.
//
// Semantic properties:
//   • Texts that share n-grams → closer in embedding space.
//   • Same text always → same vector (deterministic).
//   • Grammatically similar medical phrases have higher cosine similarity.
//
// Algorithm (random kitchen sinks / feature hashing):
//   1. Normalize: lowercase + collapse whitespace.
//   2. Extract character 3-grams and word unigrams from the text.
//   3. For each n-gram, seed a lightweight Xorshift64 PRNG with FNV-1a(gram).
//   4. Use the PRNG to generate a ±1 sparse random vector in R^384.
//   5. Accumulate (sum) all sparse vectors.
//   6. L2-normalize the result.
//
// Quality note: Suitable for round-trip correctness tests and approximate
// semantic retrieval. Not a substitute for a trained embedding model in
// production inference paths.
// =============================================================================

import 'embedding_service.dart';

class DeterministicEmbeddingService extends EmbeddingService {
  DeterministicEmbeddingService({int dimensions = 384})
      : _dimensions = dimensions;

  final int _dimensions;

  @override
  int get dimensions => _dimensions;

  @override
  String get providerName => 'deterministic';

  @override
  bool get isDeterministicFallbackActive => true;

  // ── Public API ─────────────────────────────────────────────────────────────

  @override
  Future<List<double>> embed(String text) async =>
      Future.value(_embedSync(text));

  /// Synchronous variant — useful in unit tests that don't need async.
  List<double> embedSync(String text) => _embedSync(text);

  // ── Core algorithm ─────────────────────────────────────────────────────────

  List<double> _embedSync(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return List.filled(_dimensions, 0.0);

    final accumulator = List.filled(_dimensions, 0.0);
    var tokenCount = 0;

    // Word unigrams.
    final words = normalized.split(RegExp(r'\s+'));
    for (final word in words) {
      if (word.isEmpty) continue;
      _addGramContribution(word, accumulator);
      tokenCount++;
    }

    // Character 3-grams (prefix-padded with space for boundary signal).
    final padded = ' $normalized ';
    for (var i = 0; i < padded.length - 2; i++) {
      final gram = padded.substring(i, i + 3);
      _addGramContribution(gram, accumulator);
      tokenCount++;
    }

    // Character 4-grams (additional context window).
    if (padded.length >= 4) {
      for (var i = 0; i < padded.length - 3; i++) {
        final gram = padded.substring(i, i + 4);
        _addGramContribution(gram, accumulator);
        tokenCount++;
      }
    }

    // Scale by token count to avoid magnitude explosion.
    if (tokenCount > 0) {
      for (var i = 0; i < _dimensions; i++) {
        accumulator[i] /= tokenCount;
      }
    }

    return EmbeddingService.l2Normalize(accumulator);
  }

  void _addGramContribution(String gram, List<double> accumulator) {
    final seed = _fnv1a64(gram);
    var state = seed == 0 ? 6364136223846793005 : seed;

    // Generate _dimensions projection values using Xorshift64.
    for (var d = 0; d < _dimensions; d++) {
      state = _xorshift64(state);
      // Map high bit to ±1.
      accumulator[d] += (state & 1) == 0 ? 1.0 : -1.0;
    }
  }

  // ── Text normalization ────────────────────────────────────────────────────

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s\-./]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ── Hash functions ────────────────────────────────────────────────────────

  /// FNV-1a 32-bit hash. Deterministic across all platforms.
  static int _fnv1a64(String s) {
    const offset = 2166136261;
    const prime = 16777619;
    var hash = offset;
    for (final c in s.codeUnits) {
      hash ^= c;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Xorshift64 PRNG — fast, no allocations.
  static int _xorshift64(int x) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x & 0xFFFFFFFFFFFFFFFF;
  }
}
