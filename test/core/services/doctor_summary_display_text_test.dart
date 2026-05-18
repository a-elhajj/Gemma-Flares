// Isolated unit tests for [doctorSummaryDisplayTextForTest], the chat
// display-layer formatter for GI / doctor summary output.
//
// These tests pin the *display* contract independent of the storage
// normalizer in `gemma_task_service.dart`. The display layer is the
// last line of defense before a clinician (or the user reading on
// behalf of a clinician) sees the document: bullet markers, leading
// indentation, numbered-list prefixes, and markdown emphasis runs
// must not reach the screen even if the storage layer is bypassed.
//
// Why this file exists separately from
// `doctor_summary_output_review_test.dart`:
//
//   * That suite exercises the integration path (storage normalizer →
//     fallback builder → display formatter).
//   * This suite pins the display formatter alone, so a regression in
//     the chat display path surfaces independently of the storage
//     fix in BUG-080. Without isolated coverage, a future refactor
//     of `_doctorSummaryDisplayText` could silently regress while
//     storage-normalizer tests continue passing.
//
// Contract enforced:
//   - No line starts with whitespace.
//   - No line starts with a bullet marker (`-`, `*`, `•`, `–`, `—`)
//     followed by a space.
//   - No line starts with a numbered list marker (`1.`, `1)`).
//   - Markdown emphasis (`**bold**`, `__underline__`, backticks) is
//     stripped.
//   - Markdown heading markers (`##`, `###`) are stripped; the
//     heading text is preserved on its own line.
//   - Exactly one blank line precedes each heading after the first.
//   - CRLF / CR line endings are normalized to LF.
//   - Code fences (```) and horizontal rules (---, ***, ___) are
//     dropped.
//   - Empty input returns an empty string (never crashes).

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';

/// Reject any output line that violates the visible-clinical-document
/// contract. Returns the violating line, or `null` if every line is
/// clean. Tests should assert the result is `null` so failures point
/// to the exact offending line.
String? firstFormattingViolation(String output) {
  final lines = output.split('\n');
  for (final line in lines) {
    if (line.isEmpty) continue; // blank lines between sections allowed
    if (line.startsWith(' ') || line.startsWith('\t')) {
      return 'Leading whitespace: ${_dq(line)}';
    }
    if (RegExp(r'^(?:[-*•]|[–—])\s+').hasMatch(line)) {
      return 'Bullet marker: ${_dq(line)}';
    }
    if (RegExp(r'^\d{1,2}[.)]\s+').hasMatch(line)) {
      return 'Numbered list marker: ${_dq(line)}';
    }
    if (line.contains('**')) {
      return 'Residual bold emphasis: ${_dq(line)}';
    }
    if (line.contains('`')) {
      return 'Residual backtick: ${_dq(line)}';
    }
    if (RegExp(r'^#{1,6}\s').hasMatch(line)) {
      return 'Residual markdown heading marker: ${_dq(line)}';
    }
    if (line == '---' || line == '***' || line == '___') {
      return 'Horizontal rule survived: ${_dq(line)}';
    }
    if (line.contains('\r')) {
      return 'Residual CR: ${_dq(line)}';
    }
  }
  return null;
}

String _dq(String s) => '"$s"';

/// Verify that every heading after the first is preceded by exactly
/// one blank line. Returns the offending heading, or `null` if the
/// spacing contract holds.
String? firstHeadingSpacingViolation(String output, List<String> headings) {
  final lines = output.split('\n');
  for (var h = 1; h < headings.length; h++) {
    final heading = headings[h];
    final idx = lines.indexOf(heading);
    if (idx <= 0) continue;
    if (lines[idx - 1].isNotEmpty) {
      return 'Heading "$heading" not preceded by blank line';
    }
    if (idx >= 2 && lines[idx - 2].isEmpty) {
      return 'Heading "$heading" preceded by >1 blank line';
    }
  }
  return null;
}

void main() {
  group('doctorSummaryDisplayTextForTest — empty/degenerate input', () {
    test('empty string returns empty string', () {
      expect(doctorSummaryDisplayTextForTest(''), isEmpty);
    });

    test('whitespace-only string returns empty string', () {
      expect(doctorSummaryDisplayTextForTest('   \n\t\n  '), isEmpty);
    });

    test('null-effective input (just newlines) returns empty', () {
      expect(doctorSummaryDisplayTextForTest('\n\n\n'), isEmpty);
    });
  });

  group('doctorSummaryDisplayTextForTest — heading handling', () {
    test('strips ## marker and preserves heading text', () {
      final out = doctorSummaryDisplayTextForTest('## Overview\nRisk 33/100.');
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('Overview'));
      expect(out, contains('Risk 33/100.'));
      expect(out, isNot(contains('##')));
    });

    test('handles all heading levels h1..h6', () {
      const input = '# H1\nbody1\n## H2\nbody2\n### H3\nbody3\n'
          '#### H4\nbody4\n##### H5\nbody5\n###### H6\nbody6';
      final out = doctorSummaryDisplayTextForTest(input);
      expect(firstFormattingViolation(out), isNull);
      for (final h in const ['H1', 'H2', 'H3', 'H4', 'H5', 'H6']) {
        expect(out, contains(h));
      }
    });

    test('inserts exactly one blank line before each heading after first', () {
      const input =
          '## Overview\nbody1\n## GI Activity Summary\nbody2\n## Lab Results\nbody3';
      final out = doctorSummaryDisplayTextForTest(input);
      expect(firstFormattingViolation(out), isNull);
      expect(
        firstHeadingSpacingViolation(out, const [
          'Overview',
          'GI Activity Summary',
          'Lab Results',
        ]),
        isNull,
      );
    });

    test('first heading is NOT preceded by a blank line', () {
      final out = doctorSummaryDisplayTextForTest('## Overview\nbody');
      expect(
        out.startsWith('Overview'),
        isTrue,
        reason: 'Output starts with first heading, no leading blank: $out',
      );
    });

    test('strips bold and backticks from heading text itself', () {
      final out = doctorSummaryDisplayTextForTest('## **Lab** `Results`\nbody');
      expect(out, contains('Lab Results'));
      expect(out, isNot(contains('*')));
      expect(out, isNot(contains('`')));
    });

    test('empty heading body is dropped (does not emit a blank heading)', () {
      final out = doctorSummaryDisplayTextForTest('##   \nbody');
      expect(out.trim(), 'body');
    });

    test('splits inline Condensed Diet heading into its own section', () {
      const input =
          'Bowel Pattern Baseline Stool-data days: 29; urgency days: 29. '
          'Condensed Diet and Trigger Log After meals: 44 occurrence(s).\n'
          'Questions for Your GI Doctor Should I escalate if urgency worsens?';
      final out = doctorSummaryDisplayTextForTest(input);

      expect(firstFormattingViolation(out), isNull, reason: 'Output:\n$out');
      expect(out, contains('Bowel Pattern Baseline'));
      expect(out, contains('Condensed Diet and Trigger Log'));
      expect(out, contains('After meals: 44 occurrence(s).'));
      expect(out, contains('Questions for Your GI Doctor'));
      expect(
        firstHeadingSpacingViolation(out, const [
          'Bowel Pattern Baseline',
          'Condensed Diet and Trigger Log',
          'Questions for Your GI Doctor',
        ]),
        isNull,
        reason: 'Output:\n$out',
      );
      expect(RegExp(r'^\s*[-*•]\s+', multiLine: true).hasMatch(out), isFalse);
      expect(
        RegExp(r'^\s*\d{1,2}[.)]\s+', multiLine: true).hasMatch(out),
        isFalse,
      );
    });

    test('does not split placeholder sentence containing Lab Results token',
        () {
      const input =
          'Lab Results\nNo saved Lab Results were found in this window.';
      final out = doctorSummaryDisplayTextForTest(input);

      expect(firstFormattingViolation(out), isNull, reason: 'Output:\n$out');
      expect(out, contains('No saved Lab Results were found in this window.'));
      expect(
        RegExp(
          r'No saved\s*\n\s*Lab Results\s*\n\s*were found',
          caseSensitive: false,
        ).hasMatch(out),
        isFalse,
        reason:
            'Placeholder sentence should not be fragmented into heading/body pieces.\n$out',
      );
    });

    test('does not split "Pattern overview" into a fake Overview heading', () {
      const input =
          'GI Activity Summary\nPattern overview: Bloating trend is worsening.';
      final out = doctorSummaryDisplayTextForTest(input);

      expect(firstFormattingViolation(out), isNull, reason: 'Output:\n$out');
      expect(out, contains('Pattern overview: Bloating trend is worsening.'));
      expect(
        RegExp(r'Pattern\s*\n\s*Overview', caseSensitive: false).hasMatch(out),
        isFalse,
        reason:
            'Pattern overview should remain one line, not two sections.\n$out',
      );
    });
  });

  group('doctorSummaryDisplayTextForTest — bullet/list stripping', () {
    test('strips dash bullets', () {
      final out = doctorSummaryDisplayTextForTest(
        '- Large-volume rectal bleeding.\n- Black tarry stool.',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('Large-volume rectal bleeding.'));
      expect(out, contains('Black tarry stool.'));
    });

    test('strips star bullets', () {
      final out = doctorSummaryDisplayTextForTest('* Item one\n* Item two');
      expect(firstFormattingViolation(out), isNull);
    });

    test('strips unicode • bullet', () {
      final out = doctorSummaryDisplayTextForTest('• Item one\n• Item two');
      expect(firstFormattingViolation(out), isNull);
    });

    test('strips en-dash and em-dash bullets', () {
      final out = doctorSummaryDisplayTextForTest('– Item one\n— Item two');
      expect(firstFormattingViolation(out), isNull);
    });

    test('strips numbered list markers 1. and 1)', () {
      final out = doctorSummaryDisplayTextForTest(
        '1. First question?\n2) Second question?\n10. Tenth question?',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('First question?'));
      expect(out, contains('Second question?'));
      expect(out, contains('Tenth question?'));
    });

    test('does NOT strip ranges like "2010-2020" mid-line', () {
      final out = doctorSummaryDisplayTextForTest(
        'Patient lived in region 2010-2020 with no GI symptoms.',
      );
      expect(out, contains('2010-2020'));
    });
  });

  group('doctorSummaryDisplayTextForTest — indentation handling', () {
    test('strips two-space leading indentation', () {
      final out = doctorSummaryDisplayTextForTest(
        'Lab Results\n  1 stable/normal lab series were compacted.',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('1 stable/normal lab series were compacted.'));
    });

    test('strips tab leading indentation', () {
      final out = doctorSummaryDisplayTextForTest(
        'Section\n\tIndented body line.',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('Indented body line.'));
    });

    test('strips mixed leading whitespace', () {
      final out = doctorSummaryDisplayTextForTest(
        'Section\n \t  Mixed indent line.',
      );
      expect(firstFormattingViolation(out), isNull);
    });
  });

  group('doctorSummaryDisplayTextForTest — markdown emphasis stripping', () {
    test('strips **bold**', () {
      final out = doctorSummaryDisplayTextForTest(
        'The lab is **elevated** today.',
      );
      expect(out, contains('The lab is elevated today.'));
      expect(out, isNot(contains('**')));
    });

    test('strips __underscored__', () {
      final out = doctorSummaryDisplayTextForTest('Use __caution__ here.');
      expect(out, contains('caution'));
      expect(out, isNot(contains('__')));
    });

    test('strips inline `code` backticks', () {
      final out = doctorSummaryDisplayTextForTest(
        'See lab value `CRP` for context.',
      );
      expect(out, contains('CRP'));
      expect(out, isNot(contains('`')));
    });

    test('drops code fences entirely', () {
      final out = doctorSummaryDisplayTextForTest(
        'Body\n```\nfenced content\n```\nMore body',
      );
      expect(out, contains('Body'));
      expect(out, contains('More body'));
      expect(out, isNot(contains('```')));
    });

    test('strips block-quote prefix', () {
      final out = doctorSummaryDisplayTextForTest('> Important note here.');
      expect(out, contains('Important note here.'));
      expect(out, isNot(startsWith('>')));
    });
  });

  group('doctorSummaryDisplayTextForTest — line-ending normalization', () {
    test('CRLF normalized to LF', () {
      final out = doctorSummaryDisplayTextForTest(
        '## Overview\r\nbody1\r\n## Lab Results\r\nbody2',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out.contains('\r'), isFalse);
    });

    test('bare CR normalized to LF', () {
      final out = doctorSummaryDisplayTextForTest(
        '## Overview\rbody1\r## Lab Results\rbody2',
      );
      expect(firstFormattingViolation(out), isNull);
      expect(out.contains('\r'), isFalse);
    });
  });

  group('doctorSummaryDisplayTextForTest — horizontal rules', () {
    test('drops --- horizontal rule', () {
      final out = doctorSummaryDisplayTextForTest('Body\n---\nMore body');
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('Body'));
      expect(out, contains('More body'));
    });

    test('drops *** and ___ horizontal rules', () {
      final out = doctorSummaryDisplayTextForTest('A\n***\nB\n___\nC');
      expect(firstFormattingViolation(out), isNull);
      expect(out, contains('A'));
      expect(out, contains('B'));
      expect(out, contains('C'));
    });
  });

  group('doctorSummaryDisplayTextForTest — full clinical document', () {
    test('renders 9-section GI summary cleanly end-to-end', () {
      const input = '''
## Overview
Current Gemma Flares risk score: 33/100 — MODERATE.

## GI Activity Summary
No saved symptom groups were found in this window.

## Lab Results
  1 stable/normal lab series were compacted.

## Check-in Summary
No saved check-in data was found in this window.

## Medication and Supplement Log
  - Profile medication: Biologic agents

## Bowel Pattern Baseline
No bowel-pattern baseline was derivable from saved check-ins in this window.

## Condensed Diet and Trigger Log
No recurring meal-related or trigger patterns were detected from saved notes in this window.

## Questions for Your GI Doctor
- Which symptoms should I track daily before my next visit?

## Triage and Red Flags
Use routine follow-up unless symptoms worsen or red flags appear.
  - Large-volume rectal bleeding or mostly blood in the toilet.
  - Black tarry stool or vomiting blood.
''';
      final out = doctorSummaryDisplayTextForTest(input);

      expect(firstFormattingViolation(out), isNull, reason: 'Output:\n$out');
      expect(
        firstHeadingSpacingViolation(out, const [
          'Overview',
          'GI Activity Summary',
          'Lab Results',
          'Check-in Summary',
          'Medication and Supplement Log',
          'Bowel Pattern Baseline',
          'Condensed Diet and Trigger Log',
          'Questions for Your GI Doctor',
          'Triage and Red Flags',
        ]),
        isNull,
        reason: 'Output:\n$out',
      );
      expect(out, contains('Profile medication: Biologic agents'));
      expect(
        out,
        contains('Large-volume rectal bleeding or mostly blood in the toilet.'),
      );
      expect(out, contains('Black tarry stool or vomiting blood.'));
    });

    test(
        'second pass on already-flattened output preserves content '
        'and never re-introduces markdown', () {
      // Note: the formatter is one-shot for *heading spacing* — once
      // `##` markers are stripped, the second pass cannot tell which
      // lines were headings and so cannot re-insert blank lines.
      // The contract we DO guarantee on a second pass is:
      //   - No formatting violation re-introduced.
      //   - No content is lost.
      //   - No new bullets/markers materialize.
      const input = '''
## Overview
Risk 33/100 MODERATE.

## Lab Results
CRP 12 mg/L (ref <5 mg/L) (elevated) [2026-04-15].
''';
      final once = doctorSummaryDisplayTextForTest(input);
      final twice = doctorSummaryDisplayTextForTest(once);
      expect(firstFormattingViolation(twice), isNull);
      expect(twice, contains('Overview'));
      expect(twice, contains('Risk 33/100 MODERATE.'));
      expect(twice, contains('Lab Results'));
      expect(
        twice,
        contains('CRP 12 mg/L (ref <5 mg/L) (elevated) [2026-04-15].'),
      );
    });
  });

  group('doctorSummaryDisplayTextForTest — adversarial / hostile input', () {
    test('handles deeply nested markdown safely', () {
      final out = doctorSummaryDisplayTextForTest(
        '## **__`Risk`__**\n- **bold body line**',
      );
      expect(firstFormattingViolation(out), isNull);
    });

    test('does not crash on extremely long single line', () {
      final long = 'A' * 10000;
      final out = doctorSummaryDisplayTextForTest('## Title\n$long');
      expect(out, contains('Title'));
      expect(out, contains(long));
    });

    test('handles unicode and zero-width characters without crashing', () {
      final out = doctorSummaryDisplayTextForTest(
        '## Overview​\nBody with  nbsp and emoji \u{1F525}.',
      );
      // The formatter is permitted to keep unicode payload as-is — it only
      // policies *structural* markdown. We assert no structural violation.
      expect(firstFormattingViolation(out), isNull);
    });

    test('collapses runs of inner whitespace within a line', () {
      final out = doctorSummaryDisplayTextForTest(
        'Risk     score    is    33/100.',
      );
      expect(out, 'Risk score is 33/100.');
    });

    test('returns empty string when only fences and rules present', () {
      final out = doctorSummaryDisplayTextForTest('```\n---\n***\n```\n');
      expect(out, isEmpty);
    });
  });
}
