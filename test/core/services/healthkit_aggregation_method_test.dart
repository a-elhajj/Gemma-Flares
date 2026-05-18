// ignore_for_file: lines_longer_than_80_chars
// Tests for WearableAggregationService.executeWithMethod —
// verifies all six override methods (average, sum/total, max, min, median, latest)
// plus the null/defaultForMetric pass-through, empty data handling, and unit
// conversion (km) across the same stub repository used in exhaustive tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/wearable_aggregation_service.dart';

// ---------------------------------------------------------------------------
// Minimal stub repository — returns a fixed list of rows when queried.
// Each row is a Map matching what the real SQLite query returns.
// ---------------------------------------------------------------------------

class _StubRepo implements WearableSampleRepository {
  _StubRepo({
    required List<Map<String, Object?>> rows,
    this.sources = const ['Apple Watch'],
  }) : _rows = List.unmodifiable(rows);

  final List<Map<String, Object?>> _rows;
  final List<String> sources;

  @override
  Future<List<Map<String, Object?>>> getMetricRowsForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async => _rows;

  @override
  Future<List<String>> getDistinctSourcesForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async => sources;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _EmptyRepo implements WearableSampleRepository {
  @override
  Future<List<Map<String, Object?>>> getMetricRowsForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async => const [];

  @override
  Future<List<String>> getDistinctSourcesForWindow({
    required String dbName,
    required String startDate,
    required String endDate,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _kWindow = WearableWindow(
  grain: WearableGrain.week,
  startDate: '2025-01-06',
  endDate: '2025-01-12',
  label: 'last week',
);

const _kHrvSpec = WearableMetricSpec(
  type: HealthMetricType.heartRateVariabilitySDNN,
  dbName: 'hrv_ms',
  displayName: 'HRV',
  unit: 'ms',
  rule: WearableAggRule.avgWeighted,
  phrases: ['hrv'],
);

const _kStepsSpec = WearableMetricSpec(
  type: HealthMetricType.stepCount,
  dbName: 'steps',
  displayName: 'steps',
  unit: 'steps',
  rule: WearableAggRule.sum,
  phrases: ['steps'],
);

const _kDistanceSpec = WearableMetricSpec(
  type: HealthMetricType.distanceWalkingRunning,
  dbName: 'walking_running_distance_m',
  displayName: 'distance',
  unit: 'km',
  rule: WearableAggRule.sum,
  phrases: ['distance walked'],
);

const _kHeartRateSpec = WearableMetricSpec(
  type: HealthMetricType.heartRate,
  dbName: 'heart_rate',
  displayName: 'heart rate',
  unit: 'bpm',
  rule: WearableAggRule.avgWeighted,
  phrases: ['heart rate'],
);

/// Builds a plan from spec + shared window.
WearableQueryPlan _plan(WearableMetricSpec spec) =>
    WearableQueryPlan(metric: spec, window: _kWindow);

/// Builds a service backed by a fixed row list.
WearableAggregationService _svcWith(List<Map<String, Object?>> rows) =>
    WearableAggregationService(repository: _StubRepo(rows: rows));

/// Builds a service backed by an empty repository.
WearableAggregationService _emptySvc() =>
    WearableAggregationService(repository: _EmptyRepo());

// Seven days of HRV data; avg_value = daily mean, max/min = day envelope.
// avg values: 45, 50, 55, 40, 60, 35, 70  → sum=355, mean≈50.71, median=50
// max values: 50, 58, 62, 48, 70, 42, 80  → max=80
// min values: 40, 45, 50, 35, 55, 30, 62  → min=30
final _kHrvRows = List<Map<String, Object?>>.unmodifiable([
  {'date': '2025-01-06', 'avg_value': 45.0, 'min_value': 40.0, 'max_value': 50.0, 'total_value': 45.0, 'sample_count': 10},
  {'date': '2025-01-07', 'avg_value': 50.0, 'min_value': 45.0, 'max_value': 58.0, 'total_value': 50.0, 'sample_count': 12},
  {'date': '2025-01-08', 'avg_value': 55.0, 'min_value': 50.0, 'max_value': 62.0, 'total_value': 55.0, 'sample_count': 11},
  {'date': '2025-01-09', 'avg_value': 40.0, 'min_value': 35.0, 'max_value': 48.0, 'total_value': 40.0, 'sample_count': 9},
  {'date': '2025-01-10', 'avg_value': 60.0, 'min_value': 55.0, 'max_value': 70.0, 'total_value': 60.0, 'sample_count': 14},
  {'date': '2025-01-11', 'avg_value': 35.0, 'min_value': 30.0, 'max_value': 42.0, 'total_value': 35.0, 'sample_count': 8},
  {'date': '2025-01-12', 'avg_value': 70.0, 'min_value': 62.0, 'max_value': 80.0, 'total_value': 70.0, 'sample_count': 16},
]);

// Steps: total_value per day (no avg_value — matches sum rule).
// totals: 8000, 10000, 12000, 6000, 11000, 9000, 13000 → sum=69000
final _kStepsRows = List<Map<String, Object?>>.unmodifiable([
  {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 8000.0, 'sample_count': 1},
  {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 10000.0, 'sample_count': 1},
  {'date': '2025-01-08', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 12000.0, 'sample_count': 1},
  {'date': '2025-01-09', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 6000.0, 'sample_count': 1},
  {'date': '2025-01-10', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 11000.0, 'sample_count': 1},
  {'date': '2025-01-11', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 9000.0, 'sample_count': 1},
  {'date': '2025-01-12', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 13000.0, 'sample_count': 1},
]);

// Distance in metres: totals 1000, 2000, 3000, 1500, 4000, 500, 2500 = 14500 m = 14.5 km
final _kDistanceRows = List<Map<String, Object?>>.unmodifiable([
  {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 1000.0, 'sample_count': 1},
  {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 2000.0, 'sample_count': 1},
  {'date': '2025-01-08', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 3000.0, 'sample_count': 1},
  {'date': '2025-01-09', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 1500.0, 'sample_count': 1},
  {'date': '2025-01-10', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 4000.0, 'sample_count': 1},
  {'date': '2025-01-11', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 500.0, 'sample_count': 1},
  {'date': '2025-01-12', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 2500.0, 'sample_count': 1},
]);

// Single-row dataset for deterministic latest/edge-case tests.
final _kSingleHrvRow = List<Map<String, Object?>>.unmodifiable([
  {'date': '2025-01-12', 'avg_value': 55.0, 'min_value': 50.0, 'max_value': 65.0, 'total_value': 55.0, 'sample_count': 5},
]);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── null / defaultForMetric pass-through ──────────────────────────────────

  group('executeWithMethod — pass-through cases', () {
    test('null method delegates to execute() (natural rule)', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), null);
      // Natural rule for HRV is avgWeighted — just check it returns a value.
      expect(result.value, isNotNull);
    });

    test('empty string delegates to execute()', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), '');
      expect(result.value, isNotNull);
    });

    test('defaultForMetric delegates to execute()', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'defaultForMetric');
      expect(result.value, isNotNull);
    });

    test('unknown method string falls back to execute()', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'geometric_mean');
      expect(result.value, isNotNull);
    });
  });

  // ── empty data ────────────────────────────────────────────────────────────

  group('executeWithMethod — empty repository', () {
    for (final method in ['average', 'sum', 'total', 'max', 'min', 'median', 'latest']) {
      test('method "$method" with no rows returns value=null', () async {
        final svc = _emptySvc();
        final result = await svc.executeWithMethod(_plan(_kHrvSpec), method);
        expect(result.value, isNull);
        expect(result.sampleDays, equals(0));
      });
    }

    test('metric and window preserved when empty', () async {
      final svc = _emptySvc();
      final plan = _plan(_kHrvSpec);
      final result = await svc.executeWithMethod(plan, 'average');
      expect(result.metric, equals(_kHrvSpec));
      expect(result.window, equals(_kWindow));
    });
  });

  // ── average ───────────────────────────────────────────────────────────────

  group('executeWithMethod — average', () {
    test('arithmetic mean of avg_value across 7 days', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      // (45+50+55+40+60+35+70)/7 = 355/7 ≈ 50.714
      expect(result.value, closeTo(50.714, 0.01));
    });

    test('"mean" alias gives same result as "average"', () async {
      final svc1 = _svcWith(_kHrvRows);
      final svc2 = _svcWith(_kHrvRows);
      final r1 = await svc1.executeWithMethod(_plan(_kHrvSpec), 'average');
      final r2 = await svc2.executeWithMethod(_plan(_kHrvSpec), 'mean');
      expect(r1.value, closeTo(r2.value!, 0.0001));
    });

    test('single-row average returns that row\'s avg_value', () async {
      final svc = _svcWith(_kSingleHrvRow);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      expect(result.value, closeTo(55.0, 0.001));
    });

    test('rows with null avg_value are skipped in count', () async {
      // Mix rows: first two have null avg_value, last has avg_value=60
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 100.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 200.0, 'sample_count': 1},
        {'date': '2025-01-08', 'avg_value': 60.0, 'min_value': 55.0, 'max_value': 65.0, 'total_value': 60.0, 'sample_count': 5},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      // Only 1 valid row: mean = 60.0
      expect(result.value, closeTo(60.0, 0.001));
    });

    test('all null avg_value rows → value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'total_value': 100.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': null, 'total_value': 200.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      expect(result.value, isNull);
    });
  });

  // ── sum / total ───────────────────────────────────────────────────────────

  group('executeWithMethod — sum', () {
    test('cumulative sum of total_value across 7 days', () async {
      final svc = _svcWith(_kStepsRows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'sum');
      // 8000+10000+12000+6000+11000+9000+13000 = 69000
      expect(result.value, closeTo(69000.0, 0.1));
    });

    test('"total" alias gives same result as "sum"', () async {
      final svc1 = _svcWith(_kStepsRows);
      final svc2 = _svcWith(_kStepsRows);
      final r1 = await svc1.executeWithMethod(_plan(_kStepsSpec), 'sum');
      final r2 = await svc2.executeWithMethod(_plan(_kStepsSpec), 'total');
      expect(r1.value, closeTo(r2.value!, 0.01));
    });

    test('distance metric sums in km (divides by 1000)', () async {
      final svc = _svcWith(_kDistanceRows);
      final result = await svc.executeWithMethod(_plan(_kDistanceSpec), 'sum');
      // 14500 m → 14.5 km
      expect(result.value, closeTo(14.5, 0.01));
    });

    test('non-km metric does NOT divide by 1000', () async {
      final svc = _svcWith(_kStepsRows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'sum');
      // steps unit is 'steps', not 'km'
      expect(result.value, closeTo(69000.0, 0.1));
    });

    test('single-row sum returns that row\'s total_value', () async {
      final rows = [
        {'date': '2025-01-12', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 7500.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'sum');
      expect(result.value, closeTo(7500.0, 0.01));
    });
  });

  // ── max ───────────────────────────────────────────────────────────────────

  group('executeWithMethod — max', () {
    test('returns largest max_value across all rows', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'max');
      // max_values: 50, 58, 62, 48, 70, 42, 80 → max = 80
      expect(result.value, closeTo(80.0, 0.001));
    });

    test('single-row max returns its max_value', () async {
      final svc = _svcWith(_kSingleHrvRow);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'max');
      expect(result.value, closeTo(65.0, 0.001));
    });

    test('falls back to total_value when max_value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 12000.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 9000.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'max');
      expect(result.value, closeTo(12000.0, 0.01));
    });

    test('all null max and total values → value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': 50.0, 'min_value': 45.0, 'max_value': null, 'total_value': null, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'max');
      expect(result.value, isNull);
    });

    test('max picks the true maximum (not the last row)', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': 60.0, 'min_value': 55.0, 'max_value': 70.0, 'total_value': 60.0, 'sample_count': 5},
        {'date': '2025-01-07', 'avg_value': 80.0, 'min_value': 75.0, 'max_value': 90.0, 'total_value': 80.0, 'sample_count': 5},
        {'date': '2025-01-08', 'avg_value': 40.0, 'min_value': 35.0, 'max_value': 45.0, 'total_value': 40.0, 'sample_count': 5},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'max');
      expect(result.value, closeTo(90.0, 0.001));
    });
  });

  // ── min ───────────────────────────────────────────────────────────────────

  group('executeWithMethod — min', () {
    test('returns smallest min_value across all rows', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'min');
      // min_values: 40, 45, 50, 35, 55, 30, 62 → min = 30
      expect(result.value, closeTo(30.0, 0.001));
    });

    test('single-row min returns its min_value', () async {
      final svc = _svcWith(_kSingleHrvRow);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'min');
      expect(result.value, closeTo(50.0, 0.001));
    });

    test('falls back to total_value when min_value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 12000.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 9000.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'min');
      expect(result.value, closeTo(9000.0, 0.01));
    });

    test('all null min and total values → value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': 50.0, 'min_value': null, 'max_value': 60.0, 'total_value': null, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'min');
      expect(result.value, isNull);
    });

    test('min picks the true minimum (not the first row)', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': 60.0, 'min_value': 55.0, 'max_value': 70.0, 'total_value': 60.0, 'sample_count': 5},
        {'date': '2025-01-07', 'avg_value': 80.0, 'min_value': 75.0, 'max_value': 90.0, 'total_value': 80.0, 'sample_count': 5},
        {'date': '2025-01-08', 'avg_value': 40.0, 'min_value': 20.0, 'max_value': 45.0, 'total_value': 40.0, 'sample_count': 5},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'min');
      expect(result.value, closeTo(20.0, 0.001));
    });
  });

  // ── median ────────────────────────────────────────────────────────────────

  group('executeWithMethod — median', () {
    test('odd count: middle element of sorted avg_values', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'median');
      // avg_values sorted: 35, 40, 45, 50, 55, 60, 70 → median = 50
      expect(result.value, closeTo(50.0, 0.001));
    });

    test('even count: average of two middle elements', () async {
      // avg_values: 40, 50, 60, 70 → sorted: 40, 50, 60, 70 → median = (50+60)/2 = 55
      final rows = [
        {'date': '2025-01-06', 'avg_value': 70.0, 'min_value': null, 'max_value': null, 'total_value': 70.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': 40.0, 'min_value': null, 'max_value': null, 'total_value': 40.0, 'sample_count': 1},
        {'date': '2025-01-08', 'avg_value': 60.0, 'min_value': null, 'max_value': null, 'total_value': 60.0, 'sample_count': 1},
        {'date': '2025-01-09', 'avg_value': 50.0, 'min_value': null, 'max_value': null, 'total_value': 50.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'median');
      expect(result.value, closeTo(55.0, 0.001));
    });

    test('single-row median returns that row value', () async {
      final svc = _svcWith(_kSingleHrvRow);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'median');
      expect(result.value, closeTo(55.0, 0.001));
    });

    test('falls back to total_value when avg_value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 100.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 300.0, 'sample_count': 1},
        {'date': '2025-01-08', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': 200.0, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'median');
      // sorted total_values: 100, 200, 300 → median = 200
      expect(result.value, closeTo(200.0, 0.01));
    });

    test('all null avg and total values → value is null', () async {
      final rows = [
        {'date': '2025-01-06', 'avg_value': null, 'min_value': 40.0, 'max_value': 60.0, 'total_value': null, 'sample_count': 1},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'median');
      expect(result.value, isNull);
    });

    test('median is order-independent (input order irrelevant)', () async {
      final rowsAsc = [
        {'date': '2025-01-06', 'avg_value': 10.0, 'total_value': 10.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': 20.0, 'total_value': 20.0, 'sample_count': 1},
        {'date': '2025-01-08', 'avg_value': 30.0, 'total_value': 30.0, 'sample_count': 1},
      ];
      final rowsDesc = [
        {'date': '2025-01-06', 'avg_value': 30.0, 'total_value': 30.0, 'sample_count': 1},
        {'date': '2025-01-07', 'avg_value': 10.0, 'total_value': 10.0, 'sample_count': 1},
        {'date': '2025-01-08', 'avg_value': 20.0, 'total_value': 20.0, 'sample_count': 1},
      ];
      final r1 = await _svcWith(rowsAsc).executeWithMethod(_plan(_kHrvSpec), 'median');
      final r2 = await _svcWith(rowsDesc).executeWithMethod(_plan(_kHrvSpec), 'median');
      expect(r1.value, closeTo(r2.value!, 0.001));
      expect(r1.value, closeTo(20.0, 0.001));
    });
  });

  // ── latest ────────────────────────────────────────────────────────────────

  group('executeWithMethod — latest', () {
    test('returns max_value from the first non-null row (newest first)', () async {
      // Rows passed DESC (repository guarantees this order).
      final rows = [
        {'date': '2025-01-12', 'avg_value': 70.0, 'min_value': 62.0, 'max_value': 80.0, 'total_value': 70.0, 'sample_count': 16},
        {'date': '2025-01-11', 'avg_value': 35.0, 'min_value': 30.0, 'max_value': 42.0, 'total_value': 35.0, 'sample_count': 8},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'latest');
      expect(result.value, closeTo(80.0, 0.001));
    });

    test('single-row latest returns max_value', () async {
      final svc = _svcWith(_kSingleHrvRow);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'latest');
      expect(result.value, closeTo(65.0, 0.001));
    });

    test('falls back to avg_value when max_value is null', () async {
      final rows = [
        {'date': '2025-01-12', 'avg_value': 55.0, 'min_value': 50.0, 'max_value': null, 'total_value': 55.0, 'sample_count': 5},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'latest');
      expect(result.value, closeTo(55.0, 0.001));
    });

    test('skips fully-null rows and picks next', () async {
      final rows = [
        {'date': '2025-01-12', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': null, 'sample_count': 0},
        {'date': '2025-01-11', 'avg_value': 48.0, 'min_value': 42.0, 'max_value': 55.0, 'total_value': 48.0, 'sample_count': 6},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'latest');
      expect(result.value, closeTo(55.0, 0.001));
    });

    test('all null rows → value is null', () async {
      final rows = [
        {'date': '2025-01-12', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': null, 'sample_count': 0},
        {'date': '2025-01-11', 'avg_value': null, 'min_value': null, 'max_value': null, 'total_value': null, 'sample_count': 0},
      ];
      final svc = _svcWith(rows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'latest');
      expect(result.value, isNull);
    });
  });

  // ── result metadata ───────────────────────────────────────────────────────

  group('executeWithMethod — result metadata', () {
    test('metric and window are preserved in result', () async {
      final svc = _svcWith(_kHrvRows);
      final plan = _plan(_kHrvSpec);
      final result = await svc.executeWithMethod(plan, 'average');
      expect(result.metric, equals(_kHrvSpec));
      expect(result.window, equals(_kWindow));
    });

    test('sampleDays equals number of returned rows', () async {
      final svc = _svcWith(_kHrvRows);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'max');
      expect(result.sampleDays, equals(7));
    });

    test('unit matches metric spec unit', () async {
      final svc = _svcWith(_kStepsRows);
      final result = await svc.executeWithMethod(_plan(_kStepsSpec), 'sum');
      expect(result.unit, equals('steps'));
    });

    test('km metric unit preserved after sum override', () async {
      final svc = _svcWith(_kDistanceRows);
      final result = await svc.executeWithMethod(_plan(_kDistanceSpec), 'sum');
      expect(result.unit, equals('km'));
    });

    test('sourceCount from repository sources list', () async {
      final rows = List<Map<String, Object?>>.from(_kHrvRows);
      final repo = _StubRepo(
        rows: rows,
        sources: ['Apple Watch', 'Oura Ring'],
      );
      final svc = WearableAggregationService(repository: repo);
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      expect(result.sourceCount, equals(2));
    });

    test('sourceCount is 0 for empty rows', () async {
      final svc = _emptySvc();
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'average');
      expect(result.sourceCount, equals(0));
    });

    test('sourceNames list is empty for empty rows', () async {
      final svc = _emptySvc();
      final result = await svc.executeWithMethod(_plan(_kHrvSpec), 'sum');
      expect(result.sourceNames, isEmpty);
    });
  });

  // ── WearableAggResult.confidenceTier ─────────────────────────────────────

  group('WearableAggResult.confidenceTier', () {
    WearableAggResult _make({
      required double? value,
      required int sourceCount,
      required int sampleDays,
    }) =>
        WearableAggResult(
          metric: _kHrvSpec,
          window: _kWindow,
          value: value,
          min: null,
          max: null,
          sampleDays: sampleDays,
          sourceCount: sourceCount,
        );

    test('value=null → "no_data"', () {
      expect(_make(value: null, sourceCount: 2, sampleDays: 7).confidenceTier,
          equals('no_data'));
    });

    test('sampleDays=0 → "no_data"', () {
      expect(_make(value: 50.0, sourceCount: 2, sampleDays: 0).confidenceTier,
          equals('no_data'));
    });

    test('sourceCount=0 → "no_data"', () {
      expect(_make(value: 50.0, sourceCount: 0, sampleDays: 7).confidenceTier,
          equals('no_data'));
    });

    test('2+ sources and 5+ days → "high"', () {
      expect(_make(value: 50.0, sourceCount: 2, sampleDays: 7).confidenceTier,
          equals('high'));
    });

    test('2+ sources and 5+ days (exactly 5 days) → "high"', () {
      expect(_make(value: 50.0, sourceCount: 2, sampleDays: 5).confidenceTier,
          equals('high'));
    });

    test('2 sources but 4 days → "medium"', () {
      expect(_make(value: 50.0, sourceCount: 2, sampleDays: 4).confidenceTier,
          equals('medium'));
    });

    test('1 source but 3+ days → "medium"', () {
      expect(_make(value: 50.0, sourceCount: 1, sampleDays: 3).confidenceTier,
          equals('medium'));
    });

    test('1 source and 1 day → "low"', () {
      expect(_make(value: 50.0, sourceCount: 1, sampleDays: 1).confidenceTier,
          equals('low'));
    });
  });

  // ── WearableComparisonResult ──────────────────────────────────────────────

  group('WearableComparisonResult', () {
    WearableAggResult _r(double? val) => WearableAggResult(
          metric: _kHrvSpec,
          window: _kWindow,
          value: val,
          min: null,
          max: null,
          sampleDays: 7,
        );

    test('delta = resultA.value - resultB.value', () {
      final cmp = WearableComparisonResult(
        metric: _kHrvSpec,
        resultA: _r(60.0),
        resultB: _r(50.0),
      );
      expect(cmp.delta, closeTo(10.0, 0.001));
    });

    test('delta is null when either value is null', () {
      expect(
        WearableComparisonResult(
          metric: _kHrvSpec,
          resultA: _r(null),
          resultB: _r(50.0),
        ).delta,
        isNull,
      );
      expect(
        WearableComparisonResult(
          metric: _kHrvSpec,
          resultA: _r(60.0),
          resultB: _r(null),
        ).delta,
        isNull,
      );
    });

    test('pctChange = (a - b) / b * 100', () {
      final cmp = WearableComparisonResult(
        metric: _kHrvSpec,
        resultA: _r(60.0),
        resultB: _r(50.0),
      );
      // (10 / 50) * 100 = 20%
      expect(cmp.pctChange, closeTo(20.0, 0.001));
    });

    test('pctChange is null when b is 0', () {
      final cmp = WearableComparisonResult(
        metric: _kHrvSpec,
        resultA: _r(60.0),
        resultB: _r(0.0),
      );
      expect(cmp.pctChange, isNull);
    });

    test('pctChange is null when either value is null', () {
      expect(
        WearableComparisonResult(
          metric: _kHrvSpec,
          resultA: _r(null),
          resultB: _r(50.0),
        ).pctChange,
        isNull,
      );
    });

    test('negative delta (regression) is correct', () {
      final cmp = WearableComparisonResult(
        metric: _kHrvSpec,
        resultA: _r(40.0),
        resultB: _r(50.0),
      );
      expect(cmp.delta, closeTo(-10.0, 0.001));
      expect(cmp.pctChange, closeTo(-20.0, 0.001));
    });
  });

  // ── cross-method consistency ──────────────────────────────────────────────

  group('executeWithMethod — cross-method consistency', () {
    test('max >= average >= min for same data', () async {
      final svc1 = _svcWith(_kHrvRows);
      final svc2 = _svcWith(_kHrvRows);
      final svc3 = _svcWith(_kHrvRows);
      final maxResult = await svc1.executeWithMethod(_plan(_kHrvSpec), 'max');
      final avgResult = await svc2.executeWithMethod(_plan(_kHrvSpec), 'average');
      final minResult = await svc3.executeWithMethod(_plan(_kHrvSpec), 'min');
      expect(maxResult.value!, greaterThanOrEqualTo(avgResult.value!));
      expect(avgResult.value!, greaterThanOrEqualTo(minResult.value!));
    });

    test('median is between min and max', () async {
      final svc1 = _svcWith(_kHrvRows);
      final svc2 = _svcWith(_kHrvRows);
      final svc3 = _svcWith(_kHrvRows);
      final maxResult = await svc1.executeWithMethod(_plan(_kHrvSpec), 'max');
      final medResult = await svc2.executeWithMethod(_plan(_kHrvSpec), 'median');
      final minResult = await svc3.executeWithMethod(_plan(_kHrvSpec), 'min');
      expect(medResult.value!, greaterThanOrEqualTo(minResult.value!));
      expect(medResult.value!, lessThanOrEqualTo(maxResult.value!));
    });

    test('all methods return non-null value when rows have data', () async {
      for (final method in ['average', 'mean', 'sum', 'total', 'max', 'min', 'median', 'latest']) {
        final svc = _svcWith(_kHrvRows);
        final result = await svc.executeWithMethod(_plan(_kHrvSpec), method);
        expect(result.value, isNotNull, reason: 'method "$method" returned null for non-empty data');
      }
    });

    test('all methods return null value when repo is empty', () async {
      for (final method in ['average', 'mean', 'sum', 'total', 'max', 'min', 'median', 'latest']) {
        final svc = _emptySvc();
        final result = await svc.executeWithMethod(_plan(_kHrvSpec), method);
        expect(result.value, isNull, reason: 'method "$method" should be null for empty data');
      }
    });
  });
}
