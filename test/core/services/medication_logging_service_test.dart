import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/medication_logging_service.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('buildDraftFromText detects taken medication details', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_medication_logging_service_parse',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final profileService = ProfileService(repository: repository);
    await profileService.saveProfile(
      const UserProfile(
        medications: [MedicationEntry(name: 'Humira', dose: '40 mg')],
      ),
    );

    final service = MedicationLoggingService(
      repository: repository,
      profileService: profileService,
      nowProvider: () => DateTime.parse('2026-05-09T08:00:00Z'),
    );

    final draft = await service.buildDraftFromText(
      transcript: 'Took Humira 40 mg this morning after breakfast',
    );

    expect(draft.eventType, 'medication_taken');
    expect(draft.medicationName, 'Humira');
    expect(draft.dose?.toLowerCase(), contains('40 mg'));
    expect(draft.schedule, 'morning');
    expect(draft.requiresClarification, isFalse);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'BUG-079 buildDraftFromText handles medication and supplement variants',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_medication_logging_bug079_variants',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(repository: repository);
      await profileService.saveProfile(
        const UserProfile(
          medications: [
            MedicationEntry(name: 'Humira', dose: '40 mg'),
            MedicationEntry(name: 'Mesalamine'),
          ],
        ),
      );

      final service = MedicationLoggingService(
        repository: repository,
        profileService: profileService,
        nowProvider: () => DateTime.parse('2026-05-13T08:00:00Z'),
      );

      final cases = <String, ({String name, String eventType})>{
        'I took my vitamins today': (
          name: 'Vitamins',
          eventType: 'medication_taken',
        ),
        'I took my biologics today': (
          name: 'Biologic',
          eventType: 'medication_taken',
        ),
        'took Humira 40 mg this morning': (
          name: 'Humira',
          eventType: 'medication_taken',
        ),
        'missed mesalamine last night': (
          name: 'Mesalamine',
          eventType: 'medication_skipped',
        ),
        'log prednisone 20 mg today': (
          name: 'Prednisone',
          eventType: 'medication_taken',
        ),
        'record my vitamin D3 supplement this morning': (
          name: 'Vitamin D3',
          eventType: 'medication_taken',
        ),
        'medcation log: took budesinide 9 mg': (
          name: 'Budesonide',
          eventType: 'medication_taken',
        ),
        'got my infusion today': (
          name: 'Infusion medication',
          eventType: 'medication_taken',
        ),
        'did my injection tonight': (
          name: 'Injection medication',
          eventType: 'medication_taken',
        ),
        'track meds I took b12 today': (
          name: 'B12',
          eventType: 'medication_taken',
        ),
        'forgot my probiotic this morning': (
          name: 'Probiotic',
          eventType: 'medication_skipped',
        ),
        'received omega 3 after lunch': (
          name: 'Omega 3',
          eventType: 'medication_taken',
        ),
        'Logging that I started budesonide today for this flare': (
          name: 'Budesonide',
          eventType: 'medication_taken',
        ),
      };

      for (final entry in cases.entries) {
        final draft = await service.buildDraftFromText(transcript: entry.key);

        expect(draft.requiresClarification, isFalse, reason: entry.key);
        expect(draft.medicationName, entry.value.name, reason: entry.key);
        expect(draft.eventType, entry.value.eventType, reason: entry.key);
      }

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('saveConfirmedDraft persists medication intake event', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_medication_logging_service_save',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final profileService = ProfileService(repository: repository);

    final service = MedicationLoggingService(
      repository: repository,
      profileService: profileService,
      nowProvider: () => DateTime.parse('2026-05-09T08:00:00Z'),
    );

    final saved = await service.saveConfirmedDraft(
      MedicationLoggingDraft(
        eventType: 'medication_skipped',
        medicationName: 'Mesalamine',
        dose: '1 tablet',
        schedule: 'night',
        notes: 'Skipped due to nausea',
        loggedAt: DateTime.utc(2026, 5, 9, 3, 0),
        sourceTranscript: 'Skipped mesalamine at night',
        confidence: 1.0,
      ),
    );

    final events = await repository.getIntakeEventsBetween(
      start: DateTime.utc(2026, 5, 8),
      end: DateTime.utc(2026, 5, 10),
    );

    expect(saved.savedEvent.id, isNotNull);
    expect(events, hasLength(1));
    expect(events.first.eventType, 'medication_skipped');
    expect(events.first.metadataJson['medication_name'], 'Mesalamine');

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'duplicate detection prevents accidental re-entry within 5 minutes',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_medication_logging_dup_detect',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(repository: repository);
      await profileService.saveProfile(
        const UserProfile(
          medications: [MedicationEntry(name: 'Humira', dose: '40 mg')],
        ),
      );

      final service = MedicationLoggingService(
        repository: repository,
        profileService: profileService,
        nowProvider: () => DateTime.parse('2026-05-09T08:00:00Z'),
      );

      // First entry
      final first = await service.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: 'medication_taken',
          medicationName: 'Humira',
          dose: '40 mg',
          loggedAt: DateTime.utc(2026, 5, 9, 8, 0),
          sourceTranscript: 'Took Humira',
          confidence: 0.95,
        ),
      );

      // Immediate duplicate (within 5 min)
      final second = await service.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: 'medication_taken',
          medicationName: 'Humira',
          dose: '40 mg',
          loggedAt: DateTime.utc(2026, 5, 9, 8, 2),
          sourceTranscript: 'Took Humira',
          confidence: 0.95,
        ),
      );

      expect(first.isDuplicate, isFalse);
      expect(second.isDuplicate, isTrue);
      expect(second.duplicateOfId, first.savedEvent.id);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'enhanced metadata dict includes schema version, confidence evolution',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_medication_logging_metadata',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(repository: repository);

      final service = MedicationLoggingService(
        repository: repository,
        profileService: profileService,
      );

      final result = await service.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: 'medication_taken',
          medicationName: 'Mesalamine',
          dose: '500 mg',
          schedule: 'daily',
          loggedAt: DateTime.utc(2026, 5, 9, 9, 0),
          sourceTranscript: 'Took mesalamine',
          confidence: 0.9,
          requiresClarification: false,
        ),
      );

      final metadata = result.savedEvent.metadataJson;
      expect(metadata['schema_version'], 2);
      expect(metadata['initial_parsing_confidence'], 0.9);
      expect(metadata['final_user_confidence'], 0.9);
      expect(metadata['user_confirmed'], isTrue);
      expect(metadata['is_duplicate_of'], isFalse);
      expect(metadata['adherence_indicator'], 'on_time');

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('RAG status tracking returns detailed transaction info', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_medication_logging_rag_status',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final profileService = ProfileService(repository: repository);

    final service = MedicationLoggingService(
      repository: repository,
      profileService: profileService,
    );

    final result = await service.saveConfirmedDraft(
      MedicationLoggingDraft(
        eventType: 'medication_skipped',
        medicationName: 'Azathioprine',
        loggedAt: DateTime.utc(2026, 5, 9, 10, 0),
        sourceTranscript: 'Skipped AZA today',
        confidence: 0.8,
      ),
    );

    // When RAG is not configured, ragStatus is set to a fallback value
    expect(result.ragStatus.isNotEmpty, isTrue);
    expect(result.isDuplicate, isFalse);
    // ragTransactionId may be empty if RAG service not configured
    // but the result fields are properly populated

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'adherence indicator correctly infers from event type and timing',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_medication_logging_adherence',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(repository: repository);

      final service = MedicationLoggingService(
        repository: repository,
        profileService: profileService,
      );

      final taken = await service.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: 'medication_taken',
          medicationName: 'Prednisone',
          loggedAt: DateTime.utc(2026, 5, 9, 8, 0),
          sourceTranscript: 'Took prednisone',
          confidence: 1.0,
        ),
      );

      final skipped = await service.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: 'medication_skipped',
          medicationName: 'Infliximab',
          loggedAt: DateTime.utc(2026, 5, 9, 9, 0),
          sourceTranscript: 'Missed infliximab',
          confidence: 1.0,
        ),
      );

      expect(taken.savedEvent.metadataJson['adherence_indicator'], 'on_time');
      expect(skipped.savedEvent.metadataJson['adherence_indicator'], 'skipped');

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('medication memory text is structured for RAG retrieval', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_medication_logging_rag_text',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final profileService = ProfileService(repository: repository);

    final service = MedicationLoggingService(
      repository: repository,
      profileService: profileService,
    );

    final result = await service.saveConfirmedDraft(
      MedicationLoggingDraft(
        eventType: 'medication_taken',
        medicationName: 'Vedolizumab',
        dose: '300 mg IV',
        schedule: 'every 8 weeks',
        notes: 'Infusion at clinic',
        loggedAt: DateTime.utc(2026, 5, 9, 11, 0),
        sourceTranscript: 'Had vedolizumab infusion',
        confidence: 0.95,
      ),
    );

    // Note: RAG text is generated internally; here we verify the entry was saved
    // In a full integration test, we'd verify the RAG corpus contains structured text
    expect(result.savedEvent.notes, contains('Took medication'));
    expect(result.savedEvent.notes, contains('Vedolizumab'));

    await database.close();
    await tempRoot.delete(recursive: true);
  });
}
