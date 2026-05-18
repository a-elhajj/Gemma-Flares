import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/flare_label_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/features/checkin/checkin_screen.dart';
import 'package:gemma_flares/features/health/lab_entry_screen.dart';
import 'package:gemma_flares/features/profile/profile_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWearableSampleRepository repository;
  late _FakeProfileService profileService;
  late _FakeFlareLabelService flareLabelService;

  setUp(() async {
    repository = _FakeWearableSampleRepository();
    profileService = _FakeProfileService(repository);
    flareLabelService = _FakeFlareLabelService(repository);
    AppServices.configureForTesting(
      repositoryOverride: repository,
      profileServiceOverride: profileService,
      flareLabelServiceOverride: flareLabelService,
    );
    await AppServices.wearableSampleRepository.clearLocalUserData();
  });

  tearDown(() async {
    AppServices.resetToDefaults();
  });

  testWidgets('profile screen saves profile details', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: _PushHost(childBuilder: (_) => const ProfileScreen()),
      ),
    );

    await tester.tap(find.text('Open'));
    await _pumpUntilVisible(tester, find.text('Save profile'));

    await tester.enterText(find.byType(TextField).at(0), '170');
    await tester.enterText(find.byType(TextField).at(1), '70');
    await tester.enterText(find.byType(TextField).at(2), '2018');
    await tester.pump();
    await _scrollIntoView(tester, find.text("Crohn's"));
    await tester.tap(find.text("Crohn's"));
    await tester.pump();

    expect(find.text('BMI: 24.2'), findsOneWidget);

    await _scrollIntoView(tester, find.text('Save profile'));
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);

    final profile = await AppServices.profileService.loadProfile();
    expect(profile.heightCm, 170.0);
    expect(profile.weightKg, 70.0);
    expect(profile.diseaseType, 'CD');
    expect(profile.diagnosisYear, 2018);
  });

  testWidgets('check-in screen submits a remission survey', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: CheckInScreen()),
      ),
    );
    await _pumpUntilVisible(tester, find.text('Daily Check-In'));

    final submitButton = find.widgetWithText(FilledButton, 'Submit check-in');
    await _scrollIntoView(tester, submitButton);
    await tester.ensureVisible(submitButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(submitButton, findsOneWidget);

    await tester.tap(submitButton);
    await _pumpUntil(tester, () async {
      final surveys = await AppServices.wearableSampleRepository
          .getRecentPro2Surveys(limit: 5);
      return surveys.isNotEmpty;
    });

    final surveys = await AppServices.wearableSampleRepository
        .getRecentPro2Surveys(limit: 5);
    expect(surveys, hasLength(1));
    expect(surveys.single.diseaseType, 'CD');
    expect(surveys.single.scoreVersion, Pro2SurveyRecord.cdV2Pain2Stool1);
    expect(surveys.single.isFlare, isFalse);
    expect(surveys.single.pro2Score, 0);
    final evidence = IbdCheckInService.evidenceForSurvey(surveys.single);
    expect(evidence['summary'], contains('Crohn'));
    expect(evidence['completion_score'], 0.5);
  });

  testWidgets('first check-in defaults disease type from profile', (
    tester,
  ) async {
    await AppServices.profileService.saveProfile(
      const UserProfile(diseaseType: 'UC'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: CheckInScreen()),
      ),
    );
    await _pumpUntilVisible(tester, find.text('Daily Check-In'));
    await _pumpUntilVisible(tester, find.text('Colitis basics'));

    final submitButton = find.widgetWithText(FilledButton, 'Submit check-in');
    await _scrollIntoView(tester, submitButton);
    await tester.ensureVisible(submitButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(submitButton);

    await _pumpUntil(tester, () async {
      final surveys = await AppServices.wearableSampleRepository
          .getRecentPro2Surveys(limit: 5);
      return surveys.isNotEmpty;
    });

    final surveys = await AppServices.wearableSampleRepository
        .getRecentPro2Surveys(limit: 5);
    expect(surveys, hasLength(1));
    expect(surveys.single.diseaseType, 'UC');
  });

  testWidgets(
    'check-in screen submits a severe Crohn\'s flare under v2 scoring',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(body: CheckInScreen()),
        ),
      );
      await _pumpUntilVisible(tester, find.text('Daily Check-In'));

      await tester.tap(find.text('Severe'));
      await tester.pump();
      await tester.tap(find.text('7+'));
      await tester.pump();

      final submitButton = find.widgetWithText(FilledButton, 'Submit check-in');
      await _scrollIntoView(tester, submitButton);
      await tester.ensureVisible(submitButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(submitButton);
      await _pumpUntil(tester, () async {
        final surveys = await AppServices.wearableSampleRepository
            .getRecentPro2Surveys(limit: 5);
        return surveys.isNotEmpty;
      });

      final surveys = await AppServices.wearableSampleRepository
          .getRecentPro2Surveys(limit: 5);
      expect(surveys, hasLength(1));
      expect(surveys.single.pro2Score, 9);
      expect(surveys.single.isFlare, isTrue);
      expect(surveys.single.scoreVersion, Pro2SurveyRecord.cdV2Pain2Stool1);
      final evidence = IbdCheckInService.evidenceForSurvey(surveys.single);
      expect((evidence['core'] as Map)['loose_stool_bucket'], 3);
    },
  );

  testWidgets('check-in screen keeps details optional and disease-specific', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: CheckInScreen()),
      ),
    );
    await _pumpUntilVisible(tester, find.text('Daily Check-In'));

    expect(find.text("Crohn's basics"), findsOneWidget);
    expect(find.text('Belly pain today?'), findsOneWidget);
    expect(find.text('Loose or watery stools today?'), findsOneWidget);
    expect(find.text('Bloating today?'), findsNothing);

    await tester.tap(find.text('Add details'));
    await tester.pumpAndSettle();

    expect(find.text('Bloating today?'), findsOneWidget);
    expect(find.text('Any pain or drainage around the anus?'), findsOneWidget);

    await tester.tap(find.text('Colitis'));
    await tester.pumpAndSettle();

    expect(find.text('Colitis basics'), findsOneWidget);
    expect(find.text('Any bleeding today?'), findsOneWidget);
    expect(
      find.text('Feeling like you could not fully empty?'),
      findsOneWidget,
    );
  });

  testWidgets('lab entry screen saves a CRP result and shows it in history', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: LabEntryScreen(),
      ),
    );
    await _pumpUntilVisible(tester, find.text('Save result'));

    await tester.enterText(find.byType(TextField).first, '7.2');
    await tester.pump();
    await _scrollIntoView(tester, find.text('Save result'));
    await tester.tap(find.text('Save result'));
    await tester.pumpAndSettle();

    final labs = await AppServices.wearableSampleRepository.getLabValues();
    expect(labs, hasLength(1));
    expect(labs.single.labType, 'crp');
    expect(labs.single.valueNumeric, 7.2);
    expect(find.text('Lab history'), findsOneWidget);
  });
}

Future<void> _pumpUntilVisible(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 40,
}) async {
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for the expected widget to appear.');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  int maxPumps = 60,
}) async {
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (await condition()) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for the expected condition.');
}

Future<void> _scrollIntoView(WidgetTester tester, Finder finder) {
  return tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
}

class _PushHost extends StatelessWidget {
  const _PushHost({required this.childBuilder});

  final WidgetBuilder childBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: childBuilder));
          },
          child: const Text('Open'),
        ),
      ),
    );
  }
}

class _FakeWearableSampleRepository extends WearableSampleRepository {
  _FakeWearableSampleRepository() : super(database: AppDatabase());

  final List<LabValueRecord> _labValues = [];
  final List<Pro2SurveyRecord> _pro2Surveys = [];
  final List<FlareLabelRecord> _flareLabels = [];
  int _nextLabId = 1;
  int _nextSurveyId = 1;

  @override
  Future<void> clearLocalUserData() async {
    _labValues.clear();
    _pro2Surveys.clear();
    _flareLabels.clear();
    _nextLabId = 1;
    _nextSurveyId = 1;
  }

  @override
  Future<int> upsertLabValue(LabValueRecord record) async {
    final id = record.id ?? _nextLabId++;
    _labValues.removeWhere((item) => item.id == id);
    _labValues.add(
      LabValueRecord(
        id: id,
        drawnDate: record.drawnDate,
        labType: record.labType,
        valueNumeric: record.valueNumeric,
        unit: record.unit,
        referenceHigh: record.referenceHigh,
        labName: record.labName,
        orderingProvider: record.orderingProvider,
        notes: record.notes,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt,
      ),
    );
    return id;
  }

  @override
  Future<void> deleteLabValue(int id) async {
    _labValues.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<LabValueRecord>> getLabValues({String? labType}) async {
    final results = labType == null
        ? _labValues
        : _labValues.where((item) => item.labType == labType).toList();
    results.sort((a, b) => b.drawnDate.compareTo(a.drawnDate));
    return List<LabValueRecord>.from(results);
  }

  @override
  Future<List<LabValueRecord>> getLabValuesInRange(
    String startDate,
    String endDate,
  ) async {
    return _labValues
        .where((item) => item.drawnDate.compareTo(startDate) >= 0)
        .where((item) => item.drawnDate.compareTo(endDate) <= 0)
        .toList(growable: false);
  }

  @override
  Future<int> insertPro2Survey(Pro2SurveyRecord record) async {
    final id = record.id ?? _nextSurveyId++;
    _pro2Surveys.add(
      Pro2SurveyRecord(
        id: id,
        surveyDate: record.surveyDate,
        diseaseType: record.diseaseType,
        cdAbdominalPain: record.cdAbdominalPain,
        cdStoolFrequency: record.cdStoolFrequency,
        ucRectalBleeding: record.ucRectalBleeding,
        ucStoolFrequency: record.ucStoolFrequency,
        pro2Score: record.pro2Score,
        isFlare: record.isFlare,
        scoreVersion: record.scoreVersion,
        notes: record.notes,
        createdAt: record.createdAt,
      ),
    );
    return id;
  }

  @override
  Future<List<Pro2SurveyRecord>> getRecentPro2Surveys({int limit = 7}) async {
    final results = List<Pro2SurveyRecord>.from(_pro2Surveys)
      ..sort((a, b) => b.surveyDate.compareTo(a.surveyDate));
    return results.take(limit).toList(growable: false);
  }

  @override
  Future<List<Pro2SurveyRecord>> getPro2SurveysInRange(
    String startDate,
    String endDate,
  ) async {
    return _pro2Surveys
        .where((item) => item.surveyDate.compareTo(startDate) >= 0)
        .where((item) => item.surveyDate.compareTo(endDate) <= 0)
        .toList(growable: false);
  }

  @override
  Future<List<DailySummaryRecord>> getDailySummaries({int? limit}) async {
    return const [];
  }

  @override
  Future<DailySummaryRecord?> getLatestDailySummary() async {
    return null;
  }

  @override
  Future<List<EndoscopyRecord>> getEndoscopyRecordsInRange(
    String startDate,
    String endDate,
  ) async {
    return const [];
  }

  @override
  Future<void> upsertFlareLabel(FlareLabelRecord record) async {
    _flareLabels.removeWhere((item) => item.labelDate == record.labelDate);
    _flareLabels.add(record);
  }
}

class _FakeProfileService extends ProfileService {
  _FakeProfileService(WearableSampleRepository repository)
      : super(repository: repository);

  UserProfile _profile = UserProfile.empty;

  @override
  Future<UserProfile> loadProfile() async => _profile;

  @override
  Future<void> saveProfile(UserProfile profile) async {
    _profile = profile;
  }

  @override
  Future<void> clearProfile() async {
    _profile = UserProfile.empty;
  }
}

class _FakeFlareLabelService extends FlareLabelService {
  _FakeFlareLabelService(WearableSampleRepository repository)
      : super(repository: repository);

  @override
  Future<FlareLabelComputationResult> recomputeLabels({
    String? startDate,
    String? endDate,
  }) async {
    return const FlareLabelComputationResult(
      recomputedDates: [],
      inflammatoryCount: 0,
      symptomaticCount: 0,
      combinedCount: 0,
    );
  }
}
