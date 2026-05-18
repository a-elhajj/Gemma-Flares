import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_services.dart';
import '../core/services/diagnostic_log_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_controller.dart';
import '../features/home/home_screen.dart';
import '../features/home/setup_wizard_dialog.dart';

class GemmaFlaresApp extends StatefulWidget {
  const GemmaFlaresApp({super.key});

  @override
  State<GemmaFlaresApp> createState() => _GemmaFlaresAppState();
}

class _GemmaFlaresAppState extends State<GemmaFlaresApp> {
  final ThemeModeController _themeModeController = ThemeModeController();

  @override
  void initState() {
    super.initState();
    unawaited(_themeModeController.restore());
  }

  @override
  void dispose() {
    _themeModeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeModeControllerScope(
      controller: _themeModeController,
      child: AnimatedBuilder(
        animation: _themeModeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Gemma Flares',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.buildLight(),
            darkTheme: AppTheme.buildDark(),
            themeMode: _themeModeController.themeMode,
            home: const GemmaFlaresShell(),
          );
        },
      ),
    );
  }
}

class GemmaFlaresShell extends StatefulWidget {
  const GemmaFlaresShell({super.key});

  @override
  State<GemmaFlaresShell> createState() => _GemmaFlaresShellState();
}

class _GemmaFlaresShellState extends State<GemmaFlaresShell>
    with WidgetsBindingObserver {
  bool _setupCheckComplete = false;
  String? _foregroundSessionId;
  DateTime? _pausedAt;

  static const _quickResumeSessionReuseWindow = Duration(minutes: 10);
  static const _modelWarmLoadTimeout = Duration(seconds: 20);

  /// Generates a session-scoped unique identifier without requiring the uuid package.
  static String _newSessionId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rng = math.Random.secure().nextInt(0xFFFFFFFF);
    return '${ts.toRadixString(16)}-${rng.toRadixString(16)}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _startForegroundSessionAndRefresh(
        reason: 'app_launch',
        forceNewSession: true,
      ),
    );
    // Check on next frame so the navigator is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSetup());
  }

  @override
  void dispose() {
    AppServices.healthRefreshCoordinator.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_startForegroundSessionAndRefresh(reason: 'app_resumed'));
      // Re-check model on every foreground so the badge stays accurate and
      // a corrupt/unloaded model is retried without requiring a cold start.
      unawaited(_warmLoadModel());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pausedAt = DateTime.now().toUtc();
      AppServices.healthRefreshCoordinator.stop();
    }
  }

  Future<void> _startForegroundSessionAndRefresh({
    required String reason,
    bool forceNewSession = false,
  }) async {
    final sessionId = _sessionIdForForeground(forceNew: forceNewSession);
    await AppServices.healthRefreshCoordinator.start(sessionId: sessionId);
    await AppServices.appReadinessService.refreshForOpen(reason: reason);
  }

  String _sessionIdForForeground({required bool forceNew}) {
    final pausedAt = _pausedAt;
    final shouldReuse = !forceNew &&
        _foregroundSessionId != null &&
        pausedAt != null &&
        DateTime.now().toUtc().difference(pausedAt) <
            _quickResumeSessionReuseWindow;
    if (!shouldReuse) {
      _foregroundSessionId = _newSessionId();
    }
    _pausedAt = null;
    return _foregroundSessionId!;
  }

  Future<void> _checkSetup() async {
    if (!mounted) return;
    var shouldOpenWizard = false;
    try {
      final profile = await AppServices.profileService.loadProfile();
      final setupStatus = await AppServices.setupStateService.loadStatus();
      final runtimeStatus =
          await AppServices.localModelRuntime.getRuntimeStatus();
      final hasRequiredModel = runtimeStatus.isBundledModelPresent ||
          await AppServices.liteRtLmDownloadService.hasInstalledArtifact();
      if (!mounted) return;

      // Enumerate every gate so logs precisely identify why the wizard reopens.
      // This is the only place where we re-read DB after setup — and it is
      // only called on cold launch, never inside the wizard close path.
      final completedFlag = setupStatus.completed;
      final readyForAppUse = setupStatus.isReadyForAppUse;
      final hasProfile = profile.hasProfileData;
      final hasValidatedModel = setupStatus.hasValidatedModel;
      final needsSetup = !completedFlag ||
          !readyForAppUse ||
          !hasProfile ||
          !hasValidatedModel ||
          !hasRequiredModel;
      shouldOpenWizard = needsSetup;

      if (needsSetup) {
        unawaited(
          AppServices.diagnosticLogService.info(
            'setup_check_needs_wizard',
            category: DiagnosticLogService.categoryApp,
            message: 'Setup readiness check triggered wizard open.',
            metadata: {
              'completed': completedFlag,
              'ready_for_app_use': readyForAppUse,
              'has_profile': hasProfile,
              'has_validated_model': hasValidatedModel,
              'has_required_model': hasRequiredModel,
              'schema_version': setupStatus.schemaVersion,
            },
          ),
        );
      }
    } catch (error, stackTrace) {
      shouldOpenWizard = true;
      unawaited(
        AppServices.diagnosticLogService.error(
          'setup_check_failed_opening_wizard',
          category: DiagnosticLogService.categoryApp,
          message: 'Setup readiness check failed, so the setup wizard opened.',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      // When no wizard is needed, reveal HomeScreen immediately.
      // When a wizard IS needed, defer until after the dialog so that
      // HomeScreen.initState never races with app.dart's own showDialog call
      // (which was causing a second wizard to open simultaneously).
      if (mounted && !shouldOpenWizard) {
        setState(() => _setupCheckComplete = true);
      }
    }
    if (!mounted) return;
    if (!shouldOpenWizard) {
      // Setup already done — silently warm-load the model so chat is ready
      // without triggering setup again. Non-fatal if load fails.
      if (shouldAutoWarmInstalledModelOnLaunch()) {
        unawaited(_warmLoadModel());
      }
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const SetupWizardDialog(),
    );
    // Wizard closed — now build HomeScreen. Any HomeScreen-initiated wizard
    // check will run after this and correctly reflect the updated setup state.
    if (mounted) setState(() => _setupCheckComplete = true);
  }

  Future<void> _warmLoadModel() async {
    try {
      await AppServices.modelReadiness
          .warmLoad(AppServices.localModelRuntime)
          .timeout(_modelWarmLoadTimeout);
    } catch (error, stackTrace) {
      unawaited(
        AppServices.diagnosticLogService.error(
          'model_warm_load_failed_or_timed_out',
          category: DiagnosticLogService.categoryApp,
          message: 'Model warm-load failed or exceeded the lifecycle timeout.',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_setupCheckComplete) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator.adaptive()),
      );
    }
    return const HomeScreen();
  }
}
