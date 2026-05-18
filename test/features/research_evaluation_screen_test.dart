import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/evaluation_service.dart';
import 'package:gemma_flares/features/research/research_evaluation_screen.dart';

void main() {
  testWidgets('research evaluation screen renders report metrics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResearchEvaluationScreen(
          reportLoader: () async => EvaluationReport(
            metrics: const [
              EvaluationMetrics(
                modelKey: 'mount_sinai_v1_inflammatory_7d',
                horizonDays: 7,
                flareType: 'inflammatory',
                sampleCount: 28,
                auc: 0.97,
                auprc: 0.82,
                f1: 0.88,
                sensitivity: 0.9,
                specificity: 0.84,
                optimalThreshold: 0.42,
              ),
              EvaluationMetrics(
                modelKey: 'mount_sinai_v1_symptomatic_14d',
                horizonDays: 14,
                flareType: 'symptomatic',
                sampleCount: 31,
                auc: 0.93,
                auprc: 0.77,
                f1: 0.81,
                sensitivity: 0.79,
                specificity: 0.8,
                optimalThreshold: 0.45,
              ),
            ],
            generatedAt: DateTime.parse('2026-04-16T08:00:00Z'),
            totalLabeledDays: 31,
            inflammatoryFlareDays: 6,
            symptomaticFlareDays: 8,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Local diagnostics'), findsOneWidget);
    expect(find.text('Local model diagnostics'), findsOneWidget);
    expect(find.text('Gemma runtime benchmark'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.textContaining('AUC'), findsWidgets);
    expect(find.textContaining('Inflammatory flare'), findsWidgets);
    expect(find.textContaining('Symptomatic flare'), findsWidgets);
    expect(find.text('31'), findsWidgets);
    expect(find.text('AUPRC'), findsWidgets);
  });
}
