import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/photo_intake_service.dart';
import 'package:gemma_flares/features/home/home_screen.dart';

PhotoIntakeResult _labResult({String? ocrText}) {
  return PhotoIntakeResult(
    transactionId: 'tx-1',
    kind: PhotoIntakeKind.labReport,
    confidence: 0.9,
    ocrText: ocrText,
    userFacingSummary: 'I found a lab report and prepared a review card.',
    requiresConfirmation: true,
  );
}

void main() {
  test('BUG-003 returns null when there is no photo context', () {
    final reply = buildDeterministicPhotoReply(
      result: null,
      userText: 'print results',
    );

    expect(reply, isNull);
  });

  test('BUG-003 singular print result returns OCR text', () {
    final reply = buildDeterministicPhotoReply(
      result: _labResult(ocrText: 'CRP 12.4 mg/L'),
      userText: 'print result',
    );

    expect(reply, isNotNull);
    expect(reply, contains('Here is the OCR text I read from the last photo'));
    expect(reply, contains('CRP 12.4 mg/L'));
  });

  test('BUG-003 show result alias returns OCR text', () {
    final reply = buildDeterministicPhotoReply(
      result: _labResult(ocrText: 'Fecal calprotectin 680 ug/g'),
      userText: 'show result',
    );

    expect(reply, isNotNull);
    expect(reply, contains('Fecal calprotectin 680 ug/g'));
  });

  test('BUG-003 no OCR text explains retake path with filename', () {
    final reply = buildDeterministicPhotoReply(
      result: _labResult(ocrText: '   '),
      userText: 'print results',
      lastPhotoFilename: 'labs.png',
    );

    expect(reply, isNotNull);
    expect(reply, contains('I do not have readable OCR text'));
    expect(reply, contains('(labs.png)'));
  });
}
