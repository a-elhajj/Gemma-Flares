import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/doctor_summary_pdf_service.dart';

void main() {
  test(
    'normalizeDoctorSummaryPdfTextForDisplay removes unsupported glyphs',
    () {
      const raw =
          'Risk score: 50/100 — ELEVATED. FC: 320.0 μg/g • trend stable ×2';

      final normalized = normalizeDoctorSummaryPdfTextForDisplay(raw);

      expect(normalized, contains('Risk score: 50/100 - ELEVATED.'));
      expect(normalized, contains('FC: 320.0 ug/g'));
      expect(normalized, isNot(contains('—')));
      expect(normalized, isNot(contains('μ')));
      expect(normalized, isNot(contains('•')));
      expect(normalized, isNot(contains('×')));
    },
  );

  test('renderPdf builds a non-empty PDF document', () async {
    final service = DoctorSummaryPdfService();
    final bytes = await service.renderPdf(
      const DoctorSummaryPdfRenderInput(
        summaryText: '''## Clinical Summary
- Persistent urgency over the last 7 days
- Sleep dipped on 3 nights

## Discussion Plan
- Review stool pattern and hydration changes
- Confirm timing of current medications''',
        groundedContext: {
          'symptom_count': 5,
          'lab_count': 2,
          'source_count': 4,
          'data_gaps': ['no wearable data on 2 days'],
        },
        timeRangeLabel: '2026-04-01 to 2026-04-30',
      ),
    );

    expect(bytes, isNotEmpty);
    final header = ascii.decode(bytes.take(4).toList(growable: false));
    expect(header, '%PDF');
  });

  test(
    'renderPdf accepts plain section labels and key-value content',
    () async {
      final service = DoctorSummaryPdfService();
      final bytes = await service.renderPdf(
        const DoctorSummaryPdfRenderInput(
          summaryText: '''Summary
Overview
Current Gemma Flares risk score: 50/100 — ELEVATED.
Lab Results
FC: 320.0 μg/g (ref <150.0 μg/g) — ELEVATED [2026-05-13]
Check-in Summary
Pattern overview:
Trend stable.''',
        ),
      );

      expect(bytes, isNotEmpty);
      final header = ascii.decode(bytes.take(4).toList(growable: false));
      expect(header, '%PDF');
    },
  );
}
