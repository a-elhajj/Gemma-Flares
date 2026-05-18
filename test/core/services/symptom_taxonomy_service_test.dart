import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/symptom_taxonomy_service.dart';

void main() {
  late SymptomTaxonomyService service;

  setUp(() {
    service = SymptomTaxonomyService(
      assetLoader: () =>
          File('assets/clinical/symptoms_v1.json').readAsString(),
    );
  });

  test('loads canonical symptom registry', () async {
    final entries = await service.loadEntries();

    expect(entries.length, greaterThan(80));
    expect(entries.any((entry) => entry.id == 'abdominal_pain'), isTrue);
  });

  test('matches exact canonical symptom id', () async {
    final match = await service.match('abdominal_pain');

    expect(match, isNotNull);
    expect(match!.entry.id, 'abdominal_pain');
    expect(match.matchType, 'exact');
    expect(match.confidence, 1);
  });

  test('matches synonym text', () async {
    final match = await service.match('I have gut cramps after lunch');

    expect(match, isNotNull);
    expect(match!.entry.id, 'abdominal_cramping');
    expect(match.matchType, 'synonym');
  });

  test('matches fuzzy spelling variants', () async {
    final match = await service.match('naussea');

    expect(match, isNotNull);
    expect(match!.entry.id, 'nausea');
    expect(match.matchType, 'string_similarity');
  });

  test('leaves unrelated symptoms unmatched', () async {
    final match = await service.match('my left shoelace is frayed');

    expect(match, isNull);
  });

  test('canonicalizeId returns original text when no match exists', () async {
    final id = await service.canonicalizeId('new unusual symptom');

    expect(id, 'new unusual symptom');
  });
}
