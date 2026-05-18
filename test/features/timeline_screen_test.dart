import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/dashboard_snapshot_service.dart';
import 'package:gemma_flares/features/timeline/timeline_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppServices.configureForTesting();
    AppServices.dashboardSnapshotService = _FakeTimelineSnapshotService();
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  testWidgets('timeline filters hide non-selected categories', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TimelineScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Risk elevated'), findsOneWidget);
    expect(find.text('Symptom logged'), findsOneWidget);

    await tester.tap(find.text('Symptoms'));
    await tester.pumpAndSettle();

    expect(find.text('Symptom logged'), findsOneWidget);
    expect(find.text('Risk elevated'), findsNothing);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(find.text('Risk elevated'), findsOneWidget);
  });
}

class _NoopRepository extends WearableSampleRepository {
  _NoopRepository() : super(database: AppDatabase());
}

class _FakeTimelineSnapshotService extends DashboardSnapshotService {
  _FakeTimelineSnapshotService() : super(repository: _NoopRepository());

  @override
  Future<List<TimelineGroup>> loadTimelineGroups({int dayLimit = 10}) async {
    return const [
      TimelineGroup(
        dateLocal: '2026-05-09',
        items: [
          TimelineItem(
            title: 'Risk elevated',
            detail: '42/100 risk score',
            tone: 'moderate',
            category: 'risk',
          ),
          TimelineItem(
            title: 'Symptom logged',
            detail: 'urgency 6/10',
            tone: 'symptom',
            category: 'symptom',
          ),
        ],
      ),
    ];
  }
}
