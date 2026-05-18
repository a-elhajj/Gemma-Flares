import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/database_contracts.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('app database opens and applies migration 001', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_db_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );

    final opened = await database.open();
    final tables = await opened.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );

    expect(tables, isNotEmpty);
    expect(
      tables.map((row) => row['name']),
      containsAll(<String>[
        'wearable_samples',
        'daily_summaries',
        'flare_risk_scores',
        'timeline_events',
      ]),
    );

    final databaseFile = File(
      path.join(tempRoot.path, DatabaseContracts.databaseName),
    );
    expect(databaseFile.existsSync(), isTrue);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('concurrent open calls share a single database open', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_db_singleflight_test',
    );
    var directoryLookups = 0;
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async {
        directoryLookups += 1;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return tempRoot.path;
      },
    );

    final opened = await Future.wait(List.generate(8, (_) => database.open()));

    expect(opened.toSet(), hasLength(1));
    expect(directoryLookups, 1);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'app database tolerates journal mode pragma failures during open',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_db_fallback_test',
      );
      var didAttemptWal = false;
      var didApplyDeleteFallback = false;
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
        pragmaExecutor: (database, sql) async {
          if (sql.contains('journal_mode = WAL')) {
            didAttemptWal = true;
            throw StateError('wal unsupported');
          }

          if (sql.contains('journal_mode = DELETE')) {
            didApplyDeleteFallback = true;
            throw StateError('delete unsupported');
          }

          await database.execute(sql);
        },
      );

      final opened = await database.open();
      final journalMode = await opened.rawQuery('PRAGMA journal_mode;');

      expect(journalMode, isNotEmpty);
      expect(didAttemptWal, isTrue);
      expect(didApplyDeleteFallback, isTrue);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('migration splitter ignores semicolons inside comments and strings', () {
    final statements = AppDatabase.splitMigrationStatements('''
-- A comment can mention a semicolon; it should not split the migration.
CREATE TABLE notes (body TEXT);
INSERT INTO notes(body) VALUES ('keeps; semicolon');
-- Another trailing comment; still harmless.
''');

    expect(statements, hasLength(2));
    expect(statements.first, 'CREATE TABLE notes (body TEXT)');
    expect(
      statements.last,
      "INSERT INTO notes(body) VALUES ('keeps; semicolon')",
    );
  });
}
