import 'package:flutter/services.dart';

class LabReportOcrResult {
  const LabReportOcrResult({
    required this.status,
    required this.text,
    this.reason,
  });

  final String status;
  final String text;
  final String? reason;

  factory LabReportOcrResult.fromJson(Map<Object?, Object?> json) {
    return LabReportOcrResult(
      status: json['status'] as String? ?? 'unavailable',
      text: json['text'] as String? ?? '',
      reason: json['reason'] as String?,
    );
  }
}

class LabReportOcrService {
  LabReportOcrService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.gemma_flares/lab_ocr');

  final MethodChannel _channel;

  Future<LabReportOcrResult> pickImageAndRecognizeText({
    bool camera = false,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'pickImageAndRecognizeText',
        {'camera': camera},
      );
      return LabReportOcrResult.fromJson(raw ?? const {});
    } on MissingPluginException {
      return const LabReportOcrResult(
        status: 'unavailable',
        text: '',
        reason: 'Native OCR bridge is unavailable on this platform.',
      );
    } on PlatformException catch (error) {
      return LabReportOcrResult(
        status: 'failed',
        text: '',
        reason: error.message ?? error.code,
      );
    }
  }

  Future<LabReportOcrResult> recognizeTextAtPath(String path) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'recognizeTextAtPath',
        {'path': path},
      );
      return LabReportOcrResult.fromJson(raw ?? const {});
    } on MissingPluginException {
      return const LabReportOcrResult(
        status: 'unavailable',
        text: '',
        reason: 'Native OCR bridge is unavailable on this platform.',
      );
    } on PlatformException catch (error) {
      return LabReportOcrResult(
        status: 'failed',
        text: '',
        reason: error.message ?? error.code,
      );
    }
  }
}
