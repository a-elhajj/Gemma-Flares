import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/app_services.dart';
import 'core/services/diagnostic_log_service.dart';
import 'features/device_agent/device_agent_screen.dart';

// Set via: flutter run --dart-define=GEMMA_FLARES_DEV_RESET=true
// Clears setup state and profile so the setup wizard runs on next launch.
// Never true in release builds (const bool.fromEnvironment defaults to false).
const _devReset = bool.fromEnvironment('GEMMA_FLARES_DEV_RESET');

Future<void> main() async {
  const runDeviceAgent = bool.fromEnvironment('GEMMA_FLARES_DEVICE_AGENT');
  WidgetsFlutterBinding.ensureInitialized();
  await _bootstrapAppServices();
  _installDiagnosticsHooks();

  // Reset setup state before any UI runs so the wizard opens cleanly.
  // Guarded by !kReleaseMode so production builds can never auto-wipe.
  if (_devReset && !kReleaseMode) {
    await AppServices.resetSetupForDevelopment();
    unawaited(
      AppServices.diagnosticLogService.info(
        'dev_reset_applied',
        category: DiagnosticLogService.categoryApp,
        message:
            'GEMMA_FLARES_DEV_RESET=true: setup state and profile cleared.',
      ),
    );
  }

  unawaited(
    AppServices.diagnosticLogService.info(
      'app_started',
      category: DiagnosticLogService.categoryApp,
      message: 'Gemma Flares app started.',
    ),
  );
  runApp(
    runDeviceAgent ? const GemmaFlaresDeviceAgentApp() : const GemmaFlaresApp(),
  );
}

Future<void> _bootstrapAppServices() async {
  try {
    await AppServices.bootstrapEncryption();
  } catch (error, stackTrace) {
    // Fall back to non-encrypted test/dev wiring so the app can show setup or
    // diagnostics instead of crashing later through GetIt lookups.
    AppServices.setup();
    await AppServices.diagnosticLogService.error(
      'bootstrap_encryption_failed_fallback_setup',
      category: DiagnosticLogService.categoryApp,
      message: 'Encryption bootstrap failed; app continued with fallback DI.',
      error: error,
      stackTrace: stackTrace,
    );
  }

  try {
    await AppServices.database.open();
    await AppServices.validateCriticalStartupChain();
  } catch (error, stackTrace) {
    await AppServices.diagnosticLogService.error(
      'bootstrap_database_or_service_validation_failed',
      category: DiagnosticLogService.categoryApp,
      message:
          'Database open or critical service validation failed at startup.',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

class GemmaFlaresDeviceAgentApp extends StatelessWidget {
  const GemmaFlaresDeviceAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma Flares iPhone Agent',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4A7C74),
      ),
      home: const DeviceAgentScreen(),
    );
  }
}

void _installDiagnosticsHooks() {
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (previousFlutterErrorHandler != null) {
      previousFlutterErrorHandler(details);
    } else {
      FlutterError.presentError(details);
    }
    unawaited(
      AppServices.diagnosticLogService.error(
        'flutter_framework_error',
        category: DiagnosticLogService.categoryApp,
        message: 'A Flutter framework error was recorded.',
        error: details.exception,
        stackTrace: details.stack,
        metadata: {
          'library': details.library,
          'context': details.context?.toString(),
        },
      ),
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    unawaited(
      AppServices.diagnosticLogService.error(
        'platform_uncaught_error',
        category: DiagnosticLogService.categoryApp,
        message: 'An uncaught platform error was recorded.',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return false;
  };
}
