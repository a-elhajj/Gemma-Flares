import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/doctor_summary_pdf_service.dart';
import 'package:gemma_flares/features/home/home_screen.dart';
import 'package:gemma_flares/features/home/widgets/chat_surface_widget.dart';

class _FakeDoctorSummaryPdfService extends DoctorSummaryPdfService {
  _FakeDoctorSummaryPdfService(this._writer);

  final Future<File> Function(DoctorSummaryPdfRenderInput input) _writer;
  DoctorSummaryPdfRenderInput? lastInput;

  @override
  Future<File> writePdfToTemp({
    required DoctorSummaryPdfRenderInput input,
    String? fileName,
  }) async {
    lastInput = input;
    return _writer(input);
  }
}

ChatMessage _summaryMessage({
  String text = '## Overview\nSymptoms and trends.',
  DateTime? timestamp,
}) {
  return ChatMessage(
    role: 'assistant',
    text: text,
    timestamp: timestamp ?? DateTime.parse('2026-05-13T12:00:00Z'),
    isGiSummary: true,
  );
}

Future<File> _writeTempPdfLikeFile(String name) async {
  final file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsBytes(const [0x25, 0x50, 0x44, 0x46], flush: true);
  return file;
}

void main() {
  test('home model warm-load timeout contract is stable', () {
    expect(kHomeModelWarmLoadTimeout, const Duration(seconds: 25));
    expect(
      homeModelLoadTimeoutBannerText(),
      'Gemma 4 is taking longer than expected — tap to retry.',
    );
  });

  group('isGiSummaryTrace', () {
    test('returns true for doctorSummary contract', () {
      expect(isGiSummaryTrace({'task_contract': 'doctorSummary'}), isTrue);
    });

    test('returns true for doctor_summary intent', () {
      expect(isGiSummaryTrace({'agent_intent': 'doctor_summary'}), isTrue);
    });

    test('returns true for doctor_summary_export route', () {
      expect(isGiSummaryTrace({'task_route': 'doctor_summary_export'}), isTrue);
    });

    test('returns false for null trace', () {
      expect(isGiSummaryTrace(null), isFalse);
    });

    test('returns false for unrelated trace', () {
      expect(isGiSummaryTrace({'agent_intent': 'risk_question'}), isFalse);
    });
  });

  group('shareGiSummaryPdfFirst', () {
    test('shares PDF when rendering succeeds', () async {
      final service = _FakeDoctorSummaryPdfService(
        (_) => _writeTempPdfLikeFile('bug066-share-success.pdf'),
      );
      var sharePdfCalls = 0;

      final usedPdf = await shareGiSummaryPdfFirst(
        message: _summaryMessage(),
        pdfService: service,
        sharePdf: (_) async => sharePdfCalls++,
      );

      expect(usedPdf, isTrue);
      expect(sharePdfCalls, 1);
    });

    test('passes title and timestamp to PDF render input', () async {
      final ts = DateTime.parse('2026-05-13T09:30:00Z');
      final service = _FakeDoctorSummaryPdfService(
        (_) => _writeTempPdfLikeFile('bug066-share-input.pdf'),
      );

      await shareGiSummaryPdfFirst(
        message: _summaryMessage(timestamp: ts),
        pdfService: service,
        sharePdf: (_) async {},
      );

      expect(service.lastInput?.title, 'Gemma Flares GI Visit Summary');
      expect(service.lastInput?.generatedAt, ts);
    });

    test('trims summary text before rendering', () async {
      final service = _FakeDoctorSummaryPdfService(
        (_) => _writeTempPdfLikeFile('bug066-share-trim.pdf'),
      );

      await shareGiSummaryPdfFirst(
        message: _summaryMessage(text: '   summary text with spaces   '),
        pdfService: service,
        sharePdf: (_) async {},
      );

      expect(service.lastInput?.summaryText, 'summary text with spaces');
    });

    test('throws when PDF render fails', () async {
      final service = _FakeDoctorSummaryPdfService(
        (_) async => throw StateError('render failed'),
      );

      await expectLater(
        () => shareGiSummaryPdfFirst(
          message: _summaryMessage(text: 'summary fallback text'),
          pdfService: service,
          sharePdf: (_) async {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when rendered file is missing', () async {
      final missing = File(
        '${Directory.systemTemp.path}/bug066-share-missing-${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      final service = _FakeDoctorSummaryPdfService((_) async => missing);

      await expectLater(
        () => shareGiSummaryPdfFirst(
          message: _summaryMessage(),
          pdfService: service,
          sharePdf: (_) async {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when rendered PDF is empty', () async {
      final emptyPdf = File(
        '${Directory.systemTemp.path}/bug066-empty-file-${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await emptyPdf.writeAsBytes(const [], flush: true);
      final service = _FakeDoctorSummaryPdfService((_) async => emptyPdf);

      await expectLater(
        () => shareGiSummaryPdfFirst(
          message: _summaryMessage(text: 'summary from empty pdf fallback'),
          pdfService: service,
          sharePdf: (_) async {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when summary text is empty after trim', () async {
      final service = _FakeDoctorSummaryPdfService(
        (_) => _writeTempPdfLikeFile('bug066-empty-input.pdf'),
      );

      await expectLater(
        () => shareGiSummaryPdfFirst(
          message: _summaryMessage(text: '   '),
          pdfService: service,
          sharePdf: (_) async {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('propagates failure when PDF share callback fails', () async {
      final service = _FakeDoctorSummaryPdfService(
        (_) => _writeTempPdfLikeFile('bug066-share-callback-fails.pdf'),
      );

      await expectLater(
        () => shareGiSummaryPdfFirst(
          message: _summaryMessage(),
          pdfService: service,
          sharePdf: (_) async => throw StateError('share callback failed'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'does not perform secondary companion share when PDF share succeeds',
      () async {
        final service = _FakeDoctorSummaryPdfService(
          (_) => _writeTempPdfLikeFile('bug066-no-text-fallback.pdf'),
        );
        var sharePdfCalls = 0;

        await shareGiSummaryPdfFirst(
          message: _summaryMessage(),
          pdfService: service,
          sharePdf: (_) async => sharePdfCalls++,
        );

        expect(sharePdfCalls, 1);
      },
    );

    test('provides a pdf path to share callback', () async {
      final file = await _writeTempPdfLikeFile('bug066-share-path.pdf');
      final service = _FakeDoctorSummaryPdfService((_) async => file);
      String? sharedPath;

      await shareGiSummaryPdfFirst(
        message: _summaryMessage(),
        pdfService: service,
        sharePdf: (pdfFile) async => sharedPath = pdfFile.path,
      );

      expect(sharedPath, isNotNull);
      expect(sharedPath, endsWith('.pdf'));
    });

    test('provides application/pdf MIME type to share callback', () async {
      final file = await _writeTempPdfLikeFile('bug066-share-mime.pdf');
      final service = _FakeDoctorSummaryPdfService((_) async => file);
      String? mimeType;

      await shareGiSummaryPdfFirst(
        message: _summaryMessage(),
        pdfService: service,
        sharePdf: (pdfFile) async => mimeType = pdfFile.mimeType,
      );

      expect(mimeType, 'application/pdf');
    });
  });
}
