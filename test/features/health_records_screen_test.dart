import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/method_channel_health_bridge.dart';
import 'package:gemma_flares/features/health_records/health_records_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppServices.configureForTesting(
      healthBridgeOverride: _FakeHealthBridge(),
      localModelRuntimeOverride: const UnavailableGemmaRuntime(),
    );
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  testWidgets('health tabs stay visible on small screens', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: HealthRecordsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Symptoms'), findsWidgets);
    expect(find.text('Check-ins'), findsWidgets);
    expect(find.text('Labs'), findsWidgets);
    expect(find.text('Procedures'), findsWidgets);
    expect(find.text('Medication'), findsWidgets);
    expect(find.text('Trend'), findsWidgets);
  });

  testWidgets('add lab result offers manual or scan choices', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: HealthRecordsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add lab result').first);
    await tester.pumpAndSettle();

    expect(find.text('Enter manually'), findsOneWidget);
    expect(find.text('Scan or paste report'), findsOneWidget);
  });
}

class _FakeHealthBridge extends MethodChannelHealthBridge {
  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in request.requestedTypes)
          metric: HealthAuthorizationState.authorized,
      },
      requestedAt: DateTime.utc(2026, 4, 18),
    );
  }
}
