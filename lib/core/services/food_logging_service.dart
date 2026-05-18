import '../database/wearable_sample_repository.dart';
import 'food_entry.dart';
import 'rag_index_service.dart';
import 'rag_memory_service.dart';
import 'rag_text_formatter.dart';

class FoodLoggingResult {
  const FoodLoggingResult({
    required this.savedEntry,
    required this.ragIndexed,
    required this.ragStatus,
    required this.ragTransactionId,
    required this.ragVerified,
  });

  final FoodEntry savedEntry;
  final bool ragIndexed;
  final String ragStatus;
  final String ragTransactionId;
  final bool ragVerified;
}

class FoodLoggingService {
  FoodLoggingService({
    required WearableSampleRepository repository,
    RagIndexService? ragIndexService,
    RagMemoryService? ragMemoryService,
  })  : _repository = repository,
        _ragIndexService = ragIndexService,
        _ragMemoryService = ragMemoryService;

  final WearableSampleRepository _repository;
  final RagIndexService? _ragIndexService;
  final RagMemoryService? _ragMemoryService;

  Future<FoodLoggingResult> saveFoodEntry(FoodEntry entry) async {
    final foodName = entry.foodName.trim();
    if (foodName.isEmpty) {
      throw ArgumentError.value(entry.foodName, 'foodName', 'Cannot be empty.');
    }

    final normalized = entry.copyWith(
      foodName: foodName,
      description: _trimOrNull(entry.description),
      mealType: _normalizeMealType(entry.mealType),
      portionUnit: _trimOrNull(entry.portionUnit),
      notes: _trimOrNull(entry.notes),
      source: _trimOrNull(entry.source) ?? 'manual',
      allergens: entry.allergens
          .map((item) => item.trim().toLowerCase())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false),
    );

    final id = await _repository.upsertFoodEntry(normalized);
    final saved = normalized.copyWith(id: id);
    final rag = await _indexForRag(saved);
    return FoodLoggingResult(
      savedEntry: saved,
      ragIndexed: rag.indexed,
      ragStatus: rag.status,
      ragTransactionId: rag.transactionId,
      ragVerified: rag.verified,
    );
  }

  Future<_FoodRagResult> _indexForRag(FoodEntry entry) async {
    final id = entry.id;
    if (id == null) {
      return const _FoodRagResult(
        indexed: false,
        status: 'missing_id',
        transactionId: '',
        verified: false,
      );
    }

    final transactionId = RagTextFormatter.foodChunkIdFromInt(id);
    var indexed = false;
    var status = 'not_configured';
    var verified = false;

    final ragMemory = _ragMemoryService;
    if (ragMemory != null) {
      try {
        final result = await ragMemory.writeAndVerify(
          transactionId: transactionId,
          sourceType: 'food_entry',
          sourceId: '$id',
          text: RagTextFormatter.formatFoodEntry('$id', entry),
          metadata: RagTextFormatter.foodMetadata('$id', entry),
        );
        indexed = result.status == RagMemoryStatus.verified ||
            result.status == RagMemoryStatus.writtenToCorpus ||
            result.status == RagMemoryStatus.loadedInRag;
        status = result.status;
        verified = result.status == RagMemoryStatus.verified;
      } catch (_) {
        status = RagMemoryStatus.failed;
      }
    }

    final ragIndex = _ragIndexService;
    if (ragIndex != null) {
      try {
        final result = await ragIndex.indexFoodEntryById(id, entry);
        indexed = indexed || result.isSuccess;
        if (status == 'not_configured') {
          status = result.isSuccess ? 'indexed_vector' : result.status.name;
        }
      } catch (_) {
        if (status == 'not_configured') status = 'vector_write_failed';
      }
    }

    return _FoodRagResult(
      indexed: indexed,
      status: status,
      transactionId: transactionId,
      verified: verified,
    );
  }

  String? _normalizeMealType(String? value) {
    final normalized = _trimOrNull(value)?.toLowerCase();
    if (normalized == null) return null;
    return MealType.all.contains(normalized) ? normalized : MealType.other;
  }

  String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _FoodRagResult {
  const _FoodRagResult({
    required this.indexed,
    required this.status,
    required this.transactionId,
    required this.verified,
  });

  final bool indexed;
  final String status;
  final String transactionId;
  final bool verified;
}
