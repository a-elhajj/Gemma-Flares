import 'diagnostic_log_service.dart';

class PromptInjectionResult {
  const PromptInjectionResult({
    required this.sanitizedText,
    required this.blocked,
    required this.matches,
  });

  final String sanitizedText;
  final bool blocked;
  final List<String> matches;
}

class PromptInjectionGuardService {
  PromptInjectionGuardService({DiagnosticLogService? diagnosticLogService})
      : _diagnosticLogService = diagnosticLogService;

  final DiagnosticLogService? _diagnosticLogService;

  static final List<RegExp> _patterns = [
    RegExp(
      r'ignore\s+(all\s+)?(previous|prior|above)\s+instructions',
      caseSensitive: false,
    ),
    RegExp(r'(system|developer)\s+prompt', caseSensitive: false),
    RegExp(
      r'reveal\s+(your\s+)?(prompt|instructions|secrets)',
      caseSensitive: false,
    ),
    RegExp(r'you\s+are\s+now\s+(?!gemma_flares)', caseSensitive: false),
    RegExp(r'forget\s+(the\s+)?rules', caseSensitive: false),
    RegExp(
      r'exfiltrate|send\s+.*\s+to\s+server|upload\s+health\s+data',
      caseSensitive: false,
    ),
    RegExp(
      r'<\s*/?\s*(system|developer|assistant|tool)\s*>',
      caseSensitive: false,
    ),
  ];

  Future<PromptInjectionResult> inspect(
    String input, {
    String source = 'chat',
  }) async {
    final sanitized = sanitize(input);
    final matches = <String>[];
    for (final pattern in _patterns) {
      if (pattern.hasMatch(sanitized)) {
        matches.add(pattern.pattern);
      }
    }

    final result = PromptInjectionResult(
      sanitizedText: sanitized,
      blocked: matches.isNotEmpty,
      matches: matches,
    );

    if (result.blocked) {
      await _diagnosticLogService?.warning(
        'prompt_injection_detected',
        category: DiagnosticLogService.categoryChat,
        message: 'Potential prompt injection was blocked locally.',
        metadata: {
          'source': source,
          'match_count': matches.length,
          'input_chars': input.length,
        },
      );
    }

    return result;
  }

  /// Strips control characters and normalises whitespace.
  /// Exposed as a static so callers (e.g. MemoryAssemblerService) can sanitize
  /// RAG-retrieved chunks without taking a full service dependency.
  static String sanitize(String input) {
    final strippedControls = input.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      ' ',
    );
    return strippedControls.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
