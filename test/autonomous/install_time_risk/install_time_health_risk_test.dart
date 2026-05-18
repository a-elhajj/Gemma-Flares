@Tags(['slow'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';

import '../helpers/autonomous_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AutonomousTestHarness harness;

  tearDown(() async {
    await harness.dispose();
  });

  test(
    'install setup can produce same-day flare risk from Apple Health history',
    () async {
      final now = DateTime.utc(2026, 4, 20, 10);
      harness = await AutonomousTestHarness.create(
        healthBridge: TestHealthBridge.authorized(
          samplesByMetric: buildAppleWatchBackfillSamples(
            now: now,
            days: 30,
            deterioratingTail: true,
          ),
        ),
      );

      final authorization =
          await AppServices.healthSyncService.requestAuthorization(
        metrics: HealthSyncService.allProductionMetrics,
      );
      expect(authorization.status, 'success');
      expect(
        harness.healthBridge.authorizationRequests.single,
        containsAll(HealthSyncService.tier1Metrics),
      );

      final result = await AppServices.healthSyncService.runInitialBackfill(
        metrics: HealthSyncService.tier1Metrics,
        now: now,
        lookback: const Duration(days: 30),
      );

      expect(result.hasFailures, isFalse);
      expect(result.inserted, greaterThan(100));
      expect(
        harness.healthBridge.fetchRequests.map((r) => r.metricType),
        containsAll(HealthSyncService.tier1Metrics),
      );

      final syncState = await AppServices.wearableSampleRepository.getSyncState(
        'apple_health',
      );
      final latestScore =
          await AppServices.wearableSampleRepository.getLatestFlareRiskScore();
      final snapshot =
          await AppServices.dashboardSnapshotService.loadDashboardSnapshot();

      expect(syncState?.lastBackfillStart, isNotNull);
      expect(latestScore, isNotNull);
      expect(latestScore!.riskScore, greaterThan(0));
      expect(latestScore.confidenceScore, greaterThan(50));
      expect(snapshot.latestScore, isNotNull);
      expect(
        snapshot.baselineStatusLabel.toLowerCase(),
        isNot(contains('none')),
      );
    },
  );

  test(
    'install setup degrades confidence when Apple Health history is sparse',
    () async {
      final now = DateTime.utc(2026, 4, 20, 10);
      harness = await AutonomousTestHarness.create(
        healthBridge: TestHealthBridge.authorized(
          samplesByMetric: buildAppleWatchBackfillSamples(now: now, days: 5),
        ),
      );

      await AppServices.healthSyncService.requestAuthorization(
        metrics: HealthSyncService.allProductionMetrics,
      );
      await AppServices.healthSyncService.runInitialBackfill(
        metrics: HealthSyncService.tier1Metrics,
        now: now,
        lookback: const Duration(days: 30),
      );

      final latestScore =
          await AppServices.wearableSampleRepository.getLatestFlareRiskScore();
      final opened = await harness.database.open();
      final baselineRows = await opened.query('baseline_snapshots');

      expect(latestScore, isNotNull);
      expect(latestScore!.confidenceScore, lessThan(60));
      expect(
        baselineRows.last['readiness_state'],
        isIn(['not_ready', 'low_confidence']),
      );
    },
  );

  test(
    'install setup does not fabricate risk when Health access is denied',
    () async {
      harness = await AutonomousTestHarness.create(
        healthBridge: TestHealthBridge.denied(),
      );

      final authorization =
          await AppServices.healthSyncService.requestAuthorization(
        metrics: HealthSyncService.allProductionMetrics,
      );

      expect(authorization.status, 'denied');
      expect(harness.healthBridge.fetchRequests, isEmpty);
      final latestScore =
          await AppServices.wearableSampleRepository.getLatestFlareRiskScore();
      expect(latestScore, isNull);
    },
  );
}
