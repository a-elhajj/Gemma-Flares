@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/symptom_parser_service.dart';

void main() {
  const service = SymptomParserService();
  final loggedAt = DateTime.parse('2026-04-12T18:30:00Z');

  group('symptom type detection', () {
    test('detects pain keyword', () {
      final r = service.parse(
        transcript: 'I have stomach pain',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'pain');
    });

    test('detects ache variant', () {
      final r = service.parse(
        transcript: 'My stomach ache is bad',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'pain');
    });

    test('detects cramping', () {
      final r = service.parse(
        transcript: 'Severe cramping since morning',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'cramping');
    });

    test('detects cramps variant', () {
      final r = service.parse(
        transcript: 'Having cramps again',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'cramping');
    });

    test('detects diarrhea', () {
      final r = service.parse(
        transcript: 'Diarrhea three times today',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'diarrhea');
    });

    test('detects loose stool variant', () {
      final r = service.parse(
        transcript: 'Had loose stools this morning',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'diarrhea');
    });

    test('detects urgency', () {
      final r = service.parse(
        transcript: 'Had to rush to the bathroom',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'urgency');
    });

    test('detects nausea', () {
      final r = service.parse(
        transcript: 'Feeling nauseous all day',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'nausea');
    });

    test('detects sick to my stomach', () {
      final r = service.parse(
        transcript: 'Felt sick to my stomach for hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'nausea');
    });

    test('detects bloating', () {
      final r = service.parse(
        transcript: 'Very bloated after eating',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'bloating');
    });

    test('detects fatigue', () {
      final r = service.parse(
        transcript: 'Extremely tired and exhausted',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'fatigue');
    });

    test('detects blood', () {
      final r = service.parse(
        transcript: 'Noticed blood in stool',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'blood');
    });

    test('returns other for unknown symptom', () {
      final r = service.parse(
        transcript: 'Something feels wrong today',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'other');
    });

    test('priority order: first keyword match wins', () {
      // pain comes before cramping in the _symptomKeywords map
      final r = service.parse(
        transcript: 'Pain with cramping',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'pain');
    });
  });

  group('severity extraction', () {
    test('extracts numeric X/10 scale', () {
      final r = service.parse(
        transcript: 'Pain about 7 out of 10',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 7);
    });

    test('extracts numeric X/10 with slash', () {
      final r = service.parse(transcript: 'Cramping 5/10', loggedAt: loggedAt);
      expect(r.structuredSymptom.severity1To10, 5);
    });

    test('extracts word-based "six out of ten"', () {
      final r = service.parse(
        transcript: 'Pain six out of ten',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 6);
    });

    test('extracts contextual numeric severity', () {
      final r = service.parse(
        transcript: 'Pain was 8 today',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 8);
    });

    test('maps mild keyword to 3', () {
      final r = service.parse(
        transcript: 'Having mild cramping',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 3);
    });

    test('maps moderate keyword to 6', () {
      final r = service.parse(
        transcript: 'Moderate stomach pain',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 6);
    });

    test('maps severe keyword to 8', () {
      final r = service.parse(
        transcript: 'Severe diarrhea this evening',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 8);
    });

    test('returns null when no severity info present', () {
      final r = service.parse(
        transcript: 'I had some pain',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, isNull);
    });

    test('extracts 10 out of 10', () {
      final r = service.parse(
        transcript: 'Pain 10 out of 10',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 10);
    });

    test('extracts ten out of ten', () {
      final r = service.parse(
        transcript: 'Pain ten out of ten',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 10);
    });

    test('extracts one out of ten', () {
      final r = service.parse(
        transcript: 'Pain one out of ten',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.severity1To10, 1);
    });
  });

  group('duration extraction', () {
    test('parses half an hour', () {
      final r = service.parse(
        transcript: 'Had pain for half an hour',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 30);
    });

    test('parses half hour variant', () {
      final r = service.parse(
        transcript: 'Bloating for about half hour',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 30);
    });

    test('parses an hour', () {
      final r = service.parse(
        transcript: 'Nausea lasted an hour',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 60);
    });

    test('parses couple of hours', () {
      final r = service.parse(
        transcript: 'Pain for a couple of hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 120);
    });

    test('parses couple hours', () {
      final r = service.parse(
        transcript: 'Cramping couple hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 120);
    });

    test('parses few hours', () {
      final r = service.parse(
        transcript: 'Felt sick for a few hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 180);
    });

    test('parses all day', () {
      final r = service.parse(
        transcript: 'Pain all day long',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 720);
    });

    test('parses numeric hours', () {
      final r = service.parse(
        transcript: 'Cramping for 3 hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 180);
    });

    test('parses numeric minutes', () {
      final r = service.parse(
        transcript: 'Pain lasted 45 minutes',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 45);
    });

    test('parses mixed hours and minutes', () {
      final r = service.parse(
        transcript: 'Cramping for 1 hour and 30 minutes',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 90);
    });

    test('parses 2 hrs and 15 min', () {
      final r = service.parse(
        transcript: 'Pain for 2 hrs and 15 min',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, 135);
    });

    test('returns null when no duration specified', () {
      final r = service.parse(
        transcript: 'Had some pain today',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.durationMinutes, isNull);
    });
  });

  group('meal relation detection', () {
    test('detects after lunch', () {
      final r = service.parse(
        transcript: 'Cramping after lunch',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'after_lunch');
    });

    test('detects before lunch', () {
      final r = service.parse(
        transcript: 'Pain started before lunch',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'before_lunch');
    });

    test('detects after dinner', () {
      final r = service.parse(
        transcript: 'Nausea hit after dinner',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'after_dinner');
    });

    test('detects before dinner', () {
      final r = service.parse(
        transcript: 'Pain before dinner tonight',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'before_dinner');
    });

    test('detects after breakfast', () {
      final r = service.parse(
        transcript: 'Bloated after breakfast',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'after_breakfast');
    });

    test('detects before breakfast', () {
      final r = service.parse(
        transcript: 'Pain before breakfast',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'before_breakfast');
    });

    test('detects after eating', () {
      final r = service.parse(
        transcript: 'Always worse after eating anything',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'after_meal');
    });

    test('detects after i ate', () {
      final r = service.parse(
        transcript: 'Started right after i ate',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'after_meal');
    });

    test('detects empty stomach', () {
      final r = service.parse(
        transcript: 'Worse on an empty stomach',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, 'before_meal');
    });

    test('returns null when no meal context', () {
      final r = service.parse(
        transcript: 'Had some pain today',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.mealRelation, isNull);
    });
  });

  group('clarification logic', () {
    test('asks for symptom type when other', () {
      final r = service.parse(transcript: 'Feeling weird', loggedAt: loggedAt);
      expect(r.needsClarification, isTrue);
      expect(
        r.clarificationQuestion,
        contains('Which symptom should I record'),
      );
    });

    test('asks for severity when missing', () {
      final r = service.parse(
        transcript: 'Some cramping today',
        loggedAt: loggedAt,
      );
      expect(r.needsClarification, isTrue);
      expect(r.clarificationQuestion, contains('mild, moderate, or severe'));
    });

    test('no clarification when both type and severity present', () {
      final r = service.parse(
        transcript: 'Mild cramping for 30 mins',
        loggedAt: loggedAt,
      );
      expect(r.needsClarification, isFalse);
      expect(r.clarificationQuestion, isNull);
    });

    test('clarification for other overrides severity question', () {
      // when symptomType is 'other', the question asks for type, not severity
      final r = service.parse(
        transcript: 'Feeling off, moderate',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'other');
      expect(
        r.clarificationQuestion,
        contains('Which symptom should I record'),
      );
    });
  });

  group('confidence calculation', () {
    test('base confidence for empty string', () {
      final r = service.parse(transcript: '', loggedAt: loggedAt);
      // base 0.35, symptomType == 'other' → -0.1 = 0.25
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.25, 0.01));
    });

    test('non-empty transcript adds 0.1', () {
      final r = service.parse(transcript: 'something', loggedAt: loggedAt);
      // 0.35 + 0.1(nonEmpty) - 0.1(other) = 0.35
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.35, 0.01));
    });

    test('known type adds 0.25', () {
      final r = service.parse(transcript: 'cramping', loggedAt: loggedAt);
      // 0.35 + 0.1(nonEmpty) + 0.25(type) = 0.70
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.70, 0.01));
    });

    test('severity adds 0.15', () {
      final r = service.parse(transcript: 'mild cramping', loggedAt: loggedAt);
      // 0.35 + 0.1 + 0.25 + 0.15 = 0.85
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.85, 0.01));
    });

    test('meal relation adds 0.10', () {
      final r = service.parse(
        transcript: 'mild cramping after lunch',
        loggedAt: loggedAt,
      );
      // 0.35 + 0.1 + 0.25 + 0.15 + 0.10 = 0.95
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.95, 0.01));
    });

    test('confidence caps at 0.95', () {
      final r = service.parse(
        transcript: 'Mild cramping after lunch for half an hour',
        loggedAt: loggedAt,
      );
      // 0.35 + 0.1 + 0.25 + 0.15 + 0.10 + 0.05 = 1.0, capped at 0.95
      expect(r.structuredSymptom.extractionConfidence, 0.95);
    });

    test('duration adds 0.05', () {
      final r = service.parse(
        transcript: 'cramping for half an hour',
        loggedAt: loggedAt,
      );
      // 0.35 + 0.1 + 0.25 + 0.05 = 0.75
      expect(r.structuredSymptom.extractionConfidence, closeTo(0.75, 0.01));
    });
  });

  group('full parse integration', () {
    test('comprehensive utterance: cramping after lunch 4/10 for 30 mins', () {
      final r = service.parse(
        transcript:
            'Had some cramping after lunch, maybe a 4 out of 10 for 30 minutes',
        loggedAt: loggedAt,
      );
      expect(r.status, 'success');
      expect(r.structuredSymptom.symptomType, 'cramping');
      expect(r.structuredSymptom.severity1To10, 4);
      expect(r.structuredSymptom.mealRelation, 'after_lunch');
      expect(r.structuredSymptom.durationMinutes, 30);
      expect(r.needsClarification, isFalse);
      expect(r.structuredSymptom.extractionConfidence, 0.95);
    });

    test('word-based severity with breakfast', () {
      final r = service.parse(
        transcript:
            'Loose stools after breakfast, six out of ten, for half an hour',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'diarrhea');
      expect(r.structuredSymptom.severity1To10, 6);
      expect(r.structuredSymptom.mealRelation, 'after_breakfast');
      expect(r.structuredSymptom.durationMinutes, 30);
    });

    test('vague note falls back to other with duration', () {
      final r = service.parse(
        transcript: 'Feeling off today for a few hours',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'other');
      expect(r.structuredSymptom.durationMinutes, 180);
      expect(r.needsClarification, isTrue);
    });

    test('logged time is converted to UTC', () {
      final local = DateTime.parse('2026-04-12T14:30:00-04:00');
      final r = service.parse(transcript: 'Cramping', loggedAt: local);
      expect(r.structuredSymptom.loggedTime.isUtc, isTrue);
    });

    test('whitespace normalization', () {
      final r = service.parse(
        transcript: '  cramps   after    lunch  ',
        loggedAt: loggedAt,
      );
      expect(r.structuredSymptom.symptomType, 'cramping');
      expect(r.structuredSymptom.notes, 'cramps after lunch');
    });
  });
}
