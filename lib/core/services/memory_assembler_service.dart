// =============================================================================
// GEMMA 4 HACKATHON — 4-Tier RAG Memory & Context Assembler
// =============================================================================
// [MemoryAssemblerService] builds the grounded context block passed to every
// Gemma 4 E2B inference call. It enforces the token budget so the 128K
// context window is never wasted on stale or irrelevant data.
//
// Four memory tiers (retrieval order, highest to lowest priority):
//   Tier 1 — Pinned Fact Card: user-confirmed medical facts (diagnoses, meds,
//             allergies). Always included. Source: PinnedFactService.
//   Tier 2 — Hierarchical Summaries: daily → weekly → monthly → quarterly
//             summaries. Pre-compressed at each rollup; no re-summarization
//             at inference time. Source: HierarchicalSummaryService.
//   Tier 3 — Production RAG Query: durable vector-store retrieval over recent
//             symptom notes, check-ins, labs, procedures, and health sync rows.
//             Source: RagQueryService (EmbeddingService + VectorStore).
//   Tier 4 — Message Ledger: last N confirmed conversation turns.
//             Source: rag_memory_service / conversation_repository.
//
// Token budget enforcement: TokenBudgetService packs tiers 1→4 in priority
// order, truncating at the per-intent token ceiling before returning.
// =============================================================================

import 'pinned_fact_service.dart';
import 'prompt_injection_guard_service.dart';
import 'rag_query_service.dart';
import 'rag_store.dart';
import 'token_budget_service.dart';

/// 6-step retrieval pipeline that assembles the grounded context block
/// passed to every Gemma inference call.
///
/// Steps:
/// 1. Embed the user query.
/// 2. ANN search across multiple collections.
/// 3. Time-decay rerank.
/// 4. MMR (Maximal Marginal Relevance) diversity filtering.
/// 5. Hard-include pinned facts + recent risk score.
/// 6. Token budget packing (target: ≤1800 tokens).
class MemoryAssemblerService {
  static const _maxTokenBudget = 1800;

  // Per-collection quota (approximate max results before budget packing).
  static const _collectionQuotas = <String, int>{
    'messages': 6,
    'symptoms': 4,
    'summaries': 3,
    'labs': 3,
    'procedures': 2,
    'checkins': 4,
    'knowledge': 3,
  };

  // Time-decay half-life in days.
  static const _halfLifeDays = 30.0;

  MemoryAssemblerService({
    required RagQueryService ragQueryService,
    required PinnedFactService pinnedFacts,
    required TokenBudgetService tokenBudget,
  })  : _ragQueryService = ragQueryService,
        _pinnedFacts = pinnedFacts,
        _tokenBudget = tokenBudget;

  final RagQueryService _ragQueryService;
  final PinnedFactService _pinnedFacts;
  final TokenBudgetService _tokenBudget;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Assembles grounded context for an inference call.
  ///
  /// Returns a map suitable for [LocalModelRequest.groundedContext].
  Future<Map<String, Object?>> assemble({
    required String userQuery,
    Map<String, Object?> hardIncludes = const {},
  }) async {
    final result = await _ragQueryService.query(
      userQuery,
      config: RagQueryConfig(
        topKPerCollection: 8,
        maxTotal: 24,
        decayHalfLifeDays: _halfLifeDays,
        mmrLambda: 0.7,
        collections: _collectionQuotas.keys.toList(growable: false),
      ),
    );
    final diverse = result.matches;

    // Step 5: Hard-include pinned facts.
    final pinnedFact = await _pinnedFacts.load();
    final pinnedText = pinnedFact != null
        ? 'PINNED_FACTS: ${_formatMap(pinnedFact.content)}'
        : '';

    // Step 6: Token budget packing.
    final chunks = <String>[];
    var usedTokens = 0;

    if (pinnedText.isNotEmpty) {
      usedTokens += await _tokenBudget.countTokens(pinnedText);
      chunks.add(pinnedText);
    }

    for (final match in diverse) {
      // Sanitize each retrieved chunk before injecting into the model context.
      // A crafted memory entry (e.g. via a lab OCR result stored earlier) could
      // otherwise carry injection instructions into the Gemma system prompt.
      final sanitizedText = PromptInjectionGuardService.sanitize(
        '[${match.collection}] ${match.text}',
      );
      final cost = await _tokenBudget.countTokens(sanitizedText);
      if (usedTokens + cost > _maxTokenBudget) break;
      usedTokens += cost;
      chunks.add(sanitizedText);
    }

    return {
      'retrievedChunks': chunks,
      'totalRetrievedTokens': usedTokens,
      'collectionCoverage': _coverageMap(diverse),
      'ragQueryProvider': 'RagQueryService',
      ...hardIncludes,
    };
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  String _formatMap(Map<String, Object?> map) {
    return map.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}: ${e.value}')
        .join('; ');
  }

  Map<String, int> _coverageMap(List<RagMatch> selected) {
    final counts = <String, int>{};
    for (final match in selected) {
      counts[match.collection] = (counts[match.collection] ?? 0) + 1;
    }
    return counts;
  }
}
