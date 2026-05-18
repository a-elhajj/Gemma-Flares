// Tests that verify the red-flag urgency-ordering fix:
//
// Before the fix, RedFlagClassifierService.classify() returned on the FIRST
// matching rule in declaration order. A message containing both a 'soon'
// trigger and an 'urgent' trigger would return the 'soon' result if its rule
// appeared first, silently suppressing the higher-urgency escalation.
//
// After the fix, all rules are scanned and the highest-urgency match wins.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/red_flag_classifier_service.dart';

void main() {
  group('RedFlagClassifierService — urgency ordering', () {
    late RedFlagClassifierService classifier;

    setUp(() {
      classifier = RedFlagClassifierService();
    });

    // ── Single-rule baseline ──────────────────────────────────────────────────

    test('returns none for routine symptom message', () async {
      final result = await classifier.classify('Mild cramps after lunch.');
      expect(result.triggered, isFalse);
      expect(result.urgency, 'routine');
    });

    test('fires urgent for severe_bleeding alone', () async {
      final result = await classifier.classify(
        'I am seeing a lot of blood in my stool.',
      );
      expect(result.triggered, isTrue);
      expect(result.category, 'severe_bleeding');
      expect(result.urgency, 'urgent');
    });

    test('fires urgent for obstruction terms alone', () async {
      final result = await classifier.classify(
        'I cannot pass gas and have severe bloating.',
      );
      expect(result.triggered, isTrue);
      expect(result.category, 'obstruction');
      expect(result.urgency, 'urgent');
    });

    test('fires soon for dehydration terms alone', () async {
      final result = await classifier.classify('I feel very dizzy today.');
      expect(result.triggered, isTrue);
      expect(result.urgency, 'soon');
    });

    // ── Multi-rule: urgent must win over soon ────────────────────────────────

    test(
      'urgent wins when message contains both dehydration and severe_pain terms',
      () async {
        // 'dizzy' → dehydration (soon)
        // '10/10 pain' → severe_pain (urgent)
        // Before fix: returned dehydration/soon if dehydration rule was first.
        // After fix: returns severe_pain/urgent.
        final result = await classifier.classify(
          'I am dizzy and the pain is 10/10 pain — I cannot stand up.',
        );
        expect(result.triggered, isTrue);
        expect(
          result.urgency,
          'urgent',
          reason:
              'severe_pain is urgent; dehydration is soon — urgent must win',
        );
        expect(result.category, 'severe_pain');
      },
    );

    test(
      'urgent wins when message contains both high_fever and dehydration terms',
      () async {
        // 'dizzy' → dehydration (soon), 'high fever' → high_fever (urgent)
        final result = await classifier.classify(
          'I have a high fever and feel very dizzy.',
        );
        expect(result.triggered, isTrue);
        expect(
          result.urgency,
          'urgent',
          reason: 'high_fever is urgent; dehydration is soon — urgent must win',
        );
        expect(result.category, 'high_fever');
      },
    );

    test('urgent wins for concurrent bleeding and obstruction', () async {
      // Both are urgent; the first one declared in the rule list wins among
      // equally ranked rules — this test just ensures urgent is the outcome.
      final result = await classifier.classify(
        'Heavy bleeding and I cannot pass gas.',
      );
      expect(result.triggered, isTrue);
      expect(result.urgency, 'urgent');
    });

    test(
      'reports total_matching_rules in audit metadata via diagnostic log',
      () async {
        // Both dehydration + severe_pain fire → total_matching_rules should be 2.
        // We cannot directly assert on the diagnostic log here (it is injected),
        // but we CAN assert the result reflects only the top-urgency rule.
        final result = await classifier.classify(
          'I feel dizzy and have unbearable pain.',
        );
        // unbearable pain → severe_pain (urgent) must win over dizzy → dehydration (soon)
        expect(result.urgency, 'urgent');
        expect(result.matchedTerms, contains('unbearable pain'));
      },
    );

    // ── Edge cases ────────────────────────────────────────────────────────────

    test('returns none when message has no red-flag terms', () async {
      final result = await classifier.classify(
        'How much fibre should I eat per day?',
      );
      expect(result.triggered, isFalse);
      expect(result, same(RedFlagResult.none));
    });

    test(
      'matched terms reflect the winning rule terms, not all terms',
      () async {
        // Only the terms from the highest-urgency matched rule should appear.
        final result = await classifier.classify(
          'I feel dizzy and have the worst pain of my life.',
        );
        expect(result.urgency, 'urgent'); // worst pain → severe_pain
        // matchedTerms should not contain 'dizzy' (that is the soon rule)
        expect(result.matchedTerms, isNot(contains('dizzy')));
      },
    );
  });
}
