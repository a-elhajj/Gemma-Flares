import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Normalizes text into a PDF-safe, clinician-readable form.
///
/// The built-in Helvetica family used by dart_pdf does not support many
/// Unicode glyphs. We canonicalize common symbols so exported GI summaries
/// render cleanly on all viewers without replacement characters.
String normalizeDoctorSummaryPdfTextForDisplay(String input) {
  var text = input;

  const charMap = <String, String>{
    '\u2018': "'",
    '\u2019': "'",
    '\u201C': '"',
    '\u201D': '"',
    '\u2013': '-',
    '\u2014': '-',
    '\u2212': '-',
    '\u2022': '-',
    '\u25CF': '-',
    '\u25E6': '-',
    '\u00B7': '-',
    '\u2026': '...',
    '\u00D7': 'x',
    '\u00A0': ' ',
    '\uFFFD': '',
  };

  charMap.forEach((from, to) {
    text = text.replaceAll(from, to);
  });

  // Normalize micro symbol units to ASCII-friendly labels.
  text = text
      .replaceAllMapped(
        RegExp(r'[\u03BC\u00B5]\s*g', caseSensitive: false),
        (m) => m[0]![0] == 'U' ? 'UG' : 'ug',
      )
      .replaceAllMapped(
        RegExp(r'\bug/g\b', caseSensitive: false),
        (m) => m[0] == m[0]!.toUpperCase() ? 'UG/G' : 'ug/g',
      )
      .replaceAllMapped(
        RegExp(r'\bug/dl\b', caseSensitive: false),
        (m) => m[0] == m[0]!.toUpperCase() ? 'UG/DL' : 'ug/dL',
      );

  // Remove control chars but preserve newlines/tabs.
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  return text;
}

class DoctorSummaryPdfRenderInput {
  const DoctorSummaryPdfRenderInput({
    required this.summaryText,
    this.groundedContext,
    this.generatedAt,
    this.timeRangeLabel,
    this.title = 'Gemma Flares GI Visit Summary',
  });

  final String summaryText;
  final Map<String, Object?>? groundedContext;
  final DateTime? generatedAt;
  final String? timeRangeLabel;
  final String title;
}

class DoctorSummaryPdfService {
  Future<Uint8List> renderPdf(DoctorSummaryPdfRenderInput input) async {
    final generatedAt = (input.generatedAt ?? DateTime.now().toUtc()).toUtc();
    final normalizedSummary = normalizeDoctorSummaryPdfTextForDisplay(
      input.summaryText,
    );
    final sections = _parseSections(normalizedSummary);
    final groundedContext = input.groundedContext ?? const <String, Object?>{};

    final document = pw.Document(
      title: input.title,
      author: 'Gemma Flares',
      creator: 'Gemma Flares',
      subject: 'Doctor summary generated locally on-device',
    );

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 40),
          theme: pw.ThemeData.withFont(
            base: pw.Font.helvetica(),
            bold: pw.Font.helveticaBold(),
            italic: pw.Font.helveticaOblique(),
            boldItalic: pw.Font.helveticaBoldOblique(),
          ),
        ),
        footer: (context) {
          return pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          );
        },
        build: (context) => [
          _buildHeader(
            title: input.title,
            generatedAt: generatedAt,
            timeRangeLabel: input.timeRangeLabel,
          ),
          if (sections.isEmpty)
            _sectionCard(
              heading: 'Summary',
              body: [
                _SectionLine(
                  text: _cleanLine(normalizedSummary),
                  isBullet: false,
                ),
              ],
            )
          else
            ...sections.map((section) {
              return _sectionCard(
                heading: section.heading,
                body: section.lines,
              );
            }),
          _buildContextCard(groundedContext),
          _buildSafetyFooter(),
        ],
      ),
    );

    return document.save();
  }

  Future<File> writePdfToTemp({
    required DoctorSummaryPdfRenderInput input,
    String? fileName,
  }) async {
    final bytes = await renderPdf(input);
    final tempDir = await getTemporaryDirectory();
    final safeName = (fileName ??
            'gemma_flares-doctor-summary-${DateTime.now().toUtc().millisecondsSinceEpoch}.pdf')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '-');
    final output = File('${tempDir.path}/$safeName');
    await output.writeAsBytes(bytes, flush: true);
    return output;
  }

  pw.Widget _buildHeader({
    required String title,
    required DateTime generatedAt,
    required String? timeRangeLabel,
  }) {
    final generatedLabel = _formatUtc(generatedAt);
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        borderRadius: pw.BorderRadius.circular(10),
        color: PdfColor.fromHex('#F3F8F4'),
        border: pw.Border.all(color: PdfColor.fromHex('#BDD8C6')),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#0D3B2A'),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Generated: $generatedLabel',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          if ((timeRangeLabel ?? '').trim().isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 3),
              child: pw.Text(
                'Coverage: ${timeRangeLabel!.trim()}',
                style: const pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.grey700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  pw.Widget _sectionCard({
    required String heading,
    required List<_SectionLine> body,
  }) {
    final normalizedBody = body
        .where((line) => line.text.trim().isNotEmpty)
        .toList(growable: false);

    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: pw.BoxDecoration(
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#D8E2DC')),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            heading,
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#1B4332'),
            ),
          ),
          pw.SizedBox(height: 6),
          if (normalizedBody.isEmpty)
            pw.Text(
              'No additional details were provided in this section.',
              style: const pw.TextStyle(fontSize: 10),
            )
          else
            ...normalizedBody.map((line) {
              if (line.isBullet) {
                return pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('- ', style: const pw.TextStyle(fontSize: 10)),
                      pw.Expanded(
                        child: pw.Text(
                          line.text,
                          style: const pw.TextStyle(fontSize: 10, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (_looksLikeSubheading(line.text)) {
                return pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2, bottom: 4),
                  child: pw.Text(
                    line.text,
                    style: pw.TextStyle(
                      fontSize: 10.5,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColor.fromHex('#2D6A4F'),
                    ),
                  ),
                );
              }

              final keyValue = _splitKeyValue(line.text);
              if (keyValue != null) {
                return pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.RichText(
                    text: pw.TextSpan(
                      children: [
                        pw.TextSpan(
                          text: '${keyValue.$1}: ',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromHex('#1F3D2D'),
                          ),
                        ),
                        pw.TextSpan(
                          text: keyValue.$2,
                          style: const pw.TextStyle(
                            fontSize: 10,
                            color: PdfColors.black,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 4),
                child: pw.Text(
                  line.text,
                  style: const pw.TextStyle(fontSize: 10, height: 1.3),
                ),
              );
            }),
        ],
      ),
    );
  }

  pw.Widget _buildContextCard(Map<String, Object?> context) {
    final rows = <_ContextRow>[];

    final symptomCount = _readInt(context, const ['symptom_count']);
    if (symptomCount != null) {
      rows.add(_ContextRow('Symptoms logged', '$symptomCount'));
    }

    final labsCount = _readInt(context, const ['lab_count']);
    if (labsCount != null) {
      rows.add(_ContextRow('Lab results included', '$labsCount'));
    }

    final checkinCount = _readInt(context, const ['checkin_count']);
    if (checkinCount != null) {
      rows.add(_ContextRow('Check-ins included', '$checkinCount'));
    }

    final sourceCount = _readInt(context, const ['source_count']);
    if (sourceCount != null) {
      rows.add(_ContextRow('Evidence sources', '$sourceCount'));
    }

    final dataGaps = _readList(context, const ['data_gaps']);
    if (dataGaps.isNotEmpty) {
      rows.add(_ContextRow('Data gaps', dataGaps.join('; ')));
    }

    if (rows.isEmpty) {
      return pw.SizedBox.shrink();
    }

    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 4, bottom: 10),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#F8F9FA'),
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#DEE2E6')),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Grounded context snapshot',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#343A40'),
            ),
          ),
          pw.SizedBox(height: 5),
          ...rows.map(
            (row) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(
                      text: '${row.label}: ',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromHex('#495057'),
                      ),
                    ),
                    pw.TextSpan(
                      text: row.value,
                      style: const pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildSafetyFooter() {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#FFF7E6'),
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#F8DDA5')),
      ),
      child: pw.Text(
        'This summary supports clinical discussion and does not diagnose disease, '
        'confirm flare status, or recommend medication changes.',
        style: const pw.TextStyle(fontSize: 10, color: PdfColors.black),
      ),
    );
  }

  List<_SummarySection> _parseSections(String source) {
    final lines = source
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trimRight())
        .toList(growable: false);

    final sections = <_SummarySection>[];
    var activeHeading = 'Summary';
    var activeLines = <_SectionLine>[];

    void flush() {
      if (activeLines.isEmpty && sections.isNotEmpty) {
        return;
      }
      sections.add(_SummarySection(heading: activeHeading, lines: activeLines));
      activeLines = <_SectionLine>[];
    }

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      final heading = _extractHeading(trimmed);
      if (heading != null) {
        if (activeLines.isNotEmpty || sections.isEmpty) {
          flush();
        }
        activeHeading = heading;
        continue;
      }

      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        activeLines.add(
          _SectionLine(text: _cleanLine(trimmed.substring(2)), isBullet: true),
        );
        continue;
      }

      activeLines.add(_SectionLine(text: _cleanLine(trimmed), isBullet: false));
    }

    if (activeLines.isNotEmpty || sections.isEmpty) {
      flush();
    }

    return sections
        .where(
          (section) =>
              section.heading.trim().isNotEmpty || section.lines.isNotEmpty,
        )
        .toList(growable: false);
  }

  String? _extractHeading(String line) {
    if (line.startsWith('### ')) return _cleanLine(line.substring(4));
    if (line.startsWith('## ')) return _cleanLine(line.substring(3));
    if (line.startsWith('# ')) return _cleanLine(line.substring(2));

    final canonical = line.trim().toLowerCase();
    const knownHeadings = {
      'summary',
      'overview',
      'gi activity summary',
      'gi activity & symptoms',
      'lab results',
      'check-in summary',
      'questions for your gi doctor',
      'triage and red flags',
      'medication and supplement log',
      'bowel pattern baseline',
      'condensed diet and trigger log',
    };
    if (knownHeadings.contains(canonical)) {
      return _cleanLine(line);
    }

    return null;
  }

  String _cleanLine(String line) {
    return line
        .replaceAll(RegExp(r'^\s*[•\-\*]\s+'), '')
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAllMapped(RegExp(r'\[(.*?)\]\((.*?)\)'), (match) {
          return match.group(1) ?? '';
        })
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _looksLikeSubheading(String line) {
    final trimmed = line.trim();
    if (!trimmed.endsWith(':')) return false;
    final wordCount = trimmed.split(RegExp(r'\s+')).length;
    return wordCount <= 6;
  }

  (String, String)? _splitKeyValue(String line) {
    final index = line.indexOf(': ');
    if (index <= 0) return null;
    final key = line.substring(0, index).trim();
    final value = line.substring(index + 2).trim();
    if (key.isEmpty || value.isEmpty) return null;
    if (key.length > 40) return null;
    return (key, value);
  }

  String _formatUtc(DateTime value) {
    final utc = value.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    return '${utc.year}-$month-$day $hour:$minute UTC';
  }

  int? _readInt(Map<String, Object?> context, List<String> path) {
    Object? current = context;
    for (final key in path) {
      if (current is! Map<String, Object?>) return null;
      current = current[key];
    }
    if (current is num) return current.toInt();
    if (current is String) return int.tryParse(current);
    return null;
  }

  List<String> _readList(Map<String, Object?> context, List<String> path) {
    Object? current = context;
    for (final key in path) {
      if (current is! Map<String, Object?>) return const [];
      current = current[key];
    }
    if (current is List) {
      return current
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }
}

class _SummarySection {
  const _SummarySection({required this.heading, required this.lines});

  final String heading;
  final List<_SectionLine> lines;
}

class _SectionLine {
  const _SectionLine({required this.text, required this.isBullet});

  final String text;
  final bool isBullet;
}

class _ContextRow {
  const _ContextRow(this.label, this.value);

  final String label;
  final String value;
}
