// =============================================================================
// RagQueryService — read-side for the LiteRT-LM RAG layer.
// =============================================================================
// Embeds the user's query, retrieves semantically similar documents from the
// VectorStore, applies time-decay reranking and MMR diversity filtering, and
// returns ranked results.
//
// Pair with RagIndexService (write-side) for full round-trip coverage.
// =============================================================================

import 'dart:math' as math;

import 'embedding_service.dart';
import 'rag_store.dart';

// ---------------------------------------------------------------------------
// Query result
// ---------------------------------------------------------------------------

class RagQueryResult {
  const RagQueryResult({
    required this.matches,
    required this.queryText,
    required this.totalSearched,
    required this.elapsedMs,
  });

  final List<RagMatch> matches;
  final String queryText;
  final int totalSearched;
  final int elapsedMs;

  bool get hasResults => matches.isNotEmpty;

  /// True if any match's text satisfies [predicate].
  bool anyTextContains(String substring, {bool caseSensitive = false}) {
    final q = caseSensitive ? substring : substring.toLowerCase();
    return matches.any((m) {
      final t = caseSensitive ? m.text : m.text.toLowerCase();
      return t.contains(q);
    });
  }

  /// All unique chunk IDs returned.
  List<String> get chunkIds => matches.map((m) => m.id).toList();

  @override
  String toString() =>
      'RagQueryResult(${matches.length} matches, elapsed=${elapsedMs}ms)';
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class RagQueryConfig {
  const RagQueryConfig({
    this.topKPerCollection = 4,
    this.maxTotal = 16,
    this.minScore = 0.0,
    this.decayHalfLifeDays = 30.0,
    this.mmrLambda = 0.7,
    this.collections,
  });

  final int topKPerCollection;
  final int maxTotal;
  final double minScore;

  /// Time-decay half-life in days. Older docs are penalised.
  final double decayHalfLifeDays;

  /// MMR lambda. 1.0 = pure similarity, 0.0 = pure diversity.
  final double mmrLambda;

  /// Collections to search. null = search all collections in the store.
  final List<String>? collections;
}

// ---------------------------------------------------------------------------
// RagQueryService
// ---------------------------------------------------------------------------

class RagQueryService {
  RagQueryService({
    required EmbeddingService embedding,
    required VectorStore store,
    DateTime Function()? now,
  })  : _embedding = embedding,
        _store = store,
        _now = now ?? (() => DateTime.now().toUtc());

  final EmbeddingService _embedding;
  final VectorStore _store;
  final DateTime Function() _now;

  // ── Main query API ────────────────────────────────────────────────────────

  /// Embed [queryText] and retrieve related documents.
  Future<RagQueryResult> query(
    String queryText, {
    RagQueryConfig config = const RagQueryConfig(),
  }) async {
    final sw = Stopwatch()..start();

    final queryVec = await _embedding.embed(queryText);
    final cols = config.collections ?? _store.collections;

    final all = <RagMatch>[];
    for (final col in cols) {
      final hits = await _store.query(
        collection: col,
        queryEmbedding: queryVec,
        topK: math.max(config.topKPerCollection, 50),
        minScore: -1.0,
      );
      all.addAll(hits);
    }

    final reranked = _rerank(all, config, queryText)
        .where((match) => match.score >= config.minScore)
        .toList();
    final diversified = _mmr(reranked, queryVec, config);
    final top = diversified.take(config.maxTotal).toList();

    sw.stop();
    return RagQueryResult(
      matches: top,
      queryText: queryText,
      totalSearched: all.length,
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  /// Query a single collection by name.
  Future<List<RagMatch>> queryCollection(
    String collection,
    String queryText, {
    int topK = 8,
    double minScore = 0.0,
  }) async {
    final vec = await _embedding.embed(queryText);
    final hits = await _store.query(
      collection: collection,
      queryEmbedding: vec,
      topK: math.max(topK, 50),
      minScore: -1.0,
    );
    return _rerank(
      hits,
      RagQueryConfig(
        topKPerCollection: topK,
        maxTotal: topK,
        minScore: minScore,
      ),
      queryText,
    ).where((match) => match.score >= minScore).take(topK).toList();
  }

  // ── Verify round-trip ─────────────────────────────────────────────────────

  /// Returns true if querying with [queryText] returns a document whose text
  /// contains ALL of [expectedSubstrings] (case-insensitive by default).
  Future<bool> verifyRoundTrip(
    String queryText,
    List<String> expectedSubstrings, {
    bool caseSensitive = false,
    RagQueryConfig config = const RagQueryConfig(),
  }) async {
    final result = await query(queryText, config: config);
    for (final expected in expectedSubstrings) {
      final q = caseSensitive ? expected : expected.toLowerCase();
      final found = result.matches.any((m) {
        final t = caseSensitive ? m.text : m.text.toLowerCase();
        return t.contains(q);
      });
      if (!found) return false;
    }
    return true;
  }

  /// Retrieve a document by its exact chunk ID and collection.
  Future<RagMatch?> getById({
    required String collection,
    required String chunkId,
  }) =>
      _store.get(collection: collection, id: chunkId);

  /// Returns true if the chunk exists in the store.
  Future<bool> exists({
    required String collection,
    required String chunkId,
  }) =>
      _store.exists(collection: collection, id: chunkId);

  // ── Corpus management reads (mirrors RagCorpusService read API) ────────────

  /// Returns all chunk IDs in the given [collection], or all collections.
  Future<List<String>> listChunkIds({String? collection}) async {
    final cols = collection != null ? [collection] : _store.collections;
    final ids = <String>[];
    for (final col in cols) {
      final matches = await _store.query(
        collection: col,
        queryEmbedding: const [],
        topK: 10000,
        minScore: -1.0,
      );
      ids.addAll(matches.map((m) => m.id));
    }
    return ids;
  }

  /// Read a chunk's text by ID. Returns null if not found.
  Future<String?> readChunk({
    required String collection,
    required String chunkId,
  }) async {
    final match = await _store.get(collection: collection, id: chunkId);
    return match?.text;
  }

  /// Returns true if a chunk with [chunkId] exists in [collection].
  Future<bool> chunkExists({
    required String collection,
    required String chunkId,
  }) =>
      _store.exists(collection: collection, id: chunkId);

  /// Reassembles a potentially multi-part chunk written with a base ID.
  /// Checks the base ID first, then tries `${baseId}_p1`, `${baseId}_p2`, etc.
  Future<String?> readChunkedForVerification(
      String baseId, String collection) async {
    // Try single-part first.
    final single = await readChunk(collection: collection, chunkId: baseId);
    if (single != null) return single;

    // Try multi-part.
    final buffer = StringBuffer();
    var foundAny = false;
    for (var index = 1; index <= 512; index++) {
      final chunk =
          await readChunk(collection: collection, chunkId: '${baseId}_p$index');
      if (chunk == null) break;
      foundAny = true;
      buffer.write(chunk);
    }
    return foundAny ? buffer.toString() : null;
  }

  // ── Time-decay reranking ──────────────────────────────────────────────────

  List<RagMatch> _rerank(
    List<RagMatch> matches,
    RagQueryConfig config,
    String queryText,
  ) {
    if (config.decayHalfLifeDays <= 0) return List.of(matches);
    final now = _now();
    final decayed = matches.map((m) {
      final ts = _timestampFromMetadata(m.metadata) ?? now;
      final ageDays = now.difference(ts).inHours / 24.0;
      final decayFactor = math.pow(0.5, ageDays / config.decayHalfLifeDays);
      final lexicalScore = _lexicalSimilarity(queryText, m.text);
      final blendedScore = (m.score * 0.65) + (lexicalScore * 0.35);
      final adjustedScore = blendedScore * decayFactor;
      return _DecayedMatch(
        match: RagMatch(
          id: m.id,
          collection: m.collection,
          text: m.text,
          score: adjustedScore,
          metadata: m.metadata,
          embedding: m.embedding,
        ),
        adjustedScore: adjustedScore,
      );
    }).toList();
    decayed.sort((a, b) => b.adjustedScore.compareTo(a.adjustedScore));
    return decayed.map((d) => d.match).toList();
  }

  // ── MMR diversity ─────────────────────────────────────────────────────────

  List<RagMatch> _mmr(
    List<RagMatch> candidates,
    List<double> queryVec,
    RagQueryConfig config,
  ) {
    if (candidates.isEmpty) return const [];
    if (config.mmrLambda >= 1.0) return candidates;

    final selected = <RagMatch>[];
    final remaining = List.of(candidates);

    while (selected.length < config.maxTotal && remaining.isNotEmpty) {
      var bestIdx = 0;
      var bestScore = double.negativeInfinity;

      for (var i = 0; i < remaining.length; i++) {
        final candidate = remaining[i];
        final simToQuery = candidate.score;

        // Max similarity to any already-selected doc.
        double maxSimToSelected = 0.0;
        for (final s in selected) {
          final sim = _textSimilarity(candidate.text, s.text);
          if (sim > maxSimToSelected) maxSimToSelected = sim;
        }

        final mmrScore = config.mmrLambda * simToQuery -
            (1.0 - config.mmrLambda) * maxSimToSelected;

        if (mmrScore > bestScore) {
          bestScore = mmrScore;
          bestIdx = i;
        }
      }

      selected.add(remaining[bestIdx]);
      remaining.removeAt(bestIdx);
    }

    return selected;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static DateTime? _timestampFromMetadata(Map<String, Object?> meta) {
    for (final key in [
      'logged_at',
      'drawn_date',
      'date_local',
      'installed_at',
      'survey_date',
      'created_at'
    ]) {
      final v = meta[key];
      if (v is String && v.isNotEmpty) {
        try {
          return DateTime.parse(v);
        } catch (_) {}
      }
    }
    return null;
  }

  // Lightweight Jaccard 3-gram similarity (fallback when embeddings differ).
  static double _textSimilarity(String a, String b) {
    final setA = _trigrams(a.toLowerCase());
    final setB = _trigrams(b.toLowerCase());
    if (setA.isEmpty && setB.isEmpty) return 1.0;
    if (setA.isEmpty || setB.isEmpty) return 0.0;
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union == 0 ? 0.0 : intersection / union;
  }

  static Set<String> _trigrams(String s) {
    if (s.length < 3) return {s};
    final out = <String>{};
    for (var i = 0; i < s.length - 2; i++) {
      out.add(s.substring(i, i + 3));
    }
    return out;
  }

  static double _lexicalSimilarity(String query, String text) {
    final queryTerms = _terms(query);
    if (queryTerms.isEmpty) return 0.0;
    final textTerms = _terms(text);
    if (textTerms.isEmpty) return 0.0;
    final exactHits = queryTerms.intersection(textTerms).length;
    final exactScore = exactHits / queryTerms.length;
    final trigramScore = _textSimilarity(query, text);
    return (exactScore * 0.8) + (trigramScore * 0.2);
  }

  static Set<String> _terms(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((term) => term.length >= 3)
      .toSet();
}

class _DecayedMatch {
  const _DecayedMatch({required this.match, required this.adjustedScore});
  final RagMatch match;
  final double adjustedScore;
}
