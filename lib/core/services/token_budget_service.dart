import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Queries the native tokenizer via method channel to count tokens for a string.
/// Used by MemoryAssemblerService to enforce the 4K context budget.
class TokenBudgetService {
  static const _channel = MethodChannel('com.gutguard/litert_lm');

  // Fallback: rough approximation of 4 chars ≈ 1 token when native unavailable.
  // Medical text (numbers, special chars, abbreviations) tends to tokenize at
  // closer to 2.5–3 chars/token; this conservative ratio avoids silently
  // underestimating token counts when the native tokenizer is unavailable.
  static const _charsPerToken = 3.5;

  // Tracks whether the native tokenizer is available so we emit at most
  // one fallback warning per service instance (avoids log spam).
  bool _nativeMissing = false;

  /// Tokenizes [text] and returns the token count.
  Future<int> countTokens(String text) async {
    if (text.isEmpty) return 0;
    try {
      final result = await _channel.invokeMethod<int>(
        'litert_lm_count_tokens',
        {'text': text},
      );
      return result ?? _fallbackCount(text);
    } on MissingPluginException {
      _warnNativeFallback();
      return _fallbackCount(text);
    } on PlatformException catch (e) {
      _warnNativeFallback(
        suffix: 'Native tokenizer failed with ${e.code}.',
      );
      return _fallbackCount(text);
    }
  }

  void _warnNativeFallback({String? suffix}) {
    if (!_nativeMissing) {
      _nativeMissing = true;
      // Surface once so it is visible in test output and debug logs.
      // In production the native runtime method channel must be present; if this
      // fires on a real device the context budget may be silently overestimated.
      debugPrint(
        '[TokenBudgetService] WARNING: native tokenizer unavailable. '
        'Falling back to char-count approximation. '
        'Token budget enforcement may be conservative.'
        '${suffix == null ? '' : ' $suffix'}',
      );
    }
  }

  static int _fallbackCount(String text) =>
      (text.length / _charsPerToken).ceil();
}
