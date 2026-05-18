import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/diagnostic_log_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('records structured local logs with scrubbed metadata', () async {
    final harness = await _Harness.create();
    final service = DiagnosticLogService(
      repository: harness.repository,
      sessionId: 'test-session',
      swallowFailures: false,
      nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
    );

    await service.info(
      'Chat Response!',
      category: DiagnosticLogService.categoryChat,
      message:
          'Answered user@example.com after a local runtime fallback happened.',
      metadata: const {
        'screen': 'chat',
        'risk_score': 42,
        'user_email': 'user@example.com',
        'nested': {'raw': 'nope'},
      },
    );

    final logs = await harness.repository.getDiagnosticLogs();
    expect(logs, hasLength(1));
    expect(logs.single.sessionId, 'test-session');
    expect(logs.single.level, DiagnosticLogService.levelInfo);
    expect(logs.single.category, DiagnosticLogService.categoryChat);
    expect(logs.single.eventName, 'chat_response');
    expect(logs.single.message, contains('[redacted-email]'));
    expect(logs.single.metadataJson['screen'], 'chat');
    expect(logs.single.metadataJson['risk_score'], '[redacted]');
    expect(logs.single.metadataJson['user_email'], '[redacted]');
    expect(logs.single.metadataJson['nested'], '[redacted]');

    await harness.dispose();
  });

  test(
    'records error type and stack hash without raw exception text',
    () async {
      final harness = await _Harness.create();
      final service = DiagnosticLogService(
        repository: harness.repository,
        sessionId: 'test-session',
        swallowFailures: false,
        nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
      );

      await service.error(
        'export_failed',
        category: DiagnosticLogService.categoryExport,
        message: 'Export could not be prepared.',
        error: FormatException('CRP 99 for named patient should not leak'),
        stackTrace: StackTrace.current,
        metadata: const {'byte_count': 1234},
      );

      final log = (await harness.repository.getDiagnosticLogs()).single;
      expect(log.level, DiagnosticLogService.levelError);
      expect(log.message, 'Export could not be prepared.');
      expect(log.metadataJson['error_type'], 'FormatException');
      expect(log.metadataJson['stack_hash'], isA<String>());
      expect(log.metadataJson.toString(), isNot(contains('CRP 99')));
      expect(log.metadataJson.toString(), isNot(contains('named patient')));

      await harness.dispose();
    },
  );

  test('applies retention and max-row trimming', () async {
    final harness = await _Harness.create();
    var now = DateTime.parse('2026-04-20T08:00:00Z');
    final service = DiagnosticLogService(
      repository: harness.repository,
      sessionId: 'test-session',
      maxRows: 2,
      retention: const Duration(days: 7),
      swallowFailures: false,
      nowProvider: () => now,
    );

    await harness.repository.insertDiagnosticLog(
      DiagnosticLogRecord(
        createdAt: DateTime.parse('2026-04-01T08:00:00Z'),
        sessionId: 'old-session',
        level: DiagnosticLogService.levelInfo,
        category: DiagnosticLogService.categoryApp,
        eventName: 'old_event',
        message: 'Old log.',
        metadataJson: const {},
      ),
    );

    await service.info('first');
    now = DateTime.parse('2026-04-20T08:01:00Z');
    await service.info('second');
    now = DateTime.parse('2026-04-20T08:02:00Z');
    await service.info('third');

    final logs = await harness.repository.getDiagnosticLogs();
    expect(logs, hasLength(2));
    expect(logs.map((log) => log.eventName), ['third', 'second']);
    expect(logs.any((log) => log.eventName == 'old_event'), isFalse);

    await harness.dispose();
  });
}

class _Harness {
  const _Harness({
    required this.tempRoot,
    required this.database,
    required this.repository,
  });

  final Directory tempRoot;
  final AppDatabase database;
  final WearableSampleRepository repository;

  static Future<_Harness> create() async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_diagnostic_log_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    await database.open();
    return _Harness(
      tempRoot: tempRoot,
      database: database,
      repository: repository,
    );
  }

  Future<void> dispose() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }
}
