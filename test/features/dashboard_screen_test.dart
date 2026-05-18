import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/app_readiness_service.dart';
import 'package:gemma_flares/core/services/dashboard_snapshot_service.dart';
import 'package:gemma_flares/features/dashboard/dashboard_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DashboardSnapshotService originalSnapshotService;

  setUp(() {
    AppServices.configureForTesting();
    originalSnapshotService = AppServices.dashboardSnapshotService;
    AppServices.dashboardSnapshotService = _FakeDashboardSnapshotService();
  });

  tearDown(() {
    AppServices.resetToDefaults();
    AppServices.dashboardSnapshotService = originalSnapshotService;
  });

  testWidgets('today is simplified with check-in card and no technical tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DashboardScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('How are you feeling today?'), findsOneWidget);
    expect(find.text('Ask Gemma Flares'), findsOneWidget);
    expect(find.textContaining('I can explain today’s score'), findsOneWidget);

    expect(find.text('Recovery signal'), findsNothing);
    expect(find.text('Sleep pattern'), findsNothing);
    expect(find.text('Activity pattern'), findsNothing);
    expect(find.text('Health permissions'), findsNothing);
    expect(find.text('Sync freshness'), findsNothing);
  });

  testWidgets('shows updating banner while open-ready refresh is running', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            readinessState: AppReadinessState(
              phase: 'refreshing',
              isRefreshing: true,
              reason: 'app_launch',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.textContaining('Updating your latest Health data'),
      findsOneWidget,
    );
  });
}

class _NoopRepository extends WearableSampleRepository {
  _NoopRepository() : super(database: AppDatabase());
}

class _FakeDashboardSnapshotService extends DashboardSnapshotService {
  _FakeDashboardSnapshotService() : super(repository: _NoopRepository());

  @override
  Future<DashboardSnapshot> loadDashboardSnapshot() async {
    final now = DateTime.utc(2026, 4, 18, 12);
    return DashboardSnapshot(
      latestScore: FlareRiskScoreRecord(
        dateLocal: '2026-04-18',
        riskScore: 64,
        riskBand: 'elevated',
        confidenceScore: 78,
        contributionJson: const {'hrv_points': 12},
        featureSnapshotJson: const {'hrv_sdnn_mean': 38},
        modelVersion: 'risk_v2_context_adjusted',
        createdAt: now,
      ),
      latestSummary: null,
      latestBaseline: null,
      syncState: null,
      trendCards: const [],
      driverChips: const [
        DriverChipSnapshot(label: 'HRV drift', valueLabel: '-12%', points: 12),
      ],
      scoreTrend: const [52, 64],
      isSyncStale: false,
      syncFreshnessLabel: 'Updated recently.',
      syncWarningLabel: null,
      baselineStatusLabel: 'Baseline built from recent data.',
      recommendedAction: 'Keep hydration and symptom checks consistent today.',
      latestSymptomSummary: 'Latest symptom: mild abdominal pain.',
      checkinStatusLabel: 'Daily check-in not yet submitted today.',
      earlyWarningOutlook: const [
        OutlookPointSnapshot(
          horizonDays: 7,
          label: '7d',
          probability: 0.34,
          trainingSamples: 22,
          isLearning: false,
        ),
      ],
    );
  }
}
