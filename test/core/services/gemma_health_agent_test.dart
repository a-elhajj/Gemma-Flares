// FEA-020: Gemma health agent — grounded framing contract
//
// These tests exercise the Dart-side contract for the health-agent system
// prompt. They do NOT call the LLM — they verify that buildSystemPrompt
// emits the correct framing text given different inputs, and that the
// safety hard-rules are present when disease context is available.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/prompt_templates.dart';

void main() {
  group('FEA-020: health_agent_grounded_v1 prompt contract', () {
    test(
        'TS-01: general_health_question with diseaseType uses '
        'kFramingHealthAgentGrounded', () {
      final prompt = buildSystemPrompt(
        'general_health_question',
        diseaseType: 'CD',
        dataRichness: 'rich',
      );
      expect(prompt, contains('HARD RULES'));
      expect(prompt, contains('disease_type'));
    });

    test('TS-02: prompt contains explicit no-diagnosis guard', () {
      final prompt = buildSystemPrompt(
        'general_health_question',
        diseaseType: 'UC',
      );
      expect(prompt, contains('NEVER diagnose'));
    });

    test('TS-03: prompt contains explicit no-medication-change guard', () {
      final prompt = buildSystemPrompt(
        'general_health_question',
        diseaseType: 'IBS',
      );
      expect(prompt, contains('NEVER suggest starting, stopping, or changing'));
    });

    test(
      'TS-04: prompt instructs Gemma to acknowledge missing grounding data',
      () {
        final prompt = buildSystemPrompt(
          'general_health_question',
          diseaseType: 'CD',
        );
        expect(prompt, contains('missing'));
      },
    );

    test(
        'TS-05: general_health_question WITHOUT diseaseType uses generic '
        'kFramingGeneralHealth (no HARD RULES)', () {
      // When there is no profile / disease context, fall back gracefully.
      final prompt = buildSystemPrompt(
        'general_health_question',
        dataRichness: 'none',
      );
      // Generic framing should still contain grounding instruction.
      expect(prompt, contains('grounded context'));
      // But should NOT have the strict HARD RULES block.
      expect(prompt, isNot(contains('HARD RULES')));
    });

    test('TS-06: IBS patient gets IBS glossary, not CD glossary', () {
      final prompt = buildSystemPrompt(
        'risk_question',
        diseaseType: 'IBS',
        dataRichness: 'rich',
      );
      expect(prompt, contains('IBS-SSS'));
      expect(prompt, isNot(contains('Fecal calprotectin')));
    });

    test('TS-07: CD patient gets CD glossary', () {
      final prompt = buildSystemPrompt(
        'risk_question',
        diseaseType: 'CD',
        dataRichness: 'rich',
      );
      expect(prompt, contains('Fecal calprotectin'));
      expect(prompt, isNot(contains('IBS-SSS')));
    });

    test('TS-08: prompt does not leak HARD RULES into non-health intents', () {
      final prompt = buildSystemPrompt('greeting', diseaseType: 'CD');
      expect(prompt, isNot(contains('HARD RULES')));
    });

    test(
      'TS-09: health agent framing instructs care-team referral for out-of-scope',
      () {
        final prompt = buildSystemPrompt(
          'general_health_question',
          diseaseType: 'UC',
        );
        expect(prompt, contains('care team'));
      },
    );

    test(
        'TS-10: kFramingHealthAgentGrounded constant is non-empty and '
        'does not contain patient-unsafe identifiers', () {
      expect(kFramingHealthAgentGrounded, isNotEmpty);
      expect(kFramingHealthAgentGrounded, isNot(contains('EXC_BAD_ACCESS')));
      expect(kFramingHealthAgentGrounded, isNot(contains('pthread')));
      expect(kFramingHealthAgentGrounded, isNot(contains('jetsam')));
    });
  });
}
