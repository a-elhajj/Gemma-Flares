// Tests for PendingReplyClassifierService.
//
// Covers: confirmation, edit, and negative cases across
// 100+ representative phrasings including informal/slang, typos, voice-
// transcription noise, edge cases, and false-positive guards.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/pending_reply_classifier_service.dart';

void main() {
  // ── isConfirmation ─────────────────────────────────────────────────────────

  group('isConfirmation — standard affirmatives', () {
    const confirmCases = [
      'yes',
      'yeah',
      'yep',
      'yup',
      'ya',
      'yah',
      'yea',
      'sure',
      'ok',
      'okay',
      'confirm',
      'confirmed',
      'correct',
      'right',
      'alright',
      'fine',
      'agreed',
      'absolutely',
      'definitely',
      'indeed',
      'certainly',
      'totally',
      'go',
      'go ahead',
      'do it',
      'save',
      'save it',
      'save that',
      'log it',
      'log that',
      'record it',
      'proceed',
      'submit',
      'approve',
    ];
    for (final phrase in confirmCases) {
      test('"$phrase"', () {
        expect(
          PendingReplyClassifierService.isConfirmation(phrase),
          isTrue,
          reason: '"$phrase" should be a confirmation',
        );
      });
    }
  });

  group('isConfirmation — casual suffixes (the original failing cases)', () {
    const cases = [
      'confirm thx',
      'confirm thanks',
      'confirm please',
      'confirm and thanks',
      'yes thx',
      'yes thanks',
      'yes please',
      'yes please save it',
      'yeah go ahead',
      'yeah sure',
      'yep thx',
      'ok thanks',
      'okay sounds good',
      'sure thing',
      'sure go ahead',
      'absolutely go ahead',
    ];
    for (final phrase in cases) {
      test('"$phrase"', () {
        expect(
          PendingReplyClassifierService.isConfirmation(phrase),
          isTrue,
          reason: '"$phrase" should be a confirmation',
        );
      });
    }
  });

  group(
    'isConfirmation — typos and abbreviations (via TextNormalizationService)',
    () {
      const cases = [
        // TextNormalizationService maps 'u' → 'you', 'thx' → 'thanks', etc.
        // but these should still trigger confirmation via affirmative tokens
        'yess',
        'yeahh',
        'okey',
        'okk',
        'ya',
        'yaeh',
        'yas',
        'yass',
      ];
      for (final phrase in cases) {
        test('"$phrase"', () {
          expect(
            PendingReplyClassifierService.isConfirmation(phrase),
            isTrue,
            reason: '"$phrase" should be a confirmation',
          );
        });
      }
    },
  );

  group('isConfirmation — longer affirmative phrases', () {
    const cases = [
      'yes please go ahead and save it',
      'yeah sure go ahead and log that',
      'absolutely please save my entry',
      'yes that looks good please save',
      'ok yes please submit it',
      'sure i approve go ahead',
      'yes confirm and save it please',
      'yeah save that for me',
      'definitely log that please',
      'yes please proceed and save it',
    ];
    for (final phrase in cases) {
      test('"$phrase"', () {
        expect(
          PendingReplyClassifierService.isConfirmation(phrase),
          isTrue,
          reason: '"$phrase" should be a confirmation',
        );
      });
    }
  });

  group('isConfirmation — should NOT match (negation cases)', () {
    const notConfirmCases = [
      'no',
      'nope',
      'nah',
      'never',
      'cancel',
      'discard',
      'stop',
      'no thanks',
      'not yet',
      'not now',
      'wait no',
      'actually no',
      'on second thought no',
      'do not save',
      "don't save",
      'dont log it',
      'do not log',
      'never mind',
      'nevermind',
      'no wait',
      'hold on',
      'yes not saved',
      'yeah not logged',
    ];
    for (final phrase in notConfirmCases) {
      test('"$phrase"', () {
        expect(
          PendingReplyClassifierService.isConfirmation(phrase),
          isFalse,
          reason: '"$phrase" must NOT be treated as a confirmation',
        );
      });
    }
  });

  group('isConfirmation — edge: empty / whitespace', () {
    test('empty string', () {
      expect(PendingReplyClassifierService.isConfirmation(''), isFalse);
    });
    test('whitespace only', () {
      expect(PendingReplyClassifierService.isConfirmation('   '), isFalse);
    });
  });

  // ── isEditRequest ──────────────────────────────────────────────────────────

  group('isEditRequest', () {
    const editCases = [
      'edit',
      'fix it',
      'change it',
      'edit it',
      'update it',
      'modify it',
      'let me edit',
      'let me change',
      'i want to edit',
      'i need to fix',
    ];
    for (final phrase in editCases) {
      test('"$phrase"', () {
        expect(
          PendingReplyClassifierService.isEditRequest(phrase),
          isTrue,
          reason: '"$phrase" should be an edit request',
        );
      });
    }
  });

  // ── classify — priority ordering ──────────────────────────────────────────

  group('classify — edit takes priority over confirm', () {
    test('"edit it" → edit, not confirm', () {
      expect(
        PendingReplyClassifierService.classify('edit it'),
        PendingReplyKind.edit,
      );
    });
  });

  group('classify — unknown for unrelated messages', () {
    const unknownCases = [
      'how is my risk?',
      'show me my symptoms',
      'what does that mean',
      'tell me about crohn',
      // Top-level commands should not be treated as "confirm draft"
      'log a symptom',
      'log symptoms',
      'record a symptom',
      'scan a lab photo',
      // Follow-up questions fall through to Gemma — not classified here.
      'did you save it?',
      'was that logged?',
      '',
    ];
    for (final phrase in unknownCases) {
      test('"$phrase" → unknown', () {
        expect(
          PendingReplyClassifierService.classify(phrase),
          PendingReplyKind.unknown,
          reason: '"$phrase" should not classify as confirm/edit',
        );
      });
    }
  });
}
