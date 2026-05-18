import 'diagnostic_log_service.dart';

class RedFlagResult {
  const RedFlagResult({
    required this.triggered,
    required this.category,
    required this.message,
    required this.matchedTerms,
    required this.urgency,
  });

  final bool triggered;
  final String category;
  final String message;
  final List<String> matchedTerms;
  final String urgency;

  static const none = RedFlagResult(
    triggered: false,
    category: 'none',
    message: '',
    matchedTerms: [],
    urgency: 'routine',
  );
}

class RedFlagClassifierService {
  RedFlagClassifierService({DiagnosticLogService? diagnosticLogService})
      : _diagnosticLogService = diagnosticLogService;

  final DiagnosticLogService? _diagnosticLogService;

  static const _rules = <_RedFlagRule>[
    _RedFlagRule(
      category: 'severe_bleeding',
      urgency: 'urgent',
      terms: [
        'a lot of blood',
        'heavy bleeding',
        'black stool',
        'black stools',
        'tarry stool',
        'blood clots',
      ],
      message:
          'That amount of bleeding may need urgent medical attention. Please contact your care team now, or seek urgent care if symptoms are severe.',
    ),
    _RedFlagRule(
      category: 'obstruction',
      urgency: 'urgent',
      terms: [
        'can\'t pass gas',
        'cannot pass gas',
        'no bowel movement',
        'severe bloating',
        'vomiting and pain',
        'blocked bowel',
        'obstruction',
      ],
      message:
          'Severe pain with vomiting, marked bloating, or inability to pass stool or gas can be urgent. Please seek medical care promptly.',
    ),
    _RedFlagRule(
      category: 'high_fever',
      urgency: 'urgent',
      terms: [
        'high fever',
        '103 fever',
        '104 fever',
        '39 c',
        '39c',
        '40 c',
        '40c',
      ],
      message:
          'A high fever with IBD symptoms may need urgent assessment. Please contact your clinician or seek urgent care.',
    ),
    _RedFlagRule(
      category: 'severe_pain',
      urgency: 'urgent',
      terms: [
        'severe abdominal pain',
        'worst pain',
        'unbearable pain',
        'pain 10',
        '10/10 pain',
      ],
      message:
          'Severe or worsening abdominal pain should be checked urgently, especially with fever, vomiting, or bleeding.',
    ),
    _RedFlagRule(
      category: 'dehydration',
      urgency: 'soon',
      terms: [
        'dizzy',
        'fainting',
        'can\'t keep fluids down',
        'cannot keep fluids down',
        'not peeing',
        'very dehydrated',
      ],
      message:
          'This could fit dehydration or illness that needs timely care. Please contact your care team, and seek urgent care if it worsens.',
    ),
  ];

  Future<RedFlagResult> classify(String text, {String source = 'chat'}) async {
    final lower = text.toLowerCase();

    // Collect ALL matching rules — a message can trigger multiple categories
    // (e.g. bleeding + severe pain). Return the highest-urgency match so that
    // a combined presentation is never silently downgraded to a lower category.
    final allMatches = <({_RedFlagRule rule, List<String> terms})>[];
    for (final rule in _rules) {
      final terms = rule.terms.where(lower.contains).toList(growable: false);
      if (terms.isNotEmpty) {
        allMatches.add((rule: rule, terms: terms));
      }
    }

    if (allMatches.isEmpty) return RedFlagResult.none;

    // Urgency order: 'urgent' > 'soon' > anything else.
    const urgencyRank = {'urgent': 2, 'soon': 1};
    allMatches.sort((a, b) {
      final ra = urgencyRank[a.rule.urgency] ?? 0;
      final rb = urgencyRank[b.rule.urgency] ?? 0;
      return rb.compareTo(ra); // highest urgency first
    });

    final top = allMatches.first;
    final result = RedFlagResult(
      triggered: true,
      category: top.rule.category,
      message: top.rule.message,
      matchedTerms: top.terms,
      urgency: top.rule.urgency,
    );

    await _diagnosticLogService?.warning(
      'red_flag_triggered',
      category: DiagnosticLogService.categoryChat,
      message: 'A deterministic red-flag safety rule fired.',
      metadata: {
        'source': source,
        'red_flag_category': result.category,
        'urgency': result.urgency,
        'match_count': top.terms.length,
        'total_matching_rules': allMatches.length,
      },
    );
    return result;
  }
}

class _RedFlagRule {
  const _RedFlagRule({
    required this.category,
    required this.urgency,
    required this.terms,
    required this.message,
  });

  final String category;
  final String urgency;
  final List<String> terms;
  final String message;
}
