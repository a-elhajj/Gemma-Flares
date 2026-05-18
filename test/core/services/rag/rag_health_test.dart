// 30 tests: HealthKit sync round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('HealthKit Sync RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 all metrics: steps stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['steps: 8432'],
      );
    });

    test('02 all metrics: resting_hr stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['resting_hr: 62'],
      );
    });

    test('03 all metrics: hrv_sdnn stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['hrv_sdnn: 42.5'],
      );
    });

    test('04 all metrics: sleep_hours stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['sleep_hours: 7.2'],
      );
    });

    test('05 risk score stored with band', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['72.5%', 'band=elevated'],
      );
    });

    test('06 reason stored when present', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        reason: 'daily_sync',
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['reason: daily_sync'],
      );
    });

    test('07 date_local appears in text', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        ['date_local: 2026-05-14'],
      );
    });

    test('08 indexHealthSync returns success', () async {
      final result = await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('health_sync_tx_2026-05-14'));
      expect(result.collection, equals(RagCollection.summaries));
      expect(result.textLength, greaterThan(0));
    });

    test('09 stored in summaries (not symptoms)', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      await h.assertChunkExists(
          RagCollection.summaries, 'health_sync_tx_2026-05-14');
      await h.assertChunkNotExists(
          RagCollection.symptoms, 'health_sync_tx_2026-05-14');
    });

    test('10 schema version marker in text', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.text, contains('health_rag_v1'));
    });

    // ── Metadata ──────────────────────────────────────────────────────────

    test('11 metadata: date_local correct', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.metadata['date_local'], equals('2026-05-14'));
    });

    test('12 metadata: risk_score stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.metadata['risk_score'], closeTo(72.5, 0.001));
    });

    test('13 metadata: risk_band stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.metadata['risk_band'], equals('elevated'));
    });

    test('14 metadata: metric_count correct', () async {
      final metrics = TestHealthData.allMetrics();
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: metrics,
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.metadata['metric_count'], equals(metrics.length));
    });

    test('15 metadata: schema version correct', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      );
      expect(match!.metadata['schema'], equals('health_rag_v1'));
    });

    // ── Semantic query ─────────────────────────────────────────────────────

    test('16 query "elevated heart rate poor sleep" finds health entry',
        () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      final results = await h.query.queryCollection(
        RagCollection.summaries,
        'heart rate sleep health',
      );
      expect(results.isNotEmpty, isTrue);
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('17 edge: partial metrics — only stored keys appear', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-13',
        metrics: TestHealthData.partialMetrics(), // only steps, resting_hr
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-13',
      );
      expect(match!.text, contains('steps'));
      expect(match.text, contains('resting_hr'));
      // hrv_sdnn not in partialMetrics — must not appear
      expect(match.text, isNot(contains('hrv_sdnn')));
    });

    test('18 edge: heart health focus — afib_burden stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-12',
        metrics: TestHealthData.heartHealthFocus(),
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-12',
        ['atrial_fibrillation_burden_pct: 0.0'],
      );
    });

    test('19 edge: empty metrics map — still indexes (schema/date only)',
        () async {
      final result = await h.index.indexHealthSync(
        dateLocal: '2026-05-11',
        metrics: {},
      );
      expect(result.status, equals(RagIndexStatus.success));
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-11',
        ['health_rag_v1', '2026-05-11'],
      );
    });

    test('20 edge: null risk score — no flare_risk_score line', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-10',
        metrics: TestHealthData.partialMetrics(),
        // riskScore not passed
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-10',
      );
      expect(match!.text, isNot(contains('flare_risk_score')));
    });

    test('21 edge: no reason — no reason line', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-10',
        metrics: TestHealthData.partialMetrics(),
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-10',
      );
      expect(match!.text, isNot(contains('reason:')));
    });

    test('22 edge: duplicate date overwrites metrics', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-09',
        metrics: {'steps': 5000},
      );
      await h.index.indexHealthSync(
        dateLocal: '2026-05-09',
        metrics: {'steps': 9000},
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-09',
      );
      expect(match!.text, contains('9000'));
      expect(match.text, isNot(contains('5000')));
    });

    test('23 edge: high resting_hr (>100 bpm) stores correctly', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-08',
        metrics: {'resting_hr': 112},
        riskScore: 85.0,
        riskBand: 'high',
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-08',
        ['resting_hr: 112', '85.0%', 'band=high'],
      );
    });

    test('24 edge: dietary_water_ml metric stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-07',
        metrics: {'dietary_water_ml': 2100},
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-07',
        ['dietary_water_ml: 2100'],
      );
    });

    test('25 healthSyncChunkId deterministic format', () {
      expect(
        RagTextFormatter.healthSyncChunkId('2026-05-14'),
        equals('health_sync_tx_2026-05-14'),
      );
    });

    test('26 formatHealthSync pure: same input → same output', () {
      final t1 = RagTextFormatter.formatHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      final t2 = RagTextFormatter.formatHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
      );
      expect(t1, equals(t2));
    });

    test('27 30 days of health data — all retrievable', () async {
      for (var i = 1; i <= 30; i++) {
        final date = '2026-05-${i.toString().padLeft(2, '0')}';
        await h.index.indexHealthSync(
          dateLocal: date,
          metrics: {'steps': i * 300, 'resting_hr': 60 + i},
        );
      }
      for (var i = 1; i <= 30; i++) {
        final date = '2026-05-${i.toString().padLeft(2, '0')}';
        await h.assertChunkExists(
            RagCollection.summaries, 'health_sync_tx_$date');
      }
    });

    test('28 spo2 metric stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-06',
        metrics: {'spo2': 95},
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-06',
        ['spo2: 95'],
      );
    });

    test('29 respiratory_rate metric stored', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-05',
        metrics: {'respiratory_rate': 14},
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-05',
        ['respiratory_rate: 14'],
      );
    });

    test('30 all 12 all-metrics keys present in stored text', () async {
      final metrics = TestHealthData.allMetrics();
      await h.index.indexHealthSync(
        dateLocal: '2026-05-04',
        metrics: metrics,
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-04',
      );
      for (final key in metrics.keys) {
        expect(match!.text, contains(key),
            reason: 'metric key "$key" not found in stored text');
      }
    });
  });
}
