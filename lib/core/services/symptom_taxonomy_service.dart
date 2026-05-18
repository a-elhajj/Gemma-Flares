import 'dart:convert';

import 'package:flutter/services.dart';

class SymptomTaxonomyEntry {
  const SymptomTaxonomyEntry({
    required this.id,
    required this.canonical,
    required this.synonyms,
    required this.conditions,
    required this.severityScale,
    required this.bodyRegion,
    required this.relatedToFlare,
    this.harveyBradshawItem,
    this.redFlag = false,
  });

  final String id;
  final String canonical;
  final List<String> synonyms;
  final List<String> conditions;
  final String severityScale;
  final String bodyRegion;
  final bool relatedToFlare;
  final String? harveyBradshawItem;
  final bool redFlag;
}

class SymptomTaxonomyMatch {
  const SymptomTaxonomyMatch({
    required this.entry,
    required this.matchType,
    required this.confidence,
    required this.matchedText,
  });

  final SymptomTaxonomyEntry entry;
  final String matchType;
  final double confidence;
  final String matchedText;
}

class SymptomTaxonomyService {
  SymptomTaxonomyService({Future<String> Function()? assetLoader})
      : _assetLoader = assetLoader ??
            (() => rootBundle.loadString('assets/clinical/symptoms_v1.json'));

  final Future<String> Function() _assetLoader;
  Future<List<SymptomTaxonomyEntry>>? _entriesFuture;

  Future<List<SymptomTaxonomyEntry>> loadEntries() {
    return _entriesFuture ??= _loadEntries();
  }

  Future<SymptomTaxonomyMatch?> match(String rawText) async {
    final normalized = _normalize(rawText);
    if (normalized.isEmpty) return null;
    final entries = await loadEntries();

    for (final entry in entries) {
      if (_normalize(entry.id) == normalized ||
          _normalize(entry.canonical) == normalized) {
        return SymptomTaxonomyMatch(
          entry: entry,
          matchType: 'exact',
          confidence: 1,
          matchedText: rawText,
        );
      }
    }

    for (final entry in entries) {
      for (final synonym in entry.synonyms) {
        final normalizedSynonym = _normalize(synonym);
        if (normalizedSynonym == normalized ||
            normalized.contains(normalizedSynonym) ||
            normalizedSynonym.contains(normalized)) {
          return SymptomTaxonomyMatch(
            entry: entry,
            matchType: 'synonym',
            confidence: 0.92,
            matchedText: synonym,
          );
        }
      }
    }

    SymptomTaxonomyMatch? best;
    for (final entry in entries) {
      for (final candidate in [entry.canonical, ...entry.synonyms]) {
        final candidateNormalized = _normalize(candidate);
        final similarity = _similarity(normalized, candidateNormalized);
        if (similarity < 0.78) continue;
        if (best == null || similarity > best.confidence) {
          best = SymptomTaxonomyMatch(
            entry: entry,
            matchType: 'string_similarity',
            confidence: similarity,
            matchedText: candidate,
          );
        }
      }
    }
    return best;
  }

  Future<String> canonicalizeId(String rawText) async {
    final matchResult = await match(rawText);
    return matchResult?.entry.id ?? rawText.trim();
  }

  Future<List<SymptomTaxonomyEntry>> _loadEntries() async {
    final decoded = jsonDecode(await _assetLoader());
    final symptoms = decoded is Map ? decoded['symptoms'] : null;
    if (symptoms is! List) return const [];
    return symptoms.whereType<Map>().map((raw) {
      return SymptomTaxonomyEntry(
        id: raw['id'] as String,
        canonical: raw['canonical'] as String,
        synonyms: (raw['synonyms'] as List? ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        conditions: (raw['conditions'] as List? ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        severityScale: raw['severity_scale']?.toString() ?? 'unknown',
        bodyRegion: raw['body_region']?.toString() ?? 'unknown',
        relatedToFlare: raw['related_to_flare'] == true,
        harveyBradshawItem: raw['harvey_bradshaw_item'] as String?,
        redFlag: raw['red_flag'] == true,
      );
    }).toList(growable: false);
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static double _similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final distance = _levenshtein(a, b);
    final longest = a.length > b.length ? a.length : b.length;
    return 1 - (distance / longest);
  }

  static int _levenshtein(String a, String b) {
    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = _min3(
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost,
        );
      }
      for (var j = 0; j < previous.length; j++) {
        previous[j] = current[j];
      }
    }
    return previous[b.length];
  }

  static int _min3(int a, int b, int c) {
    final ab = a < b ? a : b;
    return ab < c ? ab : c;
  }
}
