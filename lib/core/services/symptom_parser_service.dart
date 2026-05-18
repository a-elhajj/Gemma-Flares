class SymptomParseResult {
  const SymptomParseResult({
    required this.status,
    required this.structuredSymptom,
    required this.needsClarification,
    this.clarificationQuestion,
  });

  final String status;
  final StructuredSymptom structuredSymptom;
  final bool needsClarification;
  final String? clarificationQuestion;
}

class StructuredSymptom {
  const StructuredSymptom({
    required this.symptomType,
    required this.severity1To10,
    required this.onsetTime,
    required this.loggedTime,
    required this.durationMinutes,
    required this.mealRelation,
    required this.notes,
    required this.sourceTranscript,
    required this.extractionConfidence,
    required this.userFacingDescription,
    this.uncertaintyNotes = const [],
    this.safetyFlags = const [],
  });

  final String symptomType;
  final int? severity1To10;
  final DateTime? onsetTime;
  final DateTime loggedTime;
  final int? durationMinutes;
  final String? mealRelation;
  final String notes;
  final String sourceTranscript;
  final double extractionConfidence;
  final String userFacingDescription;
  final List<String> uncertaintyNotes;
  final List<String> safetyFlags;
}

class SymptomLexiconMatch {
  const SymptomLexiconMatch({
    required this.symptomType,
    required this.confidence,
    required this.matchedText,
    required this.matchType,
  });

  final String symptomType;
  final double confidence;
  final String matchedText;
  final String matchType;
}

class SymptomParserService {
  const SymptomParserService();

  static final Map<String, List<String>> _symptomKeywords = _buildLexicon();
  static const Map<String, String> _normalizationReplacements = {
    'shitting': 'pooping',
    'shitted': 'pooped',
    'shit': 'poop',
    'shits': 'poops',
    'shat': 'pooped',
    'poopies': 'poops',
    'stooling': 'pooping',
    'bm': 'bowel movement',
    'bms': 'bowel movements',
    'diahrrea': 'diarrhea',
    'diarreah': 'diarrhea',
    'diarhea': 'diarrhea',
    'diarreha': 'diarrhea',
    'urgncy': 'urgency',
    'urgancy': 'urgency',
    'bloateed': 'bloated',
    'bloatng': 'bloating',
    'becausw': 'because',
    'everyday': 'every day',
    'migrane': 'migraine',
    'migraines': 'migraine',
    'head ache': 'headache',
    'constipatedd': 'constipated',
    'constiption': 'constipation',
    'constaption': 'constipation',
    'tenesmuss': 'tenesmus',
    'urgnt': 'urgent',
    'fatiuge': 'fatigue',
    'fatgue': 'fatigue',
    'naseua': 'nausea',
    'nausia': 'nausea',
    'vomitting': 'vomiting',
    'vommiting': 'vomiting',
    'mucuos': 'mucus',
    'mucouss': 'mucus',
    'pusy': 'pus',
    'bloatingg': 'bloating',
    'crampng': 'cramping',
    'crampin': 'cramping',
    'dehydation': 'dehydration',
    'dizzyy': 'dizzy',
    'fisssure': 'fissure',
    'fistulla': 'fistula',
    'incontinance': 'incontinence',
    'incontinenece': 'incontinence',
    'back ache': 'backache',
    'belley': 'belly',
    'abdoman': 'abdomen',
    'abdo': 'abdomen',
    'bristoltype': 'bristol',
  };

  static const _seedSynonyms = <String, List<String>>{
    'pain': [
      'pain',
      'ache',
      'aching',
      'soreness',
      'sore',
      'tender',
      'tenderness',
      'sharp pain',
      'dull pain',
      'burning pain',
      'stabbing pain',
      'throbbing pain',
      'hurts',
      'hurting',
      'it hurts',
      'stomach pain',
      'abdominal pain',
      'belly pain',
      'tummy pain',
      'gut pain',
      'intestinal pain',
      'abdomen hurts',
      'belly ache',
      'stomach ache',
      'abdominal tenderness',
      'tender abdomen',
      'gut tenderness',
      'lower abdominal pain',
      'left lower belly pain',
      'right lower belly pain',
      'pelvic pain',
    ],
    'cramping': [
      'cramp',
      'cramping',
      'cramps',
      'spasm',
      'spasms',
      'gripping',
      'tight cramps',
      'intestinal cramps',
      'stomach cramps',
      'belly cramps',
      'gut cramps',
      'waves of cramps',
      'crampy',
      'twisting pain',
      'stomach twisting',
    ],
    'diarrhea': [
      'diarrhea',
      'diarrhoea',
      'poop',
      'poops',
      'pooped',
      'pooping',
      'stool',
      'stools',
      'bowel movement',
      'bowel movements',
      'the runs',
      'runs',
      'runny poop',
      'runny poo',
      'watery poop',
      'watery poo',
      'liquid poop',
      'liquid poo',
      'loose poop',
      'loose poo',
      'pooping a lot',
      'pooping too much',
      'pooped a lot',
      'lots of pooping',
      'a lot of pooping',
      'frequent pooping',
      'frequent bowel movements',
      'frequent bm',
      'frequent bms',
      'loose bowel movement',
      'loose bowel movements',
      'watery bowel movement',
      'watery bowel movements',
      'liquid bowel movement',
      'liquid bowel movements',
      'loose stool',
      'loose stools',
      'watery stool',
      'watery stools',
      'liquid stool',
      'liquid stools',
      'runny stool',
      'soft stool',
      'soft stools',
      'mushy stool',
      'mushy stools',
      'bristol 6',
      'bristol 7',
      'urgent diarrhea',
      'explosive diarrhea',
      'night diarrhea',
      'nocturnal diarrhea',
      'woke up to poop',
      'wakes me from sleep to poop',
      'multiple bowel movements',
    ],
    'urgency': [
      'urgency',
      'urgent',
      'urgent bowel movement',
      'bathroom',
      'toilet',
      'restroom',
      'need to go',
      'needed to go',
      'gotta go',
      'have to go',
      'had to go',
      'sudden urge',
      'urgent urge',
      'run to the bathroom',
      'rush to the bathroom',
      'race to the bathroom',
      'ran to the bathroom',
      'rushed to the bathroom',
      'barely made it',
      'almost did not make it',
      'almost didn\'t make it',
      'can\'t hold it',
      'cant hold it',
      'could not hold it',
      'couldn\'t hold it',
      'incomplete evacuation',
      'tenesmus',
      'constant urge',
      'always feel like i need to poop',
      'still need to go after pooping',
      'feels incomplete after bowel movement',
    ],
    'nausea': [
      'nausea',
      'nauseous',
      'sick to my stomach',
      'queasy',
      'feel sick',
      'felt sick',
      'stomach sick',
      'about to throw up',
      'want to throw up',
      'carsick feeling',
      'upset stomach',
      'sour stomach',
      'queasiness',
      'waves of nausea',
    ],
    'bloating': [
      'bloating',
      'bloated',
      'distended',
      'gassy',
      'gas',
      'full of gas',
      'trapped gas',
      'swollen belly',
      'belly swollen',
      'stomach swollen',
      'abdomen swollen',
      'puffy belly',
      'tight belly',
      'pressure in belly',
      'inflated',
      'abdominal distension',
      'distension',
      'stomach distension',
      'belly distension',
      'feels stretched',
    ],
    'fatigue': [
      'fatigue',
      'tired',
      'exhausted',
      'no energy',
      'wiped out',
      'drained',
      'run down',
      'low energy',
      'sleepy',
      'weak',
      'worn out',
      'spent',
      'crashed',
      'can\'t function',
      'cant function',
      'brain fog',
      'foggy',
      'hard to focus',
      'mental fog',
    ],
    'blood': [
      'blood',
      'bleeding',
      'bloody stool',
      'blood in stool',
      'blood in poop',
      'bloody poop',
      'rectal bleeding',
      'red stool',
      'red in toilet',
      'blood on paper',
      'blood when wiping',
      'mucus and blood',
      'bloody diarrhea',
      'maroon stool',
      'dark red stool',
      'blood clots in stool',
    ],
    'mucus_stool': [
      'mucus in stool',
      'mucus in poop',
      'pooing mucus',
      'pooping mucus',
      'slimy stool',
      'slimy poop',
      'jelly stool',
      'white mucus stool',
      'clear mucus stool',
      'stool with mucus',
      'pus in stool',
      'pus in poop',
      'pus with stool',
    ],
    'fever': [
      'fever',
      'temperature',
      'chills',
      'night sweat',
      'night sweats',
      'burning up',
      'feverish',
      'hot and cold',
      'shivering',
      'sweating at night',
      'high temp',
      'low grade fever',
      'chills and sweats',
      'night chills',
    ],
    'night_sweats': [
      'night sweats',
      'soaked at night',
      'waking up drenched',
      'sweating during sleep',
      'woke up sweating',
    ],
    'mouth_sores': [
      'mouth sore',
      'mouth sores',
      'mouth ulcer',
      'mouth ulcers',
      'canker',
      'canker sore',
      'oral ulcer',
      'sore in mouth',
      'tongue sore',
      'gum sore',
      'aphthous ulcer',
      'aphthous ulcers',
      'ulcer on tongue',
      'ulcer in mouth',
    ],
    'constipation': [
      'constipat',
      'constipation',
      'backed up',
      'hard stool',
      'hard stools',
      'can\'t go',
      'cant go',
      'not going',
      'cannot poop',
      'can\'t poop',
      'cant poop',
      'straining',
      'pellet stool',
      'rabbit pellets',
      'infrequent bowel movements',
      'fewer bowel movements',
      'hard to pass stool',
      'stuck stool',
    ],
    'fecal_incontinence': [
      'bowel incontinence',
      'fecal incontinence',
      'accident in underwear',
      'stool leakage',
      'leaked stool',
      'could not control bowel movement',
      'couldnt control bowel movement',
      'poop accident',
    ],
    'weight_loss': [
      'weight loss',
      'losing weight',
      'lost weight',
      'dropping weight',
      'unintentional weight loss',
      'losing pounds',
      'clothes getting loose',
    ],
    'appetite_loss': [
      'no appetite',
      'reduced appetite',
      'poor appetite',
      'lost appetite',
      'not hungry',
      'decreased appetite',
      'full quickly',
      'early satiety',
    ],
    'fistula': ['fistula', 'drainage', 'draining', 'abscess', 'perianal'],
    'joint_pain': ['joint pain', 'arthritis', 'joint ache', 'joints hurt'],
    'skin': [
      'rash',
      'skin rash',
      'red tender bumps',
      'tender bumps under skin',
      'erythema nodosum',
      'skin sore',
      'painful skin lesion',
      'pyoderma gangrenosum',
      'hidradenitis',
      'hidradenitis suppurativa',
      'skin ulcer',
      'skin nodules',
    ],
    'eye': [
      'eye pain',
      'eye irritation',
      'blurry vision',
      'red eye',
      'eye redness',
      'light hurts my eyes',
      'uveitis',
      'episcleritis',
    ],
    'anal_fissure': ['fissure', 'anal tear', 'rectal pain'],
    'obstruction': [
      'obstruction',
      'blockage',
      'stricture',
      'can\'t pass gas',
      'cant pass gas',
      'severe bloating with no stool',
      'no bowel movement and pain',
      'bowel blocked',
      'partial blockage',
    ],
    'vomiting': ['vomit', 'vomiting', 'threw up', 'throwing up'],
    'dehydration': [
      'dehydrat',
      'dry mouth',
      'can\'t keep fluids',
      'cant keep fluids',
      'very thirsty',
      'dark urine',
      'dizzy when standing',
    ],
    'malnutrition': ['malnutrition', 'malnourished', 'deficiency', 'anemia'],
    'dizziness': [
      'dizzy',
      'dizziness',
      'lightheaded',
      'lightheadedness',
      'faint',
      'near faint',
      'almost passed out',
    ],
    'back_pain': [
      'back pain',
      'backache',
      'lower back pain',
      'back cramps',
      'sacral pain',
    ],
    'urinary_urgency': [
      'need to pee often',
      'urinary urgency',
      'urge to pee',
      'pee frequently',
      'frequent urination',
      'cannot empty bladder',
      'cant empty bladder',
      'bladder pressure',
    ],
    'headache_migraine': [
      'headache',
      'headaches',
      'migraine',
      'migraines',
      'head pain',
      'throbbing head',
      'pounding head',
      'light sensitivity',
      'photophobia',
      'sound sensitivity',
      'head pressure',
      'pressure in my head',
    ],
  };

  static const _bodyAreas = <String>[
    '',
    'stomach',
    'belly',
    'abdomen',
    'abdominal',
    'gut',
    'intestinal',
    'bowel',
    'rectal',
    'anal',
    'perianal',
    'pelvic',
    'flank',
    'back',
    'lower back',
    'throat',
    'mouth',
  ];

  static const _intensifiers = <String>[
    '',
    'mild',
    'moderate',
    'bad',
    'really bad',
    'severe',
    'constant',
    'on and off',
    'random',
    'sudden',
    'frequent',
    'recurring',
  ];

  static const _templates = <String>[
    '{term}',
    '{term} today',
    '{term} all day',
    '{term} after eating',
    '{term} after meals',
    '{term} after breakfast',
    '{term} after lunch',
    '{term} after dinner',
    '{term} overnight',
    '{term} this morning',
    '{term} tonight',
    '{term} during the night',
    '{term} at night',
    '{term} after bowel movement',
    '{term} before bowel movement',
    'i have {term}',
    'i had {term}',
    'i am having {term}',
    'i keep having {term}',
    'dealing with {term}',
    'feeling {term}',
    'felt {term}',
    'noticed {term}',
    'keep getting {term}',
    'i still have {term}',
    'having episodes of {term}',
    'my {area} has {term}',
    'my {area} feels {term}',
    '{intensity} {term}',
    '{intensity} {area} {term}',
  ];

  static const _numberWords = <String, int>{
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
  };

  static const _genericSymptomWords = <String>{
    'pain',
    'ache',
    'sore',
    'weak',
    'tired',
    'gas',
    'urgent',
    'drainage',
  };

  static const _healthContextCues = <String>{
    'stool',
    'bowel',
    'poop',
    'rectal',
    'abdomen',
    'abdominal',
    'belly',
    'cramp',
    'nausea',
    'bleeding',
    'mucus',
    'urgency',
    'diarrhea',
    'constipation',
    'fatigue',
    'vomit',
  };

  SymptomParseResult parse({
    required String transcript,
    required DateTime loggedAt,
  }) {
    final cleaned = transcript.trim().replaceAll(RegExp(r'\s+'), ' ');
    final lowered = cleaned.toLowerCase();
    final rankedMatches = matchAllSymptoms(lowered);
    final bleedingPrimary = _containsExplicitBleedingCue(lowered)
        ? rankedMatches.where((m) => m.symptomType == 'blood').firstOrNull
        : null;
    final match = bleedingPrimary ??
        (rankedMatches.isNotEmpty ? rankedMatches.first : null);
    final symptomType = match?.symptomType ?? 'other';
    final severity = _detectSeverity(lowered);
    final durationMinutes = _detectDurationMinutes(lowered);
    final mealRelation = _detectMealRelation(lowered);
    final ambiguousTopCandidates = rankedMatches.length >= 2 &&
            (rankedMatches[0].confidence - rankedMatches[1].confidence) < 0.06
        ? rankedMatches.take(2).toList(growable: false)
        : const <SymptomLexiconMatch>[];
    final needsClarification = symptomType == 'other' ||
        severity == null ||
        ambiguousTopCandidates.isNotEmpty;
    final uncertaintyNotes = <String>[
      if (symptomType == 'other') 'Symptom type was not clear.',
      if (severity == null) 'Severity was not explicit.',
      if (ambiguousTopCandidates.isNotEmpty)
        'Symptom text matched multiple categories with similar confidence.',
    ];
    final safetyFlags = _detectSafetyFlags(
      lowered,
      symptomType: symptomType,
      severity: severity,
    );
    final confidence = _confidence(
      transcript: cleaned,
      symptomType: symptomType,
      severity: severity,
      mealRelation: mealRelation,
      durationMinutes: durationMinutes,
    );

    return SymptomParseResult(
      status: 'success',
      structuredSymptom: StructuredSymptom(
        symptomType: symptomType,
        severity1To10: severity,
        onsetTime: null,
        loggedTime: loggedAt.toUtc(),
        durationMinutes: durationMinutes,
        mealRelation: mealRelation,
        notes: cleaned,
        sourceTranscript: cleaned,
        extractionConfidence: confidence,
        userFacingDescription: _userFacingDescription(
          symptomType: symptomType,
          severity: severity,
          mealRelation: mealRelation,
          durationMinutes: durationMinutes,
        ),
        uncertaintyNotes: uncertaintyNotes,
        safetyFlags: safetyFlags,
      ),
      needsClarification: needsClarification,
      clarificationQuestion: _clarificationQuestion(
        symptomType: symptomType,
        severity: severity,
        topCandidates: ambiguousTopCandidates,
      ),
    );
  }

  bool _containsExplicitBleedingCue(String lowered) {
    return RegExp(
      r'\b(blood|bloody|bleeding|blood in stool|blood in poop|rectal bleeding)\b',
    ).hasMatch(lowered);
  }

  static bool looksLikeSymptomText(String text) {
    return matchSymptom(text) != null;
  }

  static int lexiconTermCountFor(String symptomType) {
    return _symptomKeywords[symptomType]?.length ?? 0;
  }

  static SymptomLexiconMatch? matchSymptom(String text) {
    final normalized = _normalizeWithReplacements(text);
    if (normalized.isEmpty) return null;

    SymptomLexiconMatch? best;
    for (final entry in _symptomKeywords.entries) {
      for (final synonym in entry.value) {
        final normalizedSynonym = _normalize(synonym);
        if (normalizedSynonym.isEmpty) continue;
        if (_containsPhrase(normalized, normalizedSynonym)) {
          final confidence = _adjustConfidence(
            base: normalizedSynonym.length > 8 ? 0.94 : 0.88,
            normalizedText: normalized,
            normalizedSynonym: normalizedSynonym,
          );
          final candidate = SymptomLexiconMatch(
            symptomType: entry.key,
            confidence: confidence,
            matchedText: synonym,
            matchType: 'synonym',
          );
          if (best == null || candidate.confidence > best.confidence) {
            best = candidate;
          }
        }
      }
    }
    if (best != null) return best;

    final words = normalized.split(' ').where((word) => word.length >= 4);
    for (final word in words) {
      for (final entry in _symptomKeywords.entries) {
        for (final synonym in entry.value) {
          final normalizedSynonym = _normalize(synonym);
          if (normalizedSynonym.contains(' ')) continue;
          if (normalizedSynonym.length < 4) continue;
          final similarity = _similarity(word, normalizedSynonym);
          // Short synonyms (≤5 chars) need an exact match — fuzzy threshold is
          // too permissive for 4-char words (e.g. "week" ≈ "weak" at 0.75).
          final minSimilarity = normalizedSynonym.length <= 5 ? 1.0 : 0.74;
          if (similarity < minSimilarity) continue;
          final adjusted = _adjustConfidence(
            base: similarity,
            normalizedText: normalized,
            normalizedSynonym: normalizedSynonym,
          );
          final candidate = SymptomLexiconMatch(
            symptomType: entry.key,
            confidence: adjusted,
            matchedText: synonym,
            matchType: 'fuzzy_synonym',
          );
          if (best == null || candidate.confidence > best.confidence) {
            best = candidate;
          }
        }
      }
    }
    if (best != null) return best;

    // Tier C: combine phonetic key and n-gram overlap for typo-heavy misses.
    for (final word in words) {
      for (final entry in _symptomKeywords.entries) {
        for (final synonym in entry.value) {
          final normalizedSynonym = _normalize(synonym);
          if (normalizedSynonym.contains(' ')) continue;
          if (normalizedSynonym.length < 5) continue;
          final phonetic =
              _phoneticKey(word) == _phoneticKey(normalizedSynonym) ? 1.0 : 0.0;
          final tri = _trigramSimilarity(word, normalizedSynonym);
          final composite = (phonetic * 0.6) + (tri * 0.4);
          if (composite < 0.68) continue;
          final candidate = SymptomLexiconMatch(
            symptomType: entry.key,
            confidence: _adjustConfidence(
              base: composite,
              normalizedText: normalized,
              normalizedSynonym: normalizedSynonym,
            ),
            matchedText: synonym,
            matchType: 'phonetic_ngram',
          );
          if (best == null || candidate.confidence > best.confidence) {
            best = candidate;
          }
        }
      }
    }
    return best;
  }

  static List<SymptomLexiconMatch> matchAllSymptoms(String text) {
    final normalized = _normalizeWithReplacements(text);
    if (normalized.isEmpty) return const [];
    final byType = <String, SymptomLexiconMatch>{};

    for (final entry in _symptomKeywords.entries) {
      final type = entry.key;
      for (final synonym in entry.value) {
        final normalizedSynonym = _normalize(synonym);
        if (normalizedSynonym.isEmpty) continue;
        if (_containsPhrase(normalized, normalizedSynonym)) {
          final confidence = _adjustConfidence(
            base: normalizedSynonym.length > 8 ? 0.94 : 0.88,
            normalizedText: normalized,
            normalizedSynonym: normalizedSynonym,
          );
          final candidate = SymptomLexiconMatch(
            symptomType: type,
            confidence: confidence,
            matchedText: synonym,
            matchType: 'synonym',
          );
          final current = byType[type];
          if (current == null || candidate.confidence > current.confidence) {
            byType[type] = candidate;
          }
        }
      }
    }

    final words = normalized.split(' ').where((word) => word.length >= 4);
    for (final word in words) {
      for (final entry in _symptomKeywords.entries) {
        final type = entry.key;
        for (final synonym in entry.value) {
          final normalizedSynonym = _normalize(synonym);
          if (normalizedSynonym.contains(' ')) continue;
          if (normalizedSynonym.length < 4) continue;
          final similarity = _similarity(word, normalizedSynonym);
          final minSimilarity = normalizedSynonym.length <= 5 ? 1.0 : 0.74;
          if (similarity < minSimilarity) continue;
          final adjusted = _adjustConfidence(
            base: similarity,
            normalizedText: normalized,
            normalizedSynonym: normalizedSynonym,
          );
          final candidate = SymptomLexiconMatch(
            symptomType: type,
            confidence: adjusted,
            matchedText: synonym,
            matchType: 'fuzzy_synonym',
          );
          final current = byType[type];
          if (current == null || candidate.confidence > current.confidence) {
            byType[type] = candidate;
          }
        }
      }
    }

    for (final word in words) {
      for (final entry in _symptomKeywords.entries) {
        final type = entry.key;
        for (final synonym in entry.value) {
          final normalizedSynonym = _normalize(synonym);
          if (normalizedSynonym.contains(' ')) continue;
          if (normalizedSynonym.length < 5) continue;
          final phonetic =
              _phoneticKey(word) == _phoneticKey(normalizedSynonym) ? 1.0 : 0.0;
          final tri = _trigramSimilarity(word, normalizedSynonym);
          final composite = (phonetic * 0.6) + (tri * 0.4);
          if (composite < 0.68) continue;
          final candidate = SymptomLexiconMatch(
            symptomType: type,
            confidence: _adjustConfidence(
              base: composite,
              normalizedText: normalized,
              normalizedSynonym: normalizedSynonym,
            ),
            matchedText: synonym,
            matchType: 'phonetic_ngram',
          );
          final current = byType[type];
          if (current == null || candidate.confidence > current.confidence) {
            byType[type] = candidate;
          }
        }
      }
    }

    final ranked = byType.values.toList(growable: false)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return ranked;
  }

  static Map<String, List<String>> _buildLexicon() {
    return _seedSynonyms.map((symptomType, terms) {
      return MapEntry(symptomType, _expandedTerms(terms));
    });
  }

  static List<String> _expandedTerms(List<String> seeds) {
    final expanded = <String>{};
    for (final seed in seeds) {
      final normalizedSeed = _normalize(seed);
      if (normalizedSeed.isNotEmpty) expanded.add(normalizedSeed);
    }
    for (final seed in seeds) {
      final normalizedSeed = _normalize(seed);
      if (normalizedSeed.isEmpty) continue;
      for (final template in _templates) {
        for (final area in _bodyAreas) {
          for (final intensity in _intensifiers) {
            final phrase = template
                .replaceAll('{term}', normalizedSeed)
                .replaceAll('{area}', area)
                .replaceAll('{intensity}', intensity)
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (phrase.isNotEmpty) expanded.add(phrase);
            if (expanded.length >= 2000) {
              return expanded.toList(growable: false);
            }
          }
        }
      }
    }
    return expanded.toList(growable: false);
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _normalizeWithReplacements(String value) {
    var normalized = _normalize(value);
    if (normalized.isEmpty) return normalized;
    final words = normalized.split(' ');
    final replaced =
        words.map((word) => _normalizationReplacements[word] ?? word).join(' ');
    return _normalize(replaced);
  }

  static bool _containsPhrase(String text, String phrase) {
    if (phrase.length <= 3) return text.split(' ').contains(phrase);
    return text == phrase ||
        text.startsWith('$phrase ') ||
        text.endsWith(' $phrase') ||
        text.contains(' $phrase ');
  }

  static double _similarity(String first, String second) {
    if (first == second) return 1;
    if (first.isEmpty || second.isEmpty) return 0;
    final distance = _levenshtein(first, second);
    final longest = first.length > second.length ? first.length : second.length;
    return 1 - (distance / longest);
  }

  static int _levenshtein(String first, String second) {
    final previous = List<int>.generate(second.length + 1, (index) => index);
    final current = List<int>.filled(second.length + 1, 0);
    for (var firstIndex = 0; firstIndex < first.length; firstIndex++) {
      current[0] = firstIndex + 1;
      for (var secondIndex = 0; secondIndex < second.length; secondIndex++) {
        final cost =
            first.codeUnitAt(firstIndex) == second.codeUnitAt(secondIndex)
                ? 0
                : 1;
        current[secondIndex + 1] = _min3(
          current[secondIndex] + 1,
          previous[secondIndex + 1] + 1,
          previous[secondIndex] + cost,
        );
      }
      for (var index = 0; index < previous.length; index++) {
        previous[index] = current[index];
      }
    }
    return previous[second.length];
  }

  static int _min3(int first, int second, int third) {
    final firstTwo = first < second ? first : second;
    return firstTwo < third ? firstTwo : third;
  }

  static double _adjustConfidence({
    required double base,
    required String normalizedText,
    required String normalizedSynonym,
  }) {
    final synonymTokens = normalizedSynonym.split(' ');
    final isGeneric = synonymTokens.length == 1 &&
        _genericSymptomWords.contains(synonymTokens.first);
    final hasHealthContext = _healthContextCues.any(
      (cue) => normalizedText.contains(cue),
    );
    var adjusted = base;
    if (isGeneric && !hasHealthContext) adjusted -= 0.18;
    if (isGeneric && hasHealthContext) adjusted += 0.05;
    if (!isGeneric && hasHealthContext) adjusted += 0.02;
    if (adjusted < 0) return 0;
    if (adjusted > 0.99) return 0.99;
    return adjusted;
  }

  static String _phoneticKey(String value) {
    if (value.isEmpty) return value;
    final cleaned = value
        .replaceAll('ph', 'f')
        .replaceAll('ck', 'k')
        .replaceAll('qu', 'k')
        .replaceAll('x', 'ks')
        .replaceAll('z', 's');
    if (cleaned.length == 1) return cleaned;
    final first = cleaned[0];
    final rest = cleaned
        .substring(1)
        .replaceAll(RegExp(r'[aeiouy]'), '')
        .replaceAll(RegExp(r'(.)\1+'), r'$1');
    return '$first$rest';
  }

  static double _trigramSimilarity(String first, String second) {
    final gramsA = _ngrams(first, 3);
    final gramsB = _ngrams(second, 3);
    if (gramsA.isEmpty || gramsB.isEmpty) return 0;
    final overlap = gramsA.intersection(gramsB).length.toDouble();
    final denom = gramsA.union(gramsB).length.toDouble();
    if (denom == 0) return 0;
    return overlap / denom;
  }

  static Set<String> _ngrams(String text, int n) {
    final cleaned = text.trim();
    if (cleaned.length <= n) return {cleaned};
    final grams = <String>{};
    for (var i = 0; i <= cleaned.length - n; i++) {
      grams.add(cleaned.substring(i, i + n));
    }
    return grams;
  }

  int? _detectSeverity(String lowered) {
    final scaledNumericMatch = RegExp(
      r'\b(10|[1-9])\s*(?:/|out of)\s*10\b',
    ).firstMatch(lowered);
    if (scaledNumericMatch != null) {
      return int.tryParse(scaledNumericMatch.group(1)!);
    }

    final contextualNumericMatch = RegExp(
      r'(?:pain|cramping|cramps|nausea|bloating|fatigue|urgency|it was|felt|severity)(?:\s+(?:was|at|around|about|maybe))?\s+(10|[1-9])\b',
    ).firstMatch(lowered);
    if (contextualNumericMatch != null) {
      return int.tryParse(contextualNumericMatch.group(1)!);
    }

    final scaledWordMatch = RegExp(
      r'\b(one|two|three|four|five|six|seven|eight|nine|ten)\s+out of\s+ten\b',
    ).firstMatch(lowered);
    if (scaledWordMatch != null) {
      return _numberWords[scaledWordMatch.group(1)!];
    }
    if (lowered.contains('mild')) return 3;
    if (lowered.contains('moderate')) return 6;
    if (lowered.contains('severe')) return 8;
    return null;
  }

  int? _detectDurationMinutes(String lowered) {
    final mixedMatch = RegExp(
      r'\b(\d+)\s*(?:hour|hr)s?\s*(?:and\s*)?(\d+)\s*(?:minute|min)s?\b',
    ).firstMatch(lowered);
    if (mixedMatch != null) {
      final hours = int.tryParse(mixedMatch.group(1)!) ?? 0;
      final minutes = int.tryParse(mixedMatch.group(2)!) ?? 0;
      return (hours * 60) + minutes;
    }

    if (lowered.contains('half an hour') || lowered.contains('half hour')) {
      return 30;
    }
    if (lowered.contains('an hour')) {
      return 60;
    }
    if (lowered.contains('couple of hours') ||
        lowered.contains('couple hours')) {
      return 120;
    }
    if (lowered.contains('few hours')) {
      return 180;
    }
    if (lowered.contains('all day')) {
      return 1440;
    }
    if (lowered.contains('all morning')) {
      return 360;
    }
    if (lowered.contains('all afternoon')) {
      return 360;
    }
    if (lowered.contains('all evening')) {
      return 360;
    }
    if (lowered.contains('all night')) {
      return 480;
    }
    if (lowered.contains('just now') ||
        lowered.contains('right now') ||
        lowered == 'now') {
      return 5;
    }

    final wordHourMatch = RegExp(
      r'\b(one|two|three|four|five|six|seven|eight|nine|ten)\s*(?:hour|hr)s?\b',
    ).firstMatch(lowered);
    if (wordHourMatch != null) {
      final hours = _numberWords[wordHourMatch.group(1)!] ?? 0;
      return hours * 60;
    }
    final wordMinuteMatch = RegExp(
      r'\b(one|two|three|four|five|six|seven|eight|nine|ten)\s*(?:minute|min)s?\b',
    ).firstMatch(lowered);
    if (wordMinuteMatch != null) {
      return _numberWords[wordMinuteMatch.group(1)!];
    }

    final hourMatch = RegExp(r'\b(\d+)\s*(?:hour|hr)s?\b').firstMatch(lowered);
    if (hourMatch != null) {
      return (int.tryParse(hourMatch.group(1)!) ?? 0) * 60;
    }
    final minuteMatch = RegExp(
      r'\b(\d+)\s*(?:minute|min)s?\b',
    ).firstMatch(lowered);
    if (minuteMatch != null) {
      return int.tryParse(minuteMatch.group(1)!);
    }
    return null;
  }

  String? _detectMealRelation(String lowered) {
    if (lowered.contains('after lunch')) return 'after_lunch';
    if (lowered.contains('before lunch')) return 'before_lunch';
    if (lowered.contains('after dinner')) return 'after_dinner';
    if (lowered.contains('before dinner')) return 'before_dinner';
    if (lowered.contains('after breakfast')) return 'after_breakfast';
    if (lowered.contains('before breakfast')) return 'before_breakfast';
    if (lowered.contains('after meal') ||
        lowered.contains('after meals') ||
        lowered.contains('after eating') ||
        lowered.contains('after i ate')) {
      return 'after_meal';
    }
    if (lowered.contains('before eating') ||
        lowered.contains('before i ate') ||
        lowered.contains('empty stomach')) {
      return 'before_meal';
    }
    return null;
  }

  String? _clarificationQuestion({
    required String symptomType,
    required int? severity,
    List<SymptomLexiconMatch> topCandidates = const [],
  }) {
    if (topCandidates.length >= 2) {
      return 'I heard two likely symptoms: ${_label(topCandidates[0].symptomType)} and ${_label(topCandidates[1].symptomType)}. Which one should I log?';
    }
    if (symptomType == 'other') {
      return 'Which symptom should I record: pain, cramping, urgency, diarrhea, constipation, nausea, bloating, fatigue, headache/migraine, blood, mucus/pus in stool, mouth sores, fever, or another health symptom?';
    }
    if (severity == null) {
      return 'Would you say it was mild, moderate, or severe?';
    }
    return null;
  }

  String _label(String symptomType) {
    switch (symptomType) {
      case 'mucus_stool':
        return 'mucus/pus in stool';
      case 'fecal_incontinence':
        return 'bowel leakage';
      default:
        return symptomType.replaceAll('_', ' ');
    }
  }

  double _confidence({
    required String transcript,
    required String symptomType,
    required int? severity,
    required String? mealRelation,
    required int? durationMinutes,
  }) {
    var score = 0.35;
    if (transcript.isNotEmpty) score += 0.1;
    if (symptomType != 'other') score += 0.25;
    if (symptomType == 'other') score -= 0.1;
    if (severity != null) score += 0.15;
    if (mealRelation != null) score += 0.1;
    if (durationMinutes != null) score += 0.05;
    return score.clamp(0.0, 0.95).toDouble();
  }

  String _userFacingDescription({
    required String symptomType,
    required int? severity,
    required String? mealRelation,
    required int? durationMinutes,
  }) {
    final parts = <String>[_displayName(symptomType)];
    if (severity != null) {
      parts.add('around $severity/10');
    }
    if (mealRelation != null) {
      parts.add(mealRelation.replaceAll('_', ' '));
    }
    if (durationMinutes != null) {
      final label = _durationLabel(durationMinutes);
      if (label.startsWith('all ')) {
        parts.add(label);
      } else {
        parts.add('for $label');
      }
    }
    return parts.join(' ');
  }

  List<String> _detectSafetyFlags(
    String lowered, {
    required String symptomType,
    required int? severity,
  }) {
    final flags = <String>{};
    if (symptomType == 'blood' || lowered.contains('bleed')) {
      flags.add('bleeding_reported');
    }
    if ((severity ?? 0) >= 8) {
      flags.add('severe_symptom');
    }
    if (lowered.contains('black stool') ||
        lowered.contains('passed out') ||
        lowered.contains('fainted') ||
        lowered.contains('dehydr') ||
        lowered.contains("can't keep") ||
        lowered.contains('unable to keep') ||
        lowered.contains('fever')) {
      flags.add('urgent_review');
    }
    return flags.toList(growable: false);
  }

  String _displayName(String symptomType) {
    return switch (symptomType) {
      'pain' => 'Pain',
      'cramping' => 'Cramping',
      'diarrhea' => 'Loose stools',
      'urgency' => 'Urgency',
      'nausea' => 'Nausea',
      'bloating' => 'Bloating',
      'fatigue' => 'Fatigue',
      'blood' => 'Blood in stool',
      'mucus_stool' => 'Mucus or pus in stool',
      'headache_migraine' => 'Headache / migraine',
      'constipation' => 'Constipation',
      'fecal_incontinence' => 'Bowel incontinence',
      'night_sweats' => 'Night sweats',
      'appetite_loss' => 'Appetite loss',
      'fistula' => 'Fistula or perianal drainage',
      'joint_pain' => 'Joint pain',
      'skin' => 'Skin inflammation',
      'eye' => 'Eye inflammation',
      'anal_fissure' => 'Anal fissure pain',
      'obstruction' => 'Possible bowel obstruction symptoms',
      'vomiting' => 'Vomiting',
      'dehydration' => 'Dehydration symptoms',
      'malnutrition' => 'Malnutrition or deficiency symptoms',
      'dizziness' => 'Dizziness or near-fainting',
      'back_pain' => 'Back pain',
      'urinary_urgency' => 'Urinary urgency symptoms',
      _ => 'Symptom note',
    };
  }

  String _durationLabel(int minutes) {
    if (minutes >= 1380) return 'all day';
    if (minutes >= 60 && minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    return '$minutes minutes';
  }
}
