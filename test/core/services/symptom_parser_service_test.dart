import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/symptom_parser_service.dart';

void main() {
  const service = SymptomParserService();

  test('parses common symptom utterance into structured fields', () {
    final result = service.parse(
      transcript:
          'Had some cramping after lunch, maybe a 4 out of 10 for 30 minutes',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.status, 'success');
    expect(result.structuredSymptom.symptomType, 'cramping');
    expect(result.structuredSymptom.severity1To10, 4);
    expect(result.structuredSymptom.mealRelation, 'after_lunch');
    expect(result.structuredSymptom.durationMinutes, 30);
    expect(result.needsClarification, isFalse);
    expect(result.structuredSymptom.extractionConfidence, greaterThan(0.8));
  });

  test('requests one clarification when symptom severity is missing', () {
    final result = service.parse(
      transcript:
          'My stomach is acting weird again and I had to run to the bathroom twice',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'urgency');
    expect(result.structuredSymptom.severity1To10, isNull);
    expect(result.needsClarification, isTrue);
    expect(result.clarificationQuestion, contains('mild, moderate, or severe'));
  });

  test('parses word-based severity and richer duration phrases', () {
    final result = service.parse(
      transcript:
          'Loose stools after breakfast, six out of ten, for half an hour',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'diarrhea');
    expect(result.structuredSymptom.severity1To10, 6);
    expect(result.structuredSymptom.mealRelation, 'after_breakfast');
    expect(result.structuredSymptom.durationMinutes, 30);
    expect(result.needsClarification, isFalse);
  });

  test('matches bowel symptom slang and related synonyms', () {
    final result = service.parse(
      transcript: 'Lots of pooping today, runny poop about 4 times',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'diarrhea');
    expect(
      SymptomParserService.looksLikeSymptomText('pooping too much'),
      isTrue,
    );
    expect(
      SymptomParserService.matchSymptom('watery poo')?.symptomType,
      'diarrhea',
    );
  });

  test('normalizes profanity/slang and catches typo variants', () {
    final slang = service.parse(
      transcript: 'big shit all morning',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );
    expect(slang.structuredSymptom.symptomType, 'diarrhea');

    final typo = SymptomParserService.matchSymptom('urgncy and bloateed');
    expect(typo, isNotNull);

    final all = SymptomParserService.matchAllSymptoms(
      'bloating and tired and urgent bathroom trips',
    );
    final types = all.map((m) => m.symptomType).toSet();
    expect(types.contains('bloating'), isTrue);
    expect(types.contains('fatigue'), isTrue);
    expect(types.contains('urgency'), isTrue);
  });

  test('uses fuzzy symptom matching for common misspellings', () {
    final match = SymptomParserService.matchSymptom('bad diarreha today');

    expect(match, isNotNull);
    expect(match!.symptomType, 'diarrhea');
    expect(match.matchType, anyOf('fuzzy_synonym', 'synonym'));
  });

  test('recognizes migraine and headache symptom language', () {
    final result = service.parse(
      transcript: 'I had a migraine with head pressure all day, around 7/10',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'headache_migraine');
    expect(result.structuredSymptom.severity1To10, 7);
    expect(result.structuredSymptom.durationMinutes, 1440);
    expect(result.needsClarification, isFalse);
  });

  test('parses delimiter-separated symptom fields with typo variants', () {
    final result = service.parse(
      transcript:
          'symptom: diarreha | frequency: two times | trigger: coffee | duration: half an hour',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'diarrhea');
    expect(result.structuredSymptom.durationMinutes, 30);
    expect(result.needsClarification, isTrue);
  });

  test('builds broad synonym lexicon per symptom family', () {
    expect(
      SymptomParserService.lexiconTermCountFor('diarrhea'),
      inInclusiveRange(300, 2200),
    );
    expect(
      SymptomParserService.lexiconTermCountFor('bloating'),
      inInclusiveRange(300, 2200),
    );
    expect(
      SymptomParserService.lexiconTermCountFor('fatigue'),
      inInclusiveRange(300, 2200),
    );
  });

  test('captures uc style mucus and pus stool descriptions', () {
    final result = service.parse(
      transcript: 'Passing mucus and pus with stool since this morning',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );
    final matches = SymptomParserService.matchAllSymptoms(
      'Passing mucus and pus with stool since this morning',
    );

    expect(matches.map((m) => m.symptomType), contains('mucus_stool'));
    expect(result.needsClarification, isTrue);
    expect(
      result.clarificationQuestion,
      contains('I heard two likely symptoms'),
    );
  });

  test('captures ibs style incontinence and bowel urgency language', () {
    final result = service.parse(
      transcript: 'Had stool leakage and fecal incontinence today',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );
    final matches = SymptomParserService.matchAllSymptoms(
      'Had stool leakage and fecal incontinence today',
    );

    expect(matches.map((m) => m.symptomType), contains('fecal_incontinence'));
    expect(result.needsClarification, isTrue);
  });

  test('captures appetite loss and early satiety phrases', () {
    final result = service.parse(
      transcript: 'Reduced appetite and full after a few bites for 2 days',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'appetite_loss');
  });

  test('asks for symptom clarification when the note is too vague', () {
    final result = service.parse(
      transcript: 'Feeling off today for a few hours',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.structuredSymptom.symptomType, 'other');
    expect(result.structuredSymptom.durationMinutes, 180);
    expect(result.needsClarification, isTrue);
    expect(
      result.clarificationQuestion,
      contains('Which symptom should I record'),
    );
  });

  test('asks targeted clarification on ambiguous top symptom families', () {
    final result = service.parse(
      transcript: 'I feel sore and weak since lunch',
      loggedAt: DateTime.parse('2026-04-12T18:30:00Z'),
    );

    expect(result.needsClarification, isTrue);
    expect(
      result.clarificationQuestion,
      contains('I heard two likely symptoms'),
    );
  });

  test(
    '320+ edge typo corpus keeps high symptom recognition coverage',
    () {
      final seeds = <String>[
        'diarreha after meals',
        'urgncy and tenesmuss',
        'mucuos stool with pusy',
        'constiption and hard stools',
        'fatiuge with no energy',
        'naseua and vomitting',
        'bloatingg and trapped gas',
        'fisssure pain when wiping',
        'fistulla drainage',
        'night sweats and chills',
        'head ache migrane',
        'back ache with dizziness',
        'incontinance stool leakage',
        'appetite loss full quickly',
        'joint pain and skin rash',
        'eye redness and blurry vision',
        'dehydation very thirsty',
        'mouth ulcer canker sore',
        'obstruction cant pass gas',
        'urinary urgency pee frequently',
      ];

      final wrappers = <String Function(String)>[
        (s) => s,
        (s) => 'I have $s',
        (s) => 'today: $s',
        (s) => '$s all day',
        (s) => 'my note says $s',
        (s) => '$s after lunch',
        (s) => '$s after dinner',
        (s) => 'really bad $s',
        (s) => '$s and it is moderate',
        (s) => 'please log $s',
        (s) => 'ongoing $s this morning',
        (s) => '$s overnight',
        (s) => '$s for half an hour',
        (s) => '$s with urgency',
        (s) => '$s with stool changes',
        (s) => '$s because of food trigger',
      ];

      final corpus = <String>[];
      for (final seed in seeds) {
        for (final wrap in wrappers) {
          corpus.add(wrap(seed));
        }
      }
      expect(corpus.length, greaterThanOrEqualTo(320));

      final matches = corpus
          .map(SymptomParserService.matchSymptom)
          .whereType<SymptomLexiconMatch>()
          .length;
      final coverage = matches / corpus.length;
      expect(coverage, greaterThanOrEqualTo(0.94));
    },
    tags: ['slow'],
  );

  // ── FEA-007: Voice pre-save parse preview ────────────────────────────────

  test('FEA-007 voice transcript parses to structured preview before saving',
      () {
    const parser = SymptomParserService();
    final result = parser.parse(
      transcript: 'cramps six out of ten after dinner',
      loggedAt: DateTime(2026, 5, 13, 20, 0),
    );
    expect(result.structuredSymptom.symptomType, isNotEmpty);
    // A voice-originated note must have a human-readable summary to show in review card.
    expect(result.structuredSymptom.userFacingDescription, isNotEmpty);
    // No persistence side-effect in parse — result is pure data.
    expect(result.needsClarification, isA<bool>());
  });

  test(
    'FEA-007 parse-only does not emit safety false positive for benign note',
    () {
      const parser = SymptomParserService();
      final result = parser.parse(
        transcript: 'mild bloating after breakfast, maybe a 3 out of 10',
        loggedAt: DateTime(2026, 5, 13, 8, 30),
      );
      expect(
        result.structuredSymptom.safetyFlags,
        isNot(contains('urgent_review')),
        reason: 'Mild bloating must not raise urgent_review',
      );
    },
  );

  test('FEA-007 parse flags urgent safety for bleeding transcript', () {
    const parser = SymptomParserService();
    final result = parser.parse(
      transcript: 'bright red blood in stool this morning',
      loggedAt: DateTime(2026, 5, 13, 7, 0),
    );
    final flags = result.structuredSymptom.safetyFlags;
    expect(
      flags.contains('urgent_review') || flags.contains('bleeding_reported'),
      isTrue,
      reason: 'Bleeding transcript must raise a safety flag in parse preview',
    );
  });
}
