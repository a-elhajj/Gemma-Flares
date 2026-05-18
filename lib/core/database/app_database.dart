import 'dart:async';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'database_contracts.dart';

typedef MigrationSqlLoader = Future<String> Function(String assetPath);
typedef DatabasePragmaExecutor = Future<void> Function(
    Database database, String sql);

class AppDatabase {
  AppDatabase({
    this.encryptionKey = '',
    MigrationSqlLoader? migrationLoader,
    DatabaseFactory? databaseFactoryOverride,
    Future<String> Function()? databaseDirectoryProvider,
    DatabasePragmaExecutor? pragmaExecutor,
  })  : _migrationLoader = migrationLoader ?? rootBundle.loadString,
        _databaseFactory = databaseFactoryOverride ?? databaseFactory,
        _databaseDirectoryProvider =
            databaseDirectoryProvider ?? getDatabasesPath,
        _pragmaExecutor = pragmaExecutor ?? _defaultPragmaExecutor;

  /// AES-256 key sourced from iOS Keychain via [EncryptionService].
  final String encryptionKey;

  final MigrationSqlLoader _migrationLoader;
  final DatabaseFactory _databaseFactory;
  final Future<String> Function() _databaseDirectoryProvider;
  final DatabasePragmaExecutor _pragmaExecutor;

  Database? _database;
  Future<Database>? _openingDatabase;

  Future<Database> open() async {
    // Fast path: already open.
    final opened = _database;
    if (opened != null) return opened;

    // Single-flight: if another caller already started opening, join that
    // future rather than opening a second connection.  The ??= is atomic
    // within Dart's single-threaded event loop — no gap between the null
    // check and the assignment can be observed by concurrent callers.
    _openingDatabase ??= _openDatabase();

    try {
      _database = await _openingDatabase!;
      return _database!;
    } finally {
      // Always clear the in-flight marker so a future open() after close()
      // starts a fresh connection rather than awaiting a completed future.
      _openingDatabase = null;
    }
  }

  Future<Database> _openDatabase() async {
    final databasesDirectory = await _databaseDirectoryProvider();
    final databasePath = path.join(
      databasesDirectory,
      DatabaseContracts.databaseName,
    );

    return _databaseFactory.openDatabase(
      databasePath,
      options: SqlCipherOpenDatabaseOptions(
        version: DatabaseContracts.currentSchemaVersion,
        password: encryptionKey.isEmpty ? null : encryptionKey,
        onConfigure: (database) async {
          await _configureDatabase(database);
        },
        onCreate: (database, version) async {
          await _applyMigrations(database, fromVersion: 1, toVersion: version);
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          await _applyMigrations(
            database,
            fromVersion: oldVersion + 1,
            toVersion: newVersion,
          );
        },
      ),
    );
  }

  Future<void> close() async {
    try {
      await _openingDatabase;
    } catch (_) {
      // If an in-flight open failed, close should still leave this wrapper reset.
    }
    await _database?.close();
    _database = null;
    _openingDatabase = null;
  }

  Future<void> _configureDatabase(Database database) async {
    await _pragmaExecutor(database, 'PRAGMA foreign_keys = ON;');

    try {
      await _pragmaExecutor(database, 'PRAGMA journal_mode = WAL;');
    } catch (_) {
      try {
        await _pragmaExecutor(database, 'PRAGMA journal_mode = DELETE;');
      } catch (_) {
        // Some iOS + sqflite combinations reject explicit journal mode changes.
        // Keep the platform default instead of failing app launch.
      }
    }
  }

  static Future<void> _defaultPragmaExecutor(Database database, String sql) {
    return database.execute(sql);
  }

  Future<void> _applyMigration(
    DatabaseExecutor database,
    String migrationSql,
  ) async {
    for (final statement in splitMigrationStatements(migrationSql)) {
      await database.execute('$statement;');
    }
  }

  static List<String> splitMigrationStatements(String migrationSql) {
    final statements = <String>[];
    final buffer = StringBuffer();
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var index = 0;

    while (index < migrationSql.length) {
      final char = migrationSql[index];
      final next =
          index + 1 < migrationSql.length ? migrationSql[index + 1] : '';

      if (!inSingleQuote && !inDoubleQuote && char == '-' && next == '-') {
        index += 2;
        while (index < migrationSql.length && migrationSql[index] != '\n') {
          index++;
        }
        continue;
      }

      if (char == "'" && !inDoubleQuote) {
        if (inSingleQuote && next == "'") {
          buffer.write(char);
          buffer.write(next);
          index += 2;
          continue;
        }
        inSingleQuote = !inSingleQuote;
      } else if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      }

      if (char == ';' && !inSingleQuote && !inDoubleQuote) {
        final statement = buffer.toString().trim();
        if (statement.isNotEmpty) {
          statements.add(statement);
        }
        buffer.clear();
      } else {
        buffer.write(char);
      }

      index++;
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      statements.add(tail);
    }
    return statements;
  }

  Future<void> _applyMigrations(
    DatabaseExecutor database, {
    required int fromVersion,
    required int toVersion,
  }) async {
    for (var version = fromVersion; version <= toVersion; version++) {
      final assetPath = DatabaseContracts.migrationAssets[version];
      if (assetPath == null) {
        throw StateError('Missing migration asset for schema version $version');
      }

      final migrationSql = await _migrationLoader(assetPath);
      await _applyMigration(database, migrationSql);
    }
  }
}
