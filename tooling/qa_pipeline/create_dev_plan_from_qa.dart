import 'dart:io';

import 'qa_pipeline.dart';

void main(List<String> args) {
  final parsed = Args.parse(args);
  final runId = parsed['run-id'];
  if (runId == null) throw StateError('Usage: --run-id <run_id>');
  final clustersDoc =
      readJsonFile('${runDir(runId).path}/analysis/failure_clusters.json');
  final clusters =
      asList(clustersDoc['clusters']).whereType<Map<String, Object?>>();
  Directory('docs/dev-plans').createSync(recursive: true);
  var written = 0;
  for (final cluster in clusters
      .where((row) => row['severity'] == 'P0' || row['severity'] == 'P1')) {
    final id = asText(cluster['cluster_id']);
    File('docs/dev-plans/$id-implementation-plan.md').writeAsStringSync(
      _plan(runId, cluster),
    );
    written++;
  }
  stdout.writeln('GUTGUARD_DEV_PLANS=$written');
}

String _plan(String runId, Map<String, Object?> cluster) => [
      '# Implementation Plan: ${cluster['failure_code']}',
      '',
      '- status: `planned`',
      '- run_id: `$runId`',
      '- cluster_id: `${cluster['cluster_id']}`',
      '- qa_ticket: `docs/qa/bugs/${cluster['cluster_id']}.md`',
      '- owner_area: `${cluster['owner_area']}`',
      '',
      '## Problem Statement',
      '',
      'GutGuard produced `${cluster['failure_code']}` for `${cluster['turn_count']}` turn(s). This is `${cluster['severity']}` and must be closed before release if it affects the changed area.',
      '',
      '## Root-Cause Hypothesis',
      '',
      _hypothesis(
          asText(cluster['failure_code']), asText(cluster['owner_area'])),
      '',
      '## Files To Inspect',
      '',
      for (final file in _filesFor(asText(cluster['owner_area']))) '- `$file`',
      '',
      '## Implementation Steps',
      '',
      '1. Add or isolate a focused regression using the example prompts in the QA ticket.',
      '2. Fix the deterministic owner layer before changing prompts.',
      '3. Update artifact/report fields if behavior or failure codes change.',
      '4. Format touched files and run focused tests.',
      '5. Rerun evidence build, triage, QA handoff, and release gate.',
      '',
      '## Validation Commands',
      '',
      '- `dart run tooling/qa_pipeline/build_focused_regression_suite.dart --run-id $runId`',
      '- `dart run tooling/qa_pipeline/build_qa_evidence.dart --run-id <new_run_id>`',
      '- `dart run tooling/qa_pipeline/triage_persona_failures.dart --run-id <new_run_id>`',
      '- `dart run tooling/qa_pipeline/validate_release_gate.dart --run-id <new_run_id>`',
      '',
      '## Acceptance Criteria',
      '',
      '- The original failing prompts no longer produce `${cluster['failure_code']}`.',
      '- No P0/P1 remains for `${cluster['owner_area']}`.',
      '- QA validator writes release evidence for the rerun.',
      '',
      '## Implementation Note',
      '',
      '- status: `pending`',
      '- changed_files:',
      '- commands_run:',
      '- residual_risk:',
      '',
    ].join('\n');

String _hypothesis(String code, String owner) {
  if (owner == 'native_runtime') {
    return 'Runtime state or native model lifecycle handling violated the expected model availability invariant.';
  }
  if (owner == 'local_agent_router') {
    return 'Intent routing, pending action state, or deterministic fallback selected the wrong product path.';
  }
  if (owner == 'memory_rag') {
    return 'Retrieval grounding, memory permissions, or response assembly did not match the expected evidence contract.';
  }
  if (owner == 'ocr_lab_ingestion') {
    return 'OCR/lab ingestion did not enforce review and confirmation before acting.';
  }
  if (owner == 'safety_policy') {
    return 'Safety or medical-boundary checks did not override the model response strongly enough.';
  }
  if (code.startsWith('ux.')) {
    return 'Response text failed the product tone/actionability contract.';
  }
  return 'The deterministic app contract did not cover this failure mode yet.';
}

List<String> _filesFor(String owner) => switch (owner) {
      'native_runtime' => [
          'ios/Runner/LiteRtLmRuntimeManager.swift',
          'ios/Runner/LocalModelRuntimeManager.swift',
          'lib/core/services/local_model_runtime.dart',
        ],
      'local_agent_router' => [
          'lib/core/services/local_agent_service.dart',
          'test/core/services/local_agent_service_test.dart',
          'test/gemma_eval/local_agent_eval_runner_test.dart',
        ],
      'memory_rag' => [
          'lib/core/services/local_agent_service.dart',
          'lib/core/repositories/wearable_sample_repository.dart',
        ],
      'ocr_lab_ingestion' => [
          'lib/core/services/local_agent_service.dart',
          'lib/core/services/lab_parser_service.dart',
        ],
      'safety_policy' => [
          'lib/core/services/local_agent_service.dart',
          'integration_test/adversarial_prompt_injection_test.dart',
        ],
      _ => ['lib/core/services/local_agent_service.dart'],
    };
