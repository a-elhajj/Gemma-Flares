import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final inputPath = args.isEmpty
      ? 'tooling/gemma_eval/out/local_agent_persona_suite_results.jsonl'
      : args.first;
  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    throw StateError('Missing eval output file: $inputPath');
  }

  final outDir = Directory('tooling/gemma_eval/out')
    ..createSync(recursive: true);
  final resultsFile = File('${outDir.path}/response_vibe_results.jsonl');
  final resultSink = resultsFile.openWrite();

  var total = 0;
  var passed = 0;
  final scoreTotals = <String, int>{
    'helpfulness': 0,
    'clarity': 0,
    'empathy': 0,
    'groundedness': 0,
    'actionability': 0,
    'gemma_flares_fit': 0,
  };
  final issueCounts = <String, int>{};
  final examples = <Map<String, Object?>>[];

  for (final line in inputFile.readAsLinesSync().where(
        (line) => line.trim().isNotEmpty,
      )) {
    final row = jsonDecode(line) as Map<String, Object?>;
    final result = _scoreRow(row);
    total++;
    if (result.passed) passed++;
    for (final entry in result.scores.entries) {
      scoreTotals.update(entry.key, (value) => value + entry.value);
    }
    for (final issue in result.issues) {
      issueCounts.update(issue, (value) => value + 1, ifAbsent: () => 1);
    }
    if (!result.passed && examples.length < 40) {
      examples.add(result.toJson(includeText: true));
    }
    resultSink.writeln(jsonEncode(result.toJson()));
  }
  resultSink.close();

  final averageScore = total == 0
      ? 0.0
      : scoreTotals.values.reduce((a, b) => a + b) /
          (total * scoreTotals.length);
  final sortedIssues = issueCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  File('${outDir.path}/response_vibe_summary.md').writeAsStringSync(
    [
      '# Response Vibe Evaluation',
      '',
      '- input: `$inputPath`',
      '- rows: $total',
      '- passed: $passed',
      '- failed: ${total - passed}',
      '- average_dimension_score: ${averageScore.toStringAsFixed(2)} / 5',
      '- output: `${resultsFile.path}`',
      '',
      '## Average Scores',
      '',
      for (final entry in scoreTotals.entries)
        '- ${entry.key}: ${total == 0 ? '0.00' : (entry.value / total).toStringAsFixed(2)} / 5',
      '',
      '## Issue Counts',
      '',
      if (sortedIssues.isEmpty) '- none',
      for (final issue in sortedIssues) '- ${issue.key}: ${issue.value}',
      '',
      if (examples.isNotEmpty) '## Examples To Review',
      for (final example in examples)
        '- ${example['id']} `${example['category']}` score `${example['overall_score']}` issues `${example['issues']}`\n  - prompt: ${_oneLine(example['prompt'])}\n  - response: ${_oneLine(example['response'])}',
      '',
    ].join('\n'),
  );

  if (total > 0 && passed < total) {
    stderr.writeln(
      'Response vibe evaluation found ${total - passed} rows to review.',
    );
    exitCode = 1;
  }
}

_VibeResult _scoreRow(Map<String, Object?> row) {
  final id = row['id']?.toString() ?? 'unknown';
  final category = row['category']?.toString() ?? 'unknown';
  final expectedAction = row['expected_action']?.toString() ?? '';
  final expectedIntent = row['expected_intent']?.toString() ?? '';
  final prompt = row['prompt']?.toString() ??
      row['user_input']?.toString() ??
      row['user_message']?.toString() ??
      '';
  final response = row['response']?.toString() ?? '';
  final lower = response.toLowerCase();
  final words = _wordCount(response);
  final issues = <String>[];
  final scores = <String, int>{
    'helpfulness': 5,
    'clarity': 5,
    'empathy': 5,
    'groundedness': 5,
    'actionability': 5,
    'gemma_flares_fit': 5,
  };

  void ding(String dimension, String issue, [int amount = 1]) {
    scores[dimension] = (scores[dimension]! - amount).clamp(1, 5).toInt();
    issues.add(issue);
  }

  if (response.trim().isEmpty) {
    for (final key in scores.keys) {
      scores[key] = 1;
    }
    issues.add('empty_response');
    return _VibeResult(
      id: id,
      category: category,
      expectedAction: expectedAction,
      expectedIntent: expectedIntent,
      prompt: prompt,
      response: response,
      scores: scores,
      issues: issues,
    );
  }

  if (words < 12) ding('helpfulness', 'too_short_to_be_helpful', 2);
  if (words > 95) ding('clarity', 'too_long_for_chat_turn', 1);
  if (_sentenceCount(response) > 6) ding('clarity', 'too_many_sentences', 1);
  if (_hasJargon(lower, expectedAction)) ding('clarity', 'jargon_heavy', 1);
  if (_hasVagueGenericReply(lower)) ding('helpfulness', 'generic_or_vague', 2);
  if (_hasRoboticTone(lower)) {
    ding('gemma_flares_fit', 'robotic_or_template_tone', 1);
  }
  if (lower.contains('as an ai') || lower.contains('language model')) {
    ding('gemma_flares_fit', 'generic_ai_identity', 2);
  }
  if (lower.contains('diagnose') &&
      !lower.contains('do not diagnose') &&
      !lower.contains("don't diagnose")) {
    ding('groundedness', 'diagnosis_boundary_unclear', 2);
  }
  if (_needsEmpathy(category, expectedIntent) && !_hasEmpathy(lower)) {
    ding('empathy', 'missing_empathy_for_sensitive_turn', 2);
  }
  if (_needsAction(expectedAction) && !_hasActionableNextStep(lower)) {
    ding('actionability', 'missing_next_step', 2);
  }
  if (_needsGemmaFlaresAnchor(expectedAction, expectedIntent) &&
      !_hasGemmaFlaresAnchor(lower)) {
    ding('gemma_flares_fit', 'missing_gemma_flares_anchor', 1);
  }
  if (_needsLocalGrounding(expectedAction) && !_hasLocalGrounding(lower)) {
    ding('groundedness', 'missing_local_grounding_language', 2);
  }
  if (_soundsTooCertain(lower)) {
    ding('groundedness', 'too_certain_for_health_context', 2);
  }
  if (_hasDismissiveTone(lower)) ding('empathy', 'dismissive_tone', 2);
  if (_repeatsDoctorDisclaimerOnly(lower, words)) {
    ding('helpfulness', 'disclaimer_without_help', 2);
  }

  return _VibeResult(
    id: id,
    category: category,
    expectedAction: expectedAction,
    expectedIntent: expectedIntent,
    prompt: prompt,
    response: response,
    scores: scores,
    issues: issues.toSet().toList(growable: false),
  );
}

bool _needsEmpathy(String category, String expectedIntent) {
  final value = '$category $expectedIntent'.toLowerCase();
  return value.contains('emotional') ||
      value.contains('urgent') ||
      value.contains('symptom') ||
      value.contains('medication');
}

bool _needsAction(String expectedAction) =>
    !{'redirect', 'do_not_save'}.contains(expectedAction);

bool _needsGemmaFlaresAnchor(String expectedAction, String expectedIntent) {
  final value = '$expectedAction $expectedIntent'.toLowerCase();
  return value.contains('app_feature') ||
      value.contains('risk') ||
      value.contains('memory') ||
      value.contains('health') ||
      value.contains('model') ||
      value.contains('export') ||
      value.contains('notification');
}

bool _needsLocalGrounding(String expectedAction) => {
      'rag_memory_answer',
      'confirm_synced_health_context',
      'local_only_model_guidance',
      'export_guidance',
      'doctor_summary_guidance',
      'memory_privacy_guidance',
    }.contains(expectedAction);

bool _hasEmpathy(String lower) => _containsAny(lower, const [
      'i hear you',
      'that sounds',
      'sorry',
      'rough',
      'scary',
      'frustrating',
      'understand',
      'feel',
    ]);

bool _hasActionableNextStep(String lower) => _containsAny(lower, const [
      'review',
      'save',
      'log',
      'tell me',
      'contact',
      'seek',
      'use settings',
      'export',
      'prepare',
      'check',
      'look at',
      'track',
      'open',
    ]);

bool _hasGemmaFlaresAnchor(String lower) => _containsAny(lower, const [
      'gemma_flares',
      'symptom',
      'lab',
      'risk',
      'memory',
      'health',
      'check-in',
      'local',
      'on device',
      'gemma',
    ]);

bool _hasLocalGrounding(String lower) => _containsAny(lower, const [
      'local',
      'synced',
      'on this iphone',
      'on device',
      'transaction',
      'saved',
      'export',
    ]);

bool _hasJargon(String lower, String expectedAction) {
  final terms = <String>[
    'deterministic',
    'runtime',
    'schema',
    'vector',
    'embedding',
    'classification',
  ];
  if (expectedAction != 'device_agent_guidance') {
    terms.addAll(['persona prompt', 'report with runtime']);
  }
  return _containsAny(lower, terms);
}

bool _hasVagueGenericReply(String lower) => _containsAny(lower, const [
      'i can help with that',
      'please provide more information',
      'it depends',
      'consult a professional',
    ]);

bool _hasRoboticTone(String lower) => _containsAny(lower, const [
      'unable to comply',
      'request cannot be processed',
      'invalid input',
      'detected intent',
    ]);

bool _soundsTooCertain(String lower) => _containsAny(lower, const [
      'you definitely have',
      'this proves',
      'you are safe',
      'you do not need care',
      'ignore your doctor',
      'stop taking',
    ]);

bool _hasDismissiveTone(String lower) => _containsAny(lower, const [
      'just calm down',
      'nothing to worry about',
      'not a big deal',
      'you are overreacting',
    ]);

bool _repeatsDoctorDisclaimerOnly(String lower, int words) {
  return words < 35 &&
      lower.contains('not a doctor') &&
      !_containsAny(lower, const [
        'review',
        'log',
        'tell me',
        'contact',
        'seek',
      ]);
}

bool _containsAny(String value, List<String> terms) {
  return terms.any(value.contains);
}

int _wordCount(String value) {
  return RegExp(r"[A-Za-z0-9']+").allMatches(value).length;
}

int _sentenceCount(String value) {
  return RegExp(r'[.!?]+').allMatches(value).length;
}

String _oneLine(Object? value) {
  final text = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (text.length <= 220) return text;
  return '${text.substring(0, 217)}...';
}

class _VibeResult {
  const _VibeResult({
    required this.id,
    required this.category,
    required this.expectedAction,
    required this.expectedIntent,
    required this.prompt,
    required this.response,
    required this.scores,
    required this.issues,
  });

  final String id;
  final String category;
  final String expectedAction;
  final String expectedIntent;
  final String prompt;
  final String response;
  final Map<String, int> scores;
  final List<String> issues;

  double get overallScore =>
      scores.values.reduce((a, b) => a + b) / scores.length;

  bool get passed => overallScore >= 4 && issues.length <= 1;

  Map<String, Object?> toJson({bool includeText = false}) => {
        'id': id,
        'category': category,
        'expected_action': expectedAction,
        'expected_intent': expectedIntent,
        'passed': passed,
        'overall_score': double.parse(overallScore.toStringAsFixed(2)),
        'scores': scores,
        'issues': issues,
        if (includeText) 'prompt': prompt,
        if (includeText) 'response': response,
      };
}
