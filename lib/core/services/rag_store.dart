// =============================================================================
// RagStore — VectorStore interface + implementations.
// =============================================================================
// VectorStore is the low-level embedding storage layer used by RagIndexService
// and RagQueryService. It is separate from EmbeddingService so embedding and
// storage can be tested and swapped independently.
//
// Implementations:
//   InMemoryVectorStore — pure Dart, brute-force cosine. For tests and CI.
//   DurableVectorStore  — encrypted-sandbox-friendly JSON vector store. Prod.
//   NativeVectorStore   — legacy adapter for native ANN, kept for tests/tools.
// =============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'embedding_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'vector_index_service.dart';

// ---------------------------------------------------------------------------
// Result type
// ---------------------------------------------------------------------------

class RagMatch {
  const RagMatch({
    required this.id,
    required this.collection,
    required this.text,
    required this.score,
    required this.metadata,
    this.embedding,
  });

  final String id;
  final String collection;
  final String text;
  final double score; // cosine similarity [−1, 1], higher = more relevant
  final Map<String, Object?> metadata;
  final List<double>? embedding;

  @override
  String toString() =>
      'RagMatch(id=$id, collection=$collection, score=${score.toStringAsFixed(3)})';
}

// ---------------------------------------------------------------------------
// Abstract VectorStore
// ---------------------------------------------------------------------------

abstract class VectorStore {
  /// All collection names this store manages.
  List<String> get collections;

  /// Add or replace a document in [collection].
  Future<void> add({
    required String collection,
    required String id,
    required List<double> embedding,
    required String text,
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  });

  /// Similarity search: returns up to [topK] matches ordered by descending score.
  Future<List<RagMatch>> query({
    required String collection,
    required List<double> queryEmbedding,
    int topK = 8,
    double minScore = -1.0,
  });

  /// Cross-collection search. Merges and re-ranks results from all collections.
  Future<List<RagMatch>> queryAll({
    required List<double> queryEmbedding,
    int topKPerCollection = 4,
    double minScore = -1.0,
  }) async {
    final results = <RagMatch>[];
    for (final col in collections) {
      final matches = await query(
        collection: col,
        queryEmbedding: queryEmbedding,
        topK: topKPerCollection,
        minScore: minScore,
      );
      results.addAll(matches);
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Returns the number of documents stored in [collection].
  Future<int> count(String collection);

  /// Deletes all documents in [collection].
  Future<void> clearCollection(String collection);

  /// Deletes a specific document.
  Future<void> delete({required String collection, required String id});

  /// Returns true if a document with [id] exists in [collection].
  Future<bool> exists({required String collection, required String id});

  /// Retrieve a stored document by ID (null if not found).
  Future<RagMatch?> get({required String collection, required String id});
}

// ---------------------------------------------------------------------------
// InMemoryVectorStore — brute-force cosine similarity, pure Dart.
// ---------------------------------------------------------------------------

class InMemoryVectorStore implements VectorStore {
  InMemoryVectorStore({Iterable<String>? collections})
      : _store = {
          for (final c in (collections ?? _defaultCollections)) c: {},
        };

  static const _defaultCollections = [
    'messages',
    'symptoms',
    'summaries',
    'labs',
    'procedures',
    'checkins',
    'knowledge',
    'profile',
    'food',
    'model_events',
    'medications',
    'health_sync',
    'gi_exports',
  ];

  // collection → id → document
  final Map<String, Map<String, _StoredDoc>> _store;

  @override
  List<String> get collections => _store.keys.toList();

  @override
  Future<void> add({
    required String collection,
    required String id,
    required List<double> embedding,
    required String text,
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  }) async {
    _store.putIfAbsent(collection, () => {})[id] = _StoredDoc(
      id: id,
      embedding: List.unmodifiable(embedding),
      text: text,
      metadata: Map.unmodifiable(metadata),
      timestamp: timestamp ?? DateTime.now().toUtc(),
    );
  }

  @override
  Future<List<RagMatch>> query({
    required String collection,
    required List<double> queryEmbedding,
    int topK = 8,
    double minScore = -1.0,
  }) async {
    final docs = _store[collection];
    if (docs == null || docs.isEmpty) return const [];

    final scored = <_ScoredDoc>[];
    for (final doc in docs.values) {
      final score =
          EmbeddingService.cosineSimilarity(queryEmbedding, doc.embedding);
      if (score >= minScore) {
        scored.add(_ScoredDoc(doc: doc, score: score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored
        .take(math.min(topK, scored.length))
        .map((s) => RagMatch(
              id: s.doc.id,
              collection: collection,
              text: s.doc.text,
              score: s.score,
              metadata: s.doc.metadata,
              embedding: List.of(s.doc.embedding),
            ))
        .toList(growable: false);
  }

  @override
  Future<List<RagMatch>> queryAll({
    required List<double> queryEmbedding,
    int topKPerCollection = 4,
    double minScore = -1.0,
  }) async {
    final results = <RagMatch>[];
    for (final col in collections) {
      results.addAll(await query(
        collection: col,
        queryEmbedding: queryEmbedding,
        topK: topKPerCollection,
        minScore: minScore,
      ));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  @override
  Future<int> count(String collection) async => _store[collection]?.length ?? 0;

  @override
  Future<void> clearCollection(String collection) async =>
      _store[collection]?.clear();

  @override
  Future<void> delete({
    required String collection,
    required String id,
  }) async =>
      _store[collection]?.remove(id);

  @override
  Future<bool> exists({
    required String collection,
    required String id,
  }) async =>
      _store[collection]?.containsKey(id) ?? false;

  @override
  Future<RagMatch?> get({
    required String collection,
    required String id,
  }) async {
    final doc = _store[collection]?[id];
    if (doc == null) return null;
    return RagMatch(
      id: id,
      collection: collection,
      text: doc.text,
      score: 1.0,
      metadata: doc.metadata,
      embedding: List.of(doc.embedding),
    );
  }

  /// Returns ALL documents in [collection] (for test verification).
  Future<List<RagMatch>> all(String collection) async {
    final docs = _store[collection];
    if (docs == null) return const [];
    return docs.values
        .map((doc) => RagMatch(
              id: doc.id,
              collection: collection,
              text: doc.text,
              score: 1.0,
              metadata: doc.metadata,
              embedding: List.of(doc.embedding),
            ))
        .toList(growable: false);
  }

  /// Total document count across all collections.
  Future<int> totalCount() async {
    var n = 0;
    for (final docs in _store.values) {
      n += docs.length;
    }
    return n;
  }
}

// ---------------------------------------------------------------------------
// DurableVectorStore — local persistent vector store for production RAG.
// ---------------------------------------------------------------------------

/// Durable local RAG store.
///
/// This intentionally does not depend on the old native `local_model` channel.
/// Each chunk is stored as one JSON file under Application Support, protected by
/// the iOS app sandbox and normal device data protection. The store is simple
/// brute-force cosine search; for the current on-device personal corpus size,
/// correctness and durability matter more than ANN complexity. A native ANN
/// index can be layered underneath later without changing RagIndexService.
class DurableVectorStore implements VectorStore {
  DurableVectorStore({
    Directory? rootDirectory,
    Iterable<String>? collections,
  })  : _rootDirectory = rootDirectory,
        _collections = List.unmodifiable(
          collections ?? InMemoryVectorStore._defaultCollections,
        );

  final Directory? _rootDirectory;
  final List<String> _collections;

  Future<Directory> _root() async {
    final configured = _rootDirectory;
    if (configured != null) {
      await configured.create(recursive: true);
      return configured;
    }
    final support = await getApplicationSupportDirectory();
    final root =
        Directory(p.join(support.path, 'GutGuard', 'RagVectorStore', 'v1'));
    await root.create(recursive: true);
    return root;
  }

  @override
  List<String> get collections => _collections;

  @override
  Future<void> add({
    required String collection,
    required String id,
    required List<double> embedding,
    required String text,
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  }) async {
    _validateCollection(collection);
    _validateId(id);
    if (embedding.isEmpty) {
      throw ArgumentError.value(embedding, 'embedding', 'must not be empty');
    }
    final dir = await _collectionDir(collection);
    final file = File(p.join(dir.path, '${_safeId(id)}.json'));
    final tmp = File('${file.path}.tmp');
    final record = {
      'schema_version': 1,
      'id': id,
      'collection': collection,
      'text': text,
      'metadata': metadata,
      'embedding': embedding,
      'timestamp': (timestamp ?? DateTime.now().toUtc()).toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(record)}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  @override
  Future<List<RagMatch>> query({
    required String collection,
    required List<double> queryEmbedding,
    int topK = 8,
    double minScore = -1.0,
  }) async {
    _validateCollection(collection);
    if (queryEmbedding.isEmpty || topK <= 0) return const [];
    final docs = await _readCollection(collection);
    final scored = <RagMatch>[];
    for (final doc in docs) {
      final score =
          EmbeddingService.cosineSimilarity(queryEmbedding, doc.embedding);
      if (score >= minScore) {
        scored.add(RagMatch(
          id: doc.id,
          collection: collection,
          text: doc.text,
          score: score,
          metadata: doc.metadata,
          embedding: List.of(doc.embedding),
        ));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(math.min(topK, scored.length)).toList(growable: false);
  }

  @override
  Future<List<RagMatch>> queryAll({
    required List<double> queryEmbedding,
    int topKPerCollection = 4,
    double minScore = -1.0,
  }) async {
    final results = <RagMatch>[];
    for (final collection in collections) {
      results.addAll(await query(
        collection: collection,
        queryEmbedding: queryEmbedding,
        topK: topKPerCollection,
        minScore: minScore,
      ));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  @override
  Future<int> count(String collection) async {
    _validateCollection(collection);
    final dir = await _collectionDir(collection, create: false);
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path) == '.json') n++;
    }
    return n;
  }

  @override
  Future<void> clearCollection(String collection) async {
    _validateCollection(collection);
    final dir = await _collectionDir(collection, create: false);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  @override
  Future<void> delete({required String collection, required String id}) async {
    _validateCollection(collection);
    _validateId(id);
    final file = await _fileFor(collection, id, createDir: false);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists({required String collection, required String id}) async {
    _validateCollection(collection);
    _validateId(id);
    return (await _fileFor(collection, id, createDir: false)).exists();
  }

  @override
  Future<RagMatch?> get(
      {required String collection, required String id}) async {
    _validateCollection(collection);
    _validateId(id);
    final file = await _fileFor(collection, id, createDir: false);
    final doc = await _readDoc(file);
    if (doc == null) return null;
    return RagMatch(
      id: doc.id,
      collection: collection,
      text: doc.text,
      score: 1.0,
      metadata: doc.metadata,
      embedding: List.of(doc.embedding),
    );
  }

  Future<Directory> _collectionDir(String collection,
      {bool create = true}) async {
    final dir = Directory(p.join((await _root()).path, _safeId(collection)));
    if (create) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _fileFor(
    String collection,
    String id, {
    required bool createDir,
  }) async {
    final dir = await _collectionDir(collection, create: createDir);
    return File(p.join(dir.path, '${_safeId(id)}.json'));
  }

  Future<List<_StoredDoc>> _readCollection(String collection) async {
    final dir = await _collectionDir(collection, create: false);
    if (!await dir.exists()) return const [];
    final docs = <_StoredDoc>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      final doc = await _readDoc(entity);
      if (doc != null) docs.add(doc);
    }
    return docs;
  }

  Future<_StoredDoc?> _readDoc(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final embedding = (decoded['embedding'] as List)
          .map((value) => (value as num).toDouble())
          .toList(growable: false);
      final timestamp =
          DateTime.tryParse(decoded['timestamp']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      return _StoredDoc(
        id: decoded['id']?.toString() ?? p.basenameWithoutExtension(file.path),
        embedding: embedding,
        text: decoded['text']?.toString() ?? '',
        metadata: decoded['metadata'] is Map
            ? Map<String, Object?>.from(decoded['metadata'] as Map)
            : const {},
        timestamp: timestamp,
      );
    } catch (_) {
      return null;
    }
  }

  void _validateCollection(String collection) {
    if (collection.trim().isEmpty) {
      throw ArgumentError.value(collection, 'collection', 'must not be empty');
    }
  }

  void _validateId(String id) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
  }

  static String _safeId(String raw) =>
      base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
}

// ---------------------------------------------------------------------------
// NativeVectorStore — wraps VectorIndexService for production use.
// ---------------------------------------------------------------------------

/// Bridges RagIndexService to the native HNSW implementation.
/// Embedding is done externally (by EmbeddingService); this class only stores
/// the pre-computed vectors and delegates ANN queries to VectorIndexService.
///
/// Note: [VectorIndexService.addToIndex] embeds internally on the native side.
/// Text + metadata are passed via addToIndex which re-embeds; this redundancy
/// is acceptable until a direct vector-store call is available.
class NativeVectorStore implements VectorStore {
  NativeVectorStore(this._vectorIndex);

  final VectorIndexService _vectorIndex;

  @override
  List<String> get collections => const [
        'messages',
        'symptoms',
        'summaries',
        'labs',
        'procedures',
        'checkins',
        'knowledge',
        'profile',
        'food',
        'model_events',
        'medications',
        'health_sync',
        'gi_exports',
      ];

  @override
  Future<void> add({
    required String collection,
    required String id,
    required List<double> embedding,
    required String text,
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  }) async {
    // NativeVectorStore re-embeds internally; we pass the text and metadata.
    await _vectorIndex.addToIndex(
      collection: collection,
      id: id,
      text: text,
      metadata: metadata,
    );
  }

  @override
  Future<List<RagMatch>> query({
    required String collection,
    required List<double> queryEmbedding,
    int topK = 8,
    double minScore = -1.0,
  }) async {
    final matches = await _vectorIndex.query(
      collection: collection,
      queryEmbedding: queryEmbedding,
      topK: topK,
    );
    return matches
        .where((m) => m.score >= minScore)
        .map((m) => RagMatch(
              id: m.id,
              collection: collection,
              text: m.text,
              score: m.score,
              metadata: m.metadata,
              embedding: m.embedding,
            ))
        .toList(growable: false);
  }

  @override
  Future<List<RagMatch>> queryAll({
    required List<double> queryEmbedding,
    int topKPerCollection = 4,
    double minScore = -1.0,
  }) async {
    final results = <RagMatch>[];
    for (final col in collections) {
      results.addAll(await query(
        collection: col,
        queryEmbedding: queryEmbedding,
        topK: topKPerCollection,
        minScore: minScore,
      ));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  @override
  Future<int> count(String collection) async =>
      0; // native store doesn't expose count yet

  @override
  Future<void> clearCollection(String collection) async {}

  @override
  Future<void> delete({required String collection, required String id}) async {}

  @override
  Future<bool> exists({required String collection, required String id}) async =>
      false;

  @override
  Future<RagMatch?> get(
          {required String collection, required String id}) async =>
      null;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

class _StoredDoc {
  const _StoredDoc({
    required this.id,
    required this.embedding,
    required this.text,
    required this.metadata,
    required this.timestamp,
  });

  final String id;
  final List<double> embedding;
  final String text;
  final Map<String, Object?> metadata;
  final DateTime timestamp;
}

class _ScoredDoc {
  const _ScoredDoc({required this.doc, required this.score});
  final _StoredDoc doc;
  final double score;
}
