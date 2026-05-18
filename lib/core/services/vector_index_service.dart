import 'deterministic_embedding_service.dart';
import 'embedding_service.dart';

/// Legacy vector-index facade used by older memory assembly paths.
///
/// Production RAG now uses [RagIndexService] with [LiteRtEmbeddingService] and
/// [DurableVectorStore]. This class deliberately avoids a native channel so no
/// RAG path depends on the removed local-model bridge.
///
/// Collections (7 defined by architecture):
/// - 'messages'       — conversation history embeddings
/// - 'symptoms'       — symptom log embeddings
/// - 'summaries'      — hierarchical summaries
/// - 'labs'           — lab result text embeddings
/// - 'procedures'     — procedure/clinical record embeddings
/// - 'checkins'       — check-in response embeddings
/// - 'knowledge'      — static clinical knowledge fragments
class VectorIndexService {
  final _fallbackEmbedding = DeterministicEmbeddingService();
  final Map<String, Map<String, _IndexedVectorDocument>> _collections = {};

  static const supportedCollections = <String>[
    'messages',
    'symptoms',
    'summaries',
    'labs',
    'procedures',
    'checkins',
    'knowledge',
  ];

  int? _embeddingDim;

  /// Initialize all 7 vector index collections.
  /// Probes embedding dimension on first call.
  Future<void> initialize() async {
    _embeddingDim = (await _fallbackEmbedding.embed('probe')).length;
    for (final collection in supportedCollections) {
      _collections.putIfAbsent(collection, () => {});
    }
  }

  /// Returns the embedding dimension probed at load time.
  int? get embeddingDim => _embeddingDim;

  // -------------------------------------------------------------------------
  // Embed
  // -------------------------------------------------------------------------

  /// Compute a text embedding vector via the native embed bridge.
  Future<List<double>> embed(String text) async {
    final vector = await _fallbackEmbedding.embed(text);
    _embeddingDim ??= vector.length;
    return vector;
  }

  // -------------------------------------------------------------------------
  // Index
  // -------------------------------------------------------------------------

  /// Add a text + metadata record to a collection.
  Future<void> addToIndex({
    required String collection,
    required String id,
    required String text,
    Map<String, Object?> metadata = const {},
  }) async {
    final normalizedCollection = _normalizeCollection(collection);
    final normalizedId = id.trim();
    if (normalizedId.isEmpty || text.trim().isEmpty) return;

    final vector = await embed(text);
    _collections.putIfAbsent(normalizedCollection, () => {})[normalizedId] =
        _IndexedVectorDocument(
      id: normalizedId,
      text: text,
      metadata: Map<String, Object?>.unmodifiable(metadata),
      embedding: List<double>.unmodifiable(vector),
    );
  }

  // -------------------------------------------------------------------------
  // Query
  // -------------------------------------------------------------------------

  /// ANN query against a collection, returning up to [topK] results.
  Future<List<VectorMatch>> query({
    required String collection,
    required List<double> queryEmbedding,
    int topK = 8,
  }) async {
    if (topK <= 0 || queryEmbedding.isEmpty) return const [];

    final normalizedCollection = _normalizeCollection(collection);
    final docs = _collections[normalizedCollection];
    if (docs == null || docs.isEmpty) return const [];

    final matches = <VectorMatch>[];
    for (final doc in docs.values) {
      if (doc.embedding.length != queryEmbedding.length) continue;
      matches.add(VectorMatch(
        id: doc.id,
        score: EmbeddingService.cosineSimilarity(queryEmbedding, doc.embedding),
        text: doc.text,
        metadata: doc.metadata,
        embedding: doc.embedding,
      ));
    }

    matches.sort((a, b) => b.score.compareTo(a.score));
    if (matches.length <= topK) return matches;
    return matches.take(topK).toList(growable: false);
  }

  String _normalizeCollection(String collection) {
    final normalized = collection.trim().toLowerCase();
    if (normalized.isEmpty) return 'messages';
    return normalized;
  }
}

class _IndexedVectorDocument {
  const _IndexedVectorDocument({
    required this.id,
    required this.text,
    required this.metadata,
    required this.embedding,
  });

  final String id;
  final String text;
  final Map<String, Object?> metadata;
  final List<double> embedding;
}

/// A single result returned from a vector index query.
class VectorMatch {
  const VectorMatch({
    required this.id,
    required this.score,
    required this.text,
    this.metadata = const {},
    this.embedding,
  });

  final String id;
  final double score;
  final String text;
  final Map<String, Object?> metadata;

  /// The embedding vector for this result, if returned by the native index.
  /// Present when the index is queried with returnEmbeddings: true.
  final List<double>? embedding;

  factory VectorMatch.fromMap(Map<Object?, Object?> map) {
    List<double>? embedding;
    final rawEmbedding = map['embedding'];
    if (rawEmbedding is List) {
      embedding = rawEmbedding
          .map((v) => (v as num).toDouble())
          .toList(growable: false);
    }
    return VectorMatch(
      id: map['id'] as String? ?? '',
      score: (map['score'] as num?)?.toDouble() ?? 0.0,
      text: map['text'] as String? ?? '',
      metadata: map['metadata'] != null
          ? Map<String, Object?>.from(map['metadata'] as Map)
          : const {},
      embedding: embedding,
    );
  }
}
