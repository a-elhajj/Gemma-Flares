// =============================================================================
// PENDING REPLY CLASSIFIER SERVICE
// =============================================================================
// Classifies a user's free-text reply to a pending review card (symptom or
// lab) as one of: confirmation, edit-request, or unknown.
//
// Design: semantic token analysis on normalized text, not phrase enumeration.
//
//   1. TextNormalizationService.normalizeForIntent() collapses 300+ typos,
//      abbreviations, and informal shortcuts into canonical tokens before any
//      logic runs.  "u" → "you", "thx" → "thanks", "savve" → "save", etc.
//      This alone handles thousands of surface variants without extra code.
//
//   2. Confirmation: hard-negation guard (first-token check) → affirmative
//      token vocabulary → optionally combined with action verbs.  Short
//      messages (≤4 tokens) only need an affirmative; longer ones need both
//      an affirmative AND a storage/action verb to avoid over-triggering on
//      conversational "yeah" in mid-topic chatter.
//
//   3. Edit: small closed vocabulary; this intent is unambiguous.
//
//   4. Cancel: delegated back to home_screen's existing _isCancelPendingReply
//      — that method is already comprehensive and is not replaced here.
//
//   5. Follow-up questions (e.g. "did u log it?") fall through to
//      LocalAgentService.ask() so Gemma 4 can answer with full session
//      context (recent symptoms + last conversation turns).
// =============================================================================

import 'text_normalization_service.dart';

/// Result of classifying a reply to a pending review card.
enum PendingReplyKind {
  /// User wants to save / proceed.
  confirm,

  /// User wants to edit the draft before saving.
  edit,

  /// Unable to classify as any of the above.
  unknown,
}

/// Semantic classifier for replies to pending review cards.
///
/// All public methods accept the raw, unprocessed user input.
/// Normalization is applied internally.
class PendingReplyClassifierService {
  const PendingReplyClassifierService._();

  // ── Affirmative vocabulary (canonical forms post-normalization) ────────────
  //
  // Covers: core yes-words, informal/colloquial affirmatives, agreement words,
  // action-directives, hesitant-but-positive words.  The TextNormalizationService
  // pipeline maps many informal forms to these canonical tokens automatically
  // (e.g. "u" → "you", so "yes u got it" normalises to "yes you got it").
  static const _affirmativeTokens = {
    // Core yes-words
    'yes', 'yeah', 'yep', 'yup', 'ya', 'yah', 'yea', 'aye',
    // Slang / typed variants that normalization may not catch
    'yass', 'yasss', 'yesss', 'yeahh', 'yeahhhh', 'yess',
    'okey', 'okk', 'okayy', 'yaeh', 'yas', 'yeh', 'yh',
    // Informal agreement
    'sure', 'sure thing', 'of course', 'for sure', 'totally', 'absolutely',
    'definitely', 'certainly', 'indeed', 'obviously', 'naturally',
    'affirmative', 'roger', 'copy', 'aye aye',
    // Neutral-positive confirmation words
    'ok', 'okay', 'alright', 'fine', 'correct', 'right', 'exactly',
    'precisely', 'agreed', 'agree', 'true', 'accurate',
    // Positive evaluations (implies agreement)
    'good', 'great', 'perfect', 'nice', 'wonderful', 'excellent',
    'awesome', 'fantastic', 'looks good', 'sounds good', 'seems right',
    'that looks right', 'that looks correct', 'that is correct',
    // Action-directives (user telling app to act)
    'go', 'proceed', 'continue', 'submit', 'approve', 'accept',
    'confirmed', 'confirm', 'done',
    // Storage-action words that by themselves imply confirmation
    'save', 'log', 'record', 'store', 'add', 'enter', 'register',
  };

  // ── Hard-negation first-tokens ─────────────────────────────────────────────
  // If the normalized message STARTS with one of these tokens, treat as
  // non-confirmation regardless of what follows.
  static const _hardNegationOpeners = {
    'no',
    'nope',
    'nah',
    'never',
    'cancel',
    'stop',
    'dont',
    'do not',
    'discard',
    'wait',
    'hold',
    'actually',
    'hmm',
    'ugh',
    'erm',
    'err',
  };

  // ── Negation phrases — override affirmatives if present anywhere ───────────
  static const _negationPhrases = {
    'do not save',
    'do not log',
    'do not record',
    'dont save',
    'dont log',
    'dont record',
    'not yet',
    'not now',
    'not that',
    'not this',
    'not sure',
    'on second thought',
    'actually no',
    'wait no',
    'no wait',
    'never mind',
    'nevermind',
  };

  // ── Storage verb vocabulary ────────────────────────────────────────────────
  static const _storageVerbs = {
    'save',
    'saved',
    'log',
    'logged',
    'logging',
    'record',
    'recorded',
    'recording',
    'store',
    'stored',
    'storing',
    'capture',
    'captured',
    'track',
    'tracked',
    'tracking',
    'note',
    'noted',
    'add',
    'added',
    'enter',
    'entered',
    'register',
    'registered',
    'submit',
    'submitted',
    'upload',
    'uploaded',
    'write',
    'written',
    'document',
    'documented',
  };

  // ── Edit vocabulary ────────────────────────────────────────────────────────
  static const _editTokens = {
    'edit',
    'change',
    'fix',
    'update',
    'modify',
    'alter',
    'revise',
    'redo',
    'rewrite',
    'retype',
    'rephrase',
    'reword',
  };

  static const _editPhrases = {
    'change it',
    'fix it',
    'edit it',
    'update it',
    'change that',
    'fix that',
    'let me edit',
    'let me change',
    'let me fix',
    'i want to edit',
    'i want to change',
    'i need to fix',
    'edit this',
    'fix this',
    'change this',
    'update this',
  };

  // ── Classification thresholds ─────────────────────────────────────────────

  /// Short-message threshold: messages with this many tokens or fewer are
  /// treated as confirmations if they contain any affirmative token, even
  /// without an explicit storage verb.  Covers "yes", "ok thx", "confirm pls".
  /// Value of 4 was chosen empirically: most genuine one-word and short-phrase
  /// confirmations ("yes please", "sure thing", "ok do it") are ≤ 4 tokens,
  /// while longer messages risk being conversational agreement ("yeah I think
  /// that makes sense for now") rather than an explicit save intent.
  static const _shortMessageThreshold = 4;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns [PendingReplyKind.confirm] when the message semantically means
  /// "yes, save/proceed", [PendingReplyKind.edit] when the user wants to
  /// modify the draft, and [PendingReplyKind.unknown] otherwise.
  ///
  /// Follow-up questions ("did u log it?", "was that saved?") are NOT handled
  /// here — they fall through to LocalAgentService.ask() so Gemma 4 answers
  /// with full session context (recent symptoms + conversation turns).
  ///
  /// This does NOT handle cancel — use the existing _isCancelPendingReply in
  /// home_screen.dart which is already comprehensive.
  static PendingReplyKind classify(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return PendingReplyKind.unknown;

    // Guard: question-shaped input is never a confirmation/edit.
    // "did you save it?" is a question, not a reply to save the draft.
    if (trimmed.endsWith('?')) return PendingReplyKind.unknown;

    // Normalize via the shared pipeline (handles 300+ typos/slang/shortcuts).
    final normalized = TextNormalizationService.normalizeForIntent(trimmed);
    if (normalized.isEmpty) return PendingReplyKind.unknown;

    // Guard: "start a new flow" commands should NOT confirm a pending draft.
    // Example: while a review card is pending, the user might type "log a symptom"
    // intending to start over. Treat those as unknown so they route through the
    // normal intent router instead of saving the draft.
    if (_looksLikeNewDraftCommand(normalized)) {
      return PendingReplyKind.unknown;
    }

    final tokens = normalized.split(' ');
    final tokenSet = tokens.toSet();

    // Phrase-level affirmative: "do it" is a direct command.
    if (normalized == 'do it' ||
        normalized.startsWith('do it ') ||
        normalized.endsWith(' do it')) {
      return PendingReplyKind.confirm;
    }

    // Check edit first — it's unambiguous and shouldn't be confused with confirm.
    if (_isEditIntent(normalized, tokenSet)) return PendingReplyKind.edit;

    // Confirmation.
    if (_isConfirmIntent(normalized, tokenSet, tokens)) {
      return PendingReplyKind.confirm;
    }

    return PendingReplyKind.unknown;
  }

  static bool _looksLikeNewDraftCommand(String normalized) {
    const exact = {
      // Symptom logging starts
      'log a symptom',
      'log symptom',
      'log symptoms',
      'record a symptom',
      'record symptom',
      'save a symptom',
      'save symptom',
      'i want to log a symptom',
      'i have a symptom to log',
      'i have symptoms to log',
      // Lab scan starts
      'scan a lab photo',
      'scan lab photo',
      'scan a photo',
      'scan photo',
      'scan a lab',
      'scan lab',
    };
    if (exact.contains(normalized)) return true;
    if (normalized.startsWith('scan a lab photo ')) return true;
    if (normalized.startsWith('scan lab photo ')) return true;
    return false;
  }

  /// Convenience wrapper — returns true when the reply means "yes, save it".
  static bool isConfirmation(String rawInput) =>
      classify(rawInput) == PendingReplyKind.confirm;

  /// Convenience wrapper — returns true when the user wants to edit the draft.
  static bool isEditRequest(String rawInput) =>
      classify(rawInput) == PendingReplyKind.edit;

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static bool _isEditIntent(String normalized, Set<String> tokenSet) {
    if (_editPhrases.any(normalized.contains)) return true;
    // Single edit token (e.g. just "edit", "fix") with no strong affirmative.
    if (tokenSet.length <= 3 && tokenSet.any(_editTokens.contains)) return true;
    return false;
  }

  static bool _isConfirmIntent(
    String normalized,
    Set<String> tokenSet,
    List<String> tokens,
  ) {
    // Guard 1: Hard-negation opener overrides everything.
    if (_hardNegationOpeners.contains(tokens.first)) {
      return false;
    }

    // Guard 2: Negation phrase anywhere in the message overrides affirmatives.
    if (_negationPhrases.any(normalized.contains)) return false;

    // Guard 3: "not" token combined with a storage verb = negation
    // (e.g. "not logged", "not saved yet", "yes not saved").
    // Applied regardless of affirmatives so "yes not saved" is caught.
    if (tokenSet.contains('not') && tokenSet.any(_storageVerbs.contains)) {
      return false;
    }

    // Check for affirmative signal.
    final hasAffirmative = tokenSet.any(_affirmativeTokens.contains);
    if (!hasAffirmative) return false;

    // Short messages (≤ _shortMessageThreshold tokens): affirmative alone is
    // sufficient.  Covers "yes", "yeah go", "sure!", "ok thx", "confirm pls".
    if (tokens.length <= _shortMessageThreshold) return true;

    // Longer messages: require an additional storage/action verb to reduce
    // false positives on conversational "yeah I understand" type continuations.
    final hasStorageOrAction = tokenSet.any(_storageVerbs.contains) ||
        tokenSet.contains('proceed') ||
        tokenSet.contains('go') ||
        tokenSet.contains('continue') ||
        tokenSet.contains('please') ||
        tokenSet.contains('submit') ||
        tokenSet.contains('approve') ||
        tokenSet.contains('accept');

    return hasStorageOrAction;
  }
}
