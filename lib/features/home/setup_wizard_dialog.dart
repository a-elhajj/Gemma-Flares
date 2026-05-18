import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/contracts/health_bridge_contracts.dart';
import '../../core/services/apple_watch_capability_service.dart';
import '../../core/services/litert_lm_download_service.dart';
import '../../core/services/health_sync_service.dart';
import '../../core/services/local_model_runtime.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/setup_state_service.dart';
import '../../core/services/rag_memory_service.dart';

/// First-launch setup wizard shown when profile, model, or Apple Health setup
/// has not been validated for this local install.
class SetupWizardDialog extends StatefulWidget {
  const SetupWizardDialog({super.key});

  @override
  State<SetupWizardDialog> createState() => _SetupWizardDialogState();
}

enum _Step { profile, health, model }

enum _ModelState {
  idle,
  downloading,
  extracting,
  loading,
  validating,
  loaded,
  failed,
}

enum _HealthState { idle, requesting, syncing, validated, failed }

class _PhaseValidation {
  const _PhaseValidation({
    required this.ok,
    required this.title,
    required this.message,
  });

  final bool ok;
  final String title;
  final String message;
}

class _SetupWizardDialogState extends State<SetupWizardDialog> {
  static const double _lbPerKg = 2.2046226218;

  _Step _step = _Step.profile;

  final _ageController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _diagnosisYearController = TextEditingController();
  final _surgeryYearController = TextEditingController();
  final _otherConditionsController = TextEditingController();

  String? _diseaseType;
  String? _biologicalSex;
  String? _cdLocation;
  String? _cdBehavior;
  bool? _cdPerianal;
  String? _ucExtent;
  bool? _hadSurgery;
  String? _deviceType = 'Apple Watch';
  String? _watchModel = AppleWatchCapabilityService.unknownModelId;
  String? _smokingStatus;
  String _weightUnit = 'kg';
  final Set<String> _medicationClasses = <String>{};

  _PhaseValidation? _profileValidation;
  _PhaseValidation? _modelValidation;
  _PhaseValidation? _healthValidation;
  _ModelState _modelState = _ModelState.idle;
  _HealthState _healthState = _HealthState.idle;
  String? _modelProgressLabel;
  double? _modelProgress;
  Future<LiteRtLmDownloadResult>? _modelDownloadFuture;
  bool _modelArtifactsReady = false;
  bool _modelRevealPlayed = false;
  bool _modelRepairMode = false;

  // -- In-memory phase completion flags -------------------------------------
  // These are the sole source of truth for the Done button gate (_canClose).
  // They are set only after the corresponding await-ed persist call returns,
  // so there is never a DB read-after-write race on the close path.
  bool _profileValidatedInMemory = false;
  bool _healthResolvedInMemory = false;
  bool _modelValidatedInMemory = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedSetupData());
    _startBackgroundModelDownload();
  }

  @override
  void dispose() {
    _ageController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    _diagnosisYearController.dispose();
    _surgeryYearController.dispose();
    _otherConditionsController.dispose();
    super.dispose();
  }

  void _startBackgroundModelDownload() {
    if (_modelDownloadFuture != null) return;
    final future = _downloadModelArtifacts();
    _modelDownloadFuture = future;
    unawaited(
      future.then((_) {
        _modelArtifactsReady = true;
      }, onError: (_) {}),
    );
  }

  Future<LiteRtLmDownloadResult> _downloadModelArtifacts() async {
    final runtimeStatus =
        await AppServices.localModelRuntime.getRuntimeStatus();
    final hasModel = runtimeStatus.isBundledModelPresent ||
        await AppServices.liteRtLmDownloadService.hasInstalledArtifact();
    if (hasModel) {
      _modelArtifactsReady = true;
      if (mounted && _modelState == _ModelState.idle) {
        setState(() {
          _modelProgressLabel = 'Gemma 4 model is ready.';
          _modelProgress = null;
        });
      }
      // Fast-path: model already on disk — downloadRequired returns immediately.
      return AppServices.liteRtLmDownloadService.downloadRequired();
    }

    if (mounted) {
      setState(() {
        if (_step == _Step.model) {
          _modelState = _ModelState.downloading;
        }
        _modelProgressLabel = 'Downloading Gemma 4 in the background...';
        _modelProgress = null;
      });
    }
    try {
      final result = await AppServices.liteRtLmDownloadService.downloadRequired(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            if (_step == _Step.model) {
              _modelState = _ModelState.downloading;
            }
            _modelProgress = progress.fraction;
            _modelProgressLabel = _formatLiteRtProgress(progress);
          });
        },
      );
      if (mounted &&
          _step == _Step.model &&
          _modelState == _ModelState.downloading) {
        setState(() {
          _modelState = _ModelState.idle;
          _modelProgress = null;
          _modelProgressLabel = 'Gemma 4 model downloaded. Ready to validate.';
        });
      }
      return result;
    } catch (error) {
      _modelDownloadFuture = null;
      if (mounted) {
        setState(() {
          _modelState = _ModelState.failed;
          _modelValidation = _PhaseValidation(
            ok: false,
            title: 'Gemma 4 download failed',
            message: error is LiteRtLmDownloadException
                ? error.userMessage
                : error.toString(),
          );
        });
      }
      rethrow;
    }
  }

  void _enterModelStep() {
    setState(() => _step = _Step.model);
    if (_modelState != _ModelState.loaded &&
        _modelState != _ModelState.loading &&
        _modelState != _ModelState.validating) {
      unawaited(_loadAndValidateModel());
    }
  }

  Future<void> _playFastModelRevealIfReady() async {
    if (!_modelArtifactsReady || _modelRevealPlayed) return;
    _modelRevealPlayed = true;
    const frames = <(double progress, String label)>[
      (0.18, 'Resuming Gemma 4 download...'),
      (0.74, 'Finishing Gemma 4 download...'),
      (1.0, 'Gemma 4 models downloaded.'),
    ];
    for (final frame in frames) {
      if (!mounted || _step != _Step.model) return;
      setState(() {
        _modelState = _ModelState.downloading;
        _modelProgress = frame.$1;
        _modelProgressLabel = frame.$2;
      });
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }
  }

  Future<void> _saveAndValidateProfile() async {
    setState(() => _profileValidation = null);
    try {
      final current = await AppServices.profileService.loadProfile();
      final profile = current.copyWith(
        dateOfBirth: _dateOfBirthFromAge(_ageController.text),
        biologicalSex: _blankToNull(_biologicalSex),
        heightCm: _parsePositiveDouble(_heightController.text),
        weightKg: _weightKgFromInput(),
        weightUnitPreference: _weightUnit,
        diseaseType: _blankToNull(_diseaseType),
        cdDiseaseLocation: _blankToNull(_cdLocation),
        cdDiseaseBehavior: _blankToNull(_cdBehavior),
        cdPerianalInvolvement: _cdPerianal,
        ucDiseaseExtent: _blankToNull(_ucExtent),
        diagnosisYear: _parseYear(_diagnosisYearController.text),
        hadSurgery: _hadSurgery,
        surgeryYear: _parseYear(_surgeryYearController.text),
        medications: _medicationClasses
            .map((name) => MedicationEntry(name: name))
            .toList(growable: false),
        otherConditions: _profileContextTags(),
        deviceType: _blankToNull(_deviceType),
        watchSeries:
            _deviceType == 'Apple Watch' ? _blankToNull(_watchModel) : null,
      );
      await AppServices.profileService.saveProfile(profile);
      final saved = await AppServices.profileService.loadProfile();
      final covariates = await AppServices.profileService.getCovariates();
      if (!mounted) return;
      if (!saved.hasProfileData || saved.diseaseType == null) {
        setState(() {
          _profileValidation = const _PhaseValidation(
            ok: false,
            title: 'Profile needs a diagnosis',
            message:
                'Choose Crohn\'s disease, ulcerative colitis, indeterminate colitis, or IBS before continuing.',
          );
        });
        return;
      }
      final details = <String>[
        'Diagnosis: ${saved.diseaseType}',
        if (covariates.age != null) 'Age: ${covariates.age}',
        if (covariates.bmi != null)
          'BMI: ${covariates.bmi!.toStringAsFixed(1)}',
        if (saved.medications.isNotEmpty)
          'Medication groups: ${saved.medications.length}',
      ].join(' | ');
      await AppServices.setupStateService.markProfileValidated();
      // Set in-memory flag immediately after the await - no re-read needed.
      _profileValidatedInMemory = true;
      // Best-effort RAG anchor: idempotent transactionId ensures no duplicates.
      unawaited(_writeProfileRagAnchor(saved));
      if (!mounted) return;
      setState(() {
        _profileValidation = _PhaseValidation(
          ok: true,
          title: 'Profile saved and validated',
          message: details,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _profileValidation = _PhaseValidation(
          ok: false,
          title: 'Profile validation failed',
          message: error.toString(),
        );
      });
    }
  }

  Future<void> _loadAndValidateModel() async {
    setState(() {
      _modelState = _ModelState.downloading;
      _modelValidation = null;
      _modelProgressLabel ??= 'Preparing Gemma 4 models...';
    });
    try {
      _startBackgroundModelDownload();
      await _modelDownloadFuture;
      await _playFastModelRevealIfReady();

      if (!mounted) return;
      setState(() {
        _modelState = _ModelState.loading;
        _modelProgress = null;
        _modelProgressLabel = 'Loading Gemma 4 locally...';
      });
      final status = await AppServices.localModelRuntime.loadLocalModel(
        profile: 'phone_balanced',
      );
      if (!mounted) return;
      if (!status.isModelLoaded) {
        setState(() {
          _modelState = _ModelState.failed;
          _modelValidation = _PhaseValidation(
            ok: false,
            title: 'Gemma 4 did not load',
            message: _modelStatusMessage(status),
          );
        });
        return;
      }

      setState(() => _modelState = _ModelState.validating);
      final probe = await AppServices.localModelRuntime.generate(
        const LocalModelRequest(
          systemPrompt:
              'You are GutGuard. Validate that local inference works. Do not mention medical advice.',
          userPrompt: 'Reply in one short sentence that GutGuard is ready.',
          groundedContext: {'setup_validation': true},
          maxTokens: 24,
          temperature: 0.01,
          taskType: 'setup_validation',
          modelRole: 'daily_fast',
          contextPolicy: 'setup_validation',
          requestId: 'setup_model_probe',
        ),
      );
      if (!mounted) return;
      final output = probe.outputText.trim();
      final ok = probe.status == 'ok' || probe.status == 'success';
      if (ok && output.isNotEmpty) {
        await AppServices.setupStateService.markModelValidated(
          runtimeProfile: probe.activeRuntimeProfile,
          backend: probe.backendUsed,
        );
        _modelValidatedInMemory = true;
        // Record model installation in the structured RAG index.
        unawaited(AppServices.ragIndexService.indexModelInstallation(
          engineProvider: 'litert-lm',
          modelId: 'gemma-4-e2b-litert',
          installedAt: DateTime.now().toUtc(),
          validated: true,
          runtimeProfile: probe.activeRuntimeProfile,
          backend: probe.backendUsed,
        ));
        if (!mounted) return;
        setState(() {
          _modelState = _ModelState.loaded;
          _modelValidation = _PhaseValidation(
            ok: true,
            title: 'Gemma 4 loaded and generated text',
            message: 'Backend: ${probe.backendUsed}; '
                'profile: ${probe.activeRuntimeProfile}; '
                'smoke test confirmed: "$output"',
          );
        });
      } else {
        setState(() {
          _modelState = _ModelState.failed;
          _modelValidation = _PhaseValidation(
            ok: false,
            title: 'Gemma 4 loaded but failed validation',
            message: probe.reason ??
                probe.fallbackReason ??
                'The validation probe returned no usable text.',
          );
        });
      }
    } catch (error) {
      if (!mounted) return;
      // Don't overwrite a more-specific failure title already set by the
      // download catch (e.g. 'Gemma 4 download failed').
      if (_modelState == _ModelState.failed && _modelValidation != null) return;
      setState(() {
        _modelState = _ModelState.failed;
        _modelValidation = _PhaseValidation(
          ok: false,
          title: 'Gemma 4 validation crashed',
          message: error.toString(),
        );
      });
    }
  }

  Future<void> _freshReinstallAndValidateModel() async {
    setState(() {
      _modelState = _ModelState.downloading;
      _modelValidation = null;
      _modelProgress = null;
      _modelProgressLabel = 'Removing old Gemma 4 files...';
      _modelArtifactsReady = false;
      _modelRevealPlayed = false;
      _modelDownloadFuture = null;
    });
    try {
      // Clear installed artifacts before redownloading.
      await AppServices.liteRtLmDownloadService.resetArtifact();
      await AppServices.setupStateService.markModelNeedsRepair();
      if (!mounted) return;
      setState(() {
        _modelProgressLabel = 'Starting a fresh Gemma 4 download...';
      });
      await _loadAndValidateModel();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _modelState = _ModelState.failed;
        _modelValidation = _PhaseValidation(
          ok: false,
          title: 'Gemma 4 reset failed',
          message: error.toString(),
        );
      });
    }
  }

  String _formatLiteRtProgress(LiteRtLmDownloadProgress progress) {
    final phase = progress.phase;
    final label = progress.artifact.label;
    if (phase == 'ready' || phase == 'already_installed') {
      return '$label is ready.';
    }
    final total = progress.totalBytes;
    final received = progress.receivedBytes;
    if (total == null || total <= 0) {
      return 'Downloading $label (${_formatBytes(received)})...';
    }
    return 'Downloading $label (${_formatBytes(received)} of ${_formatBytes(total)})...';
  }

  String _formatBytes(int bytes) {
    final gb = bytes / 1000000000;
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / 1000000;
    if (mb >= 1) return '${mb.toStringAsFixed(0)} MB';
    final kb = bytes / 1000;
    if (kb >= 1) return '${kb.toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _authorizeSyncAndValidateHealth() async {
    setState(() {
      _healthState = _HealthState.requesting;
      _healthValidation = null;
    });
    try {
      final metrics = HealthSyncService.allProductionMetrics;
      final authorization = await AppServices.healthSyncService
          .requestAuthorization(metrics: metrics);
      if (!mounted) return;
      if (authorization.status != 'success') {
        setState(() {
          _healthState = _HealthState.failed;
          _healthValidation = _PhaseValidation(
            ok: false,
            title: 'Health access was not completed',
            message:
                'iOS returned ${authorization.status}. Open Settings or Apple Health to grant access, then retry.',
          );
        });
        return;
      }

      final status = await AppServices.healthSyncService.getAuthorizationStatus(
        metrics: metrics,
      );
      if (!status.healthDataAvailable) {
        if (!mounted) return;
        setState(() {
          _healthState = _HealthState.failed;
          _healthValidation = const _PhaseValidation(
            ok: false,
            title: 'Apple Health is unavailable',
            message:
                'This device cannot provide HealthKit data to Gemma Flares.',
          );
        });
        return;
      }

      setState(() => _healthState = _HealthState.syncing);
      final result = await AppServices.healthSyncService.runInitialBackfill(
        metrics: HealthSyncService.tier1Metrics,
        lookback: const Duration(days: 30),
      );
      final syncState = await AppServices.wearableSampleRepository.getSyncState(
        'apple_health',
      );
      if (!mounted) return;

      final coreFailures = result.metricResults
          .where((item) => item.error != null)
          .map((item) => item.metricType.wireName)
          .toList(growable: false);
      final successfulGroups =
          result.metricResults.where((item) => item.status == 'success').length;
      if (syncState?.lastSyncAt == null ||
          coreFailures.length == result.metricResults.length) {
        setState(() {
          _healthState = _HealthState.failed;
          _healthValidation = const _PhaseValidation(
            ok: false,
            title: 'Health sync validation failed',
            message:
                'No core Health metric could be read. Retry after granting access in the Health sheet.',
          );
        });
        return;
      }

      final imported = result.inserted + result.updated;
      final message = imported > 0
          ? 'Read $imported samples across $successfulGroups core metric groups. Last sync: ${syncState!.lastSyncAt!.toLocal()}.'
          : 'Health access completed and sync ran, but Apple Health returned no recent samples. Wear your Apple Watch and keep the enabled categories on.';
      await AppServices.setupStateService.completeWithHealth(
        importedSamples: imported,
        lastBackfillAt: syncState?.lastSyncAt,
      );
      // Set in-memory flag immediately after the await - no re-read needed.
      _healthResolvedInMemory = true;
      // Best-effort RAG anchor with fixed transaction ID (idempotent).
      unawaited(
        _writeHealthRagAnchor(
          importedSamples: imported,
          lastSyncAt: syncState?.lastSyncAt,
        ),
      );
      if (!mounted) return;
      setState(() {
        _healthState = _HealthState.validated;
        _healthValidation = _PhaseValidation(
          ok: true,
          title: 'Health access validated',
          message: message,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _healthState = _HealthState.failed;
        _healthValidation = _PhaseValidation(
          ok: false,
          title: 'Health validation failed',
          message: error.toString(),
        );
      });
    }
  }

  Future<void> _loadSavedSetupData() async {
    try {
      final profile = await AppServices.profileService.loadProfile();
      final setupStatus = await AppServices.setupStateService.loadStatus();
      final runtimeStatus =
          await AppServices.localModelRuntime.getRuntimeStatus();
      final hasRequiredModel = runtimeStatus.isBundledModelPresent ||
          await AppServices.liteRtLmDownloadService.hasInstalledArtifact();
      if (setupStatus.hasValidatedModel && !hasRequiredModel) {
        await AppServices.setupStateService.markModelNeedsRepair();
      }
      if (!mounted) return;
      setState(() {
        _applyProfile(profile);
        _applySetupStatus(
          setupStatus,
          profile,
          hasRequiredModel: hasRequiredModel,
        );
      });
    } catch (_) {
      // Saved setup state is best-effort; the wizard remains editable.
    }
  }

  void _applyProfile(UserProfile profile) {
    _ageController.text = _ageFromDateOfBirth(profile.dateOfBirth) ?? '';
    _heightController.text = _formatNumber(profile.heightCm);
    _weightUnit = profile.weightUnitPreference == 'lb' ? 'lb' : 'kg';
    final displayedWeight = profile.weightKg == null
        ? null
        : _weightUnit == 'lb'
            ? profile.weightKg! * _lbPerKg
            : profile.weightKg;
    _weightController.text = _formatNumber(displayedWeight);
    _diagnosisYearController.text = profile.diagnosisYear?.toString() ?? '';
    _surgeryYearController.text = profile.surgeryYear?.toString() ?? '';
    _watchModel = const AppleWatchCapabilityService()
        .capabilityFor(profile.watchSeries)
        .id;
    _diseaseType = profile.diseaseType;
    _biologicalSex = profile.biologicalSex;
    _cdLocation = profile.cdDiseaseLocation;
    _cdBehavior = profile.cdDiseaseBehavior;
    _cdPerianal = profile.cdPerianalInvolvement;
    _ucExtent = profile.ucDiseaseExtent;
    _hadSurgery = profile.hadSurgery;
    _deviceType = profile.deviceType ?? 'Apple Watch';
    _medicationClasses
      ..clear()
      ..addAll(profile.medications.map((item) => item.name));

    final visibleConditions = <String>[];
    for (final condition in profile.otherConditions) {
      if (condition.startsWith('smoking_status:')) {
        _smokingStatus = condition.substring('smoking_status:'.length);
      } else {
        visibleConditions.add(condition);
      }
    }
    _otherConditionsController.text = visibleConditions.join(', ');
  }

  void _applySetupStatus(
    SetupStatus setupStatus,
    UserProfile profile, {
    required bool hasRequiredModel,
  }) {
    final canTrustSavedValidation = setupStatus.isCurrentSchema;
    if (!canTrustSavedValidation) {
      _step = _Step.profile;
      _profileValidation = const _PhaseValidation(
        ok: false,
        title: 'Profile needs re-validation',
        message:
            'Setup rules changed. Save and validate Profile, Health, and Gemma 4 again so each step is confirmed.',
      );
      return;
    }

    if (setupStatus.hasValidatedProfile && profile.hasProfileData) {
      _profileValidatedInMemory = true;
      _profileValidation = _PhaseValidation(
        ok: true,
        title: 'Profile saved and validated',
        message: 'Saved setup profile is ready.',
      );
    }
    final modelAvailableNow = hasRequiredModel;
    if (setupStatus.hasValidatedModel && modelAvailableNow) {
      _modelValidatedInMemory = true;
      _modelState = _ModelState.loaded;
      _modelValidation = _PhaseValidation(
        ok: true,
        title: 'Gemma 4 loaded and generated text',
        message: [
          if (setupStatus.modelBackend != null)
            'Backend: ${setupStatus.modelBackend}',
          if (setupStatus.modelRuntimeProfile != null)
            'profile: ${setupStatus.modelRuntimeProfile}',
          'validated previously',
        ].join('; '),
      );
    } else if (setupStatus.hasValidatedModel && !modelAvailableNow) {
      _modelRepairMode = true;
      _modelState = _ModelState.idle;
      _modelValidation = const _PhaseValidation(
        ok: false,
        title: 'Gemma 4 needs repair',
        message:
            'Setup was previously completed, but the verified local model files are missing or no longer match the install manifest. Download and validate Gemma 4 again to continue.',
      );
    }
    if (setupStatus.healthValidatedAt != null) {
      _healthResolvedInMemory = true;
      _healthState = _HealthState.validated;
      _healthValidation = _PhaseValidation(
        ok: true,
        title: setupStatus.healthEnabled
            ? 'Health access validated'
            : 'Health skipped for now',
        message: setupStatus.healthEnabled
            ? 'Previous setup imported ${setupStatus.healthImportedSamples} samples. Health will re-sync in the background when the app opens.'
            : 'Setup is complete without Apple Health. You can grant access later and Gemma Flares will sync in the background.',
      );
    }
    if (_modelRepairMode) {
      _step = _Step.model;
    } else if (setupStatus.hasValidatedProfile && profile.hasProfileData) {
      if (setupStatus.healthValidatedAt != null && !_modelValidationIsOk) {
        _step = _Step.model;
      } else if (setupStatus.healthValidatedAt == null) {
        _step = _Step.health;
      }
    }
  }

  bool get _modelValidationIsOk => _modelValidation?.ok == true;

  /// In-memory close gate - never touches the DB.
  /// All three phases must be confirmed in memory before [Navigator.pop] fires.
  bool get _canClose =>
      _profileValidatedInMemory &&
      _healthResolvedInMemory &&
      _modelValidatedInMemory &&
      _modelState == _ModelState.loaded;

  String? _ageFromDateOfBirth(String? dateOfBirth) {
    if (dateOfBirth == null || dateOfBirth.isEmpty) return null;
    final dob = DateTime.tryParse('${dateOfBirth}T00:00:00Z');
    if (dob == null) return null;
    final now = DateTime.now().toUtc();
    var age = now.year - dob.year;
    final birthdayPassed =
        now.month > dob.month || (now.month == dob.month && now.day >= dob.day);
    if (!birthdayPassed) age -= 1;
    return age >= 0 ? age.toString() : null;
  }

  String _formatNumber(double? value) {
    if (value == null) return '';
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  Future<void> _finish({bool healthEnabled = true}) async {
    // -- Health-skip path ----------------------------------------------------
    // Called from "Continue without Health" on the health step.
    // Persist the skip, set in-memory flag immediately (no re-read race),
    // write best-effort RAG anchor, then advance to the model step.
    if (_step == _Step.health && !healthEnabled) {
      try {
        await AppServices.setupStateService.completeWithoutHealth();
      } catch (_) {
        // Non-fatal - model step gates on _healthResolvedInMemory.
      }
      if (!mounted) return;
      setState(() => _healthResolvedInMemory = true);
      unawaited(_writeHealthRagAnchor(importedSamples: 0, skipped: true));
      _enterModelStep();
      return;
    }

    // -- Navigation path -----------------------------------------------------
    // Health step's "Continue to Gemma 4" button calls _enterModelStep directly.
    // This branch handles the rare case _finish is called from health without skip.
    if (_step == _Step.health) {
      _enterModelStep();
      return;
    }

    // -- Close gate (in-memory only, no DB round-trip) -----------------------
    // _canClose uses only flags that were set after await-ed persist calls,
    // eliminating the DB flush race that required two Done taps.
    if (_canClose) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // -- Scroll to the first incomplete step with a clear blocker message ----
    setState(() {
      if (!_profileValidatedInMemory) {
        _step = _Step.profile;
        _profileValidation = const _PhaseValidation(
          ok: false,
          title: 'Profile still needs validation',
          message: 'Save and validate your profile before leaving setup.',
        );
      } else if (!_healthResolvedInMemory) {
        _step = _Step.health;
        _healthValidation = const _PhaseValidation(
          ok: false,
          title: 'Health step still needs confirmation',
          message: 'Complete Health access, or choose Continue without Health.',
        );
      } else {
        _step = _Step.model;
        _modelValidation ??= const _PhaseValidation(
          ok: false,
          title: 'Gemma 4 still needs validation',
          message:
              'Complete the local model load and smoke test before leaving setup.',
        );
      }
    });
  }

  // \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  // RAG anchor helpers \u2014 idempotent fixed transaction IDs, best-effort.
  // Failure never blocks setup progression.
  // \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

  Future<void> _writeProfileRagAnchor(UserProfile profile) async {
    try {
      // Structured RAG index (LiteRT-LM embedding, queryable via RagQueryService).
      unawaited(AppServices.ragIndexService.indexProfile(profile));
      // Supplemental write to the legacy ragMemoryService path for backward compat.
      final covariates = await AppServices.profileService.getCovariates();
      final profileJson = profile.toJson();
      final covariatesJson = {
        'age': covariates.age,
        'sex_male': covariates.sexMale,
        'bmi': covariates.bmi,
        'disease_cd': covariates.diseaseCd,
      };
      final anchorPayload = {
        'anchor_type': 'setup_profile',
        'schema_version': SetupStatus.currentSchemaVersion,
        'profile': profileJson,
        'covariates': covariatesJson,
      };
      await AppServices.ragMemoryService.writeAndVerify(
        transactionId: RagMemoryService.setupProfileTransactionId,
        sourceType: 'setup',
        sourceId: 'user_profile',
        text:
            'Gemma Flares setup profile anchor.\n${jsonEncode(anchorPayload)}',
        metadata: {
          'setup_phase': 'profile',
          'schema_version': '${SetupStatus.currentSchemaVersion}',
          'profile': profileJson,
          'covariates': covariatesJson,
        },
      );
    } catch (_) {
      // Best-effort. Profile is valid regardless of RAG write outcome.
    }
  }

  Future<void> _writeHealthRagAnchor({
    required int importedSamples,
    DateTime? lastSyncAt,
    bool skipped = false,
  }) async {
    try {
      // Structured RAG index (LiteRT-LM embedding, queryable via RagQueryService).
      unawaited(AppServices.ragIndexService.indexHealthSync(
        dateLocal: DateTime.now().toUtc().toIso8601String().substring(0, 10),
        metrics: {
          'setup_health_sync': true,
          'imported_samples': importedSamples,
          'skipped': skipped,
        },
      ));
      final text = skipped
          ? 'Gemma Flares setup health anchor. User chose to continue without Apple Health access.'
          : 'Gemma Flares setup health anchor. '
              'Apple Health access granted and initial backfill complete. '
              'Imported samples: $importedSamples. '
              '${lastSyncAt != null ? 'Last sync: $lastSyncAt.' : ''}';
      await AppServices.ragMemoryService.writeAndVerify(
        // Fixed ID \u2014 upsert ensures this slot is never duplicated across re-runs.
        transactionId: RagMemoryService.setupHealthTransactionId,
        sourceType: 'setup',
        sourceId: 'apple_health',
        text: text,
        metadata: {
          'setup_phase': 'health',
          'skipped': skipped,
          'imported_samples': importedSamples,
        },
      );
    } catch (_) {
      // Best-effort. Health resolution is valid regardless of RAG write outcome.
    }
  }

  List<String> _profileContextTags() {
    final tags = <String>[];
    final conditions = _otherConditionsController.text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty);
    tags.addAll(conditions);
    if (_smokingStatus != null && _smokingStatus != 'prefer_not') {
      tags.add('smoking_status:${_smokingStatus!}');
    }
    return tags;
  }

  String? _dateOfBirthFromAge(String value) {
    final age = int.tryParse(value.trim());
    if (age == null || age <= 0 || age > 120) return null;
    final year = DateTime.now().toUtc().year - age;
    return '$year-07-01';
  }

  double? _parsePositiveDouble(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  double? _weightKgFromInput() {
    final weight = _parsePositiveDouble(_weightController.text);
    if (weight == null) return null;
    return _weightUnit == 'lb' ? weight / _lbPerKg : weight;
  }

  void _setWeightUnit(String nextUnit) {
    if (nextUnit == _weightUnit) return;
    final currentWeight = _parsePositiveDouble(_weightController.text);
    final convertedWeight = switch ((_weightUnit, nextUnit, currentWeight)) {
      (_, _, null) => null,
      ('kg', 'lb', final value?) => value * _lbPerKg,
      ('lb', 'kg', final value?) => value / _lbPerKg,
      _ => currentWeight,
    };

    setState(() {
      _weightUnit = nextUnit;
      _weightController.text = _formatNumber(convertedWeight);
    });
  }

  int? _parseYear(String value) {
    final parsed = int.tryParse(value.trim());
    final now = DateTime.now().toUtc().year;
    if (parsed == null || parsed < 1900 || parsed > now) return null;
    return parsed;
  }

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == 'prefer_not') {
      return null;
    }
    return trimmed;
  }

  String _modelStatusMessage(LocalModelRuntimeStatus status) {
    final parts = <String>[
      status.reason,
      'Expected: ${status.expectedModelFilename}',
      'Backend linked: ${status.isBackendLinked}',
      'Model present: ${status.isBundledModelPresent}',
      'Profile: ${status.activeRuntimeProfile}',
    ];
    return parts.where((part) => part.trim().isNotEmpty).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final canPop = _step == _Step.model &&
        _modelState != _ModelState.loading &&
        _modelState != _ModelState.validating;

    return PopScope(
      canPop: canPop,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StepIndicator(current: _step),
                const SizedBox(height: 22),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: KeyedSubtree(
                    key: ValueKey(_step),
                    child: switch (_step) {
                      _Step.profile => _ProfileStep(
                          ageController: _ageController,
                          heightController: _heightController,
                          weightController: _weightController,
                          weightUnit: _weightUnit,
                          diagnosisYearController: _diagnosisYearController,
                          surgeryYearController: _surgeryYearController,
                          otherConditionsController: _otherConditionsController,
                          watchModel: _watchModel,
                          diseaseType: _diseaseType,
                          biologicalSex: _biologicalSex,
                          cdLocation: _cdLocation,
                          cdBehavior: _cdBehavior,
                          cdPerianal: _cdPerianal,
                          ucExtent: _ucExtent,
                          hadSurgery: _hadSurgery,
                          deviceType: _deviceType,
                          smokingStatus: _smokingStatus,
                          medicationClasses: _medicationClasses,
                          validation: _profileValidation,
                          onDiseaseTypeChanged: (value) => setState(() {
                            _diseaseType = value;
                            _profileValidation = null;
                          }),
                          onBiologicalSexChanged: (value) =>
                              setState(() => _biologicalSex = value),
                          onCdLocationChanged: (value) =>
                              setState(() => _cdLocation = value),
                          onCdBehaviorChanged: (value) =>
                              setState(() => _cdBehavior = value),
                          onCdPerianalChanged: (value) =>
                              setState(() => _cdPerianal = value),
                          onUcExtentChanged: (value) =>
                              setState(() => _ucExtent = value),
                          onHadSurgeryChanged: (value) =>
                              setState(() => _hadSurgery = value),
                          onDeviceTypeChanged: (value) => setState(() {
                            _deviceType = value;
                            if (value == 'Apple Watch') {
                              _watchModel ??=
                                  AppleWatchCapabilityService.unknownModelId;
                            }
                          }),
                          onWatchModelChanged: (value) =>
                              setState(() => _watchModel = value),
                          onSmokingStatusChanged: (value) =>
                              setState(() => _smokingStatus = value),
                          onWeightUnitChanged: _setWeightUnit,
                          onMedicationToggled: (value, selected) =>
                              setState(() {
                            selected
                                ? _medicationClasses.add(value)
                                : _medicationClasses.remove(value);
                          }),
                        ),
                      _Step.model => _ModelStep(
                          state: _modelState,
                          progressLabel: _modelProgressLabel,
                          progress: _modelProgress,
                          validation: _modelValidation,
                          onLoad: _loadAndValidateModel,
                        ),
                      _Step.health => _HealthStep(
                          state: _healthState,
                          validation: _healthValidation,
                          onSync: _authorizeSyncAndValidateHealth,
                        ),
                    },
                  ),
                ),
                const SizedBox(height: 24),
                _buildActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActions() {
    return switch (_step) {
      _Step.profile => Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _profileValidation?.ok == true
                    ? null
                    : _saveAndValidateProfile,
                child: const Text('Save and validate'),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _profileValidation?.ok == true
                  ? () => setState(() => _step = _Step.health)
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      _Step.model => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_modelState == _ModelState.loading ||
                _modelState == _ModelState.downloading ||
                _modelState == _ModelState.extracting ||
                _modelState == _ModelState.validating)
              const SizedBox.shrink()
            else if (_modelState == _ModelState.loaded)
              FilledButton(
                onPressed: () => unawaited(_finish()),
                child: const Text('Done'),
              )
            else
              FilledButton.icon(
                onPressed: _modelState == _ModelState.failed
                    ? () => unawaited(_freshReinstallAndValidateModel())
                    : _loadAndValidateModel,
                icon: const Icon(Icons.memory_rounded, size: 18),
                label: Text(
                  _modelState == _ModelState.failed
                      ? 'Retry Gemma 4 setup'
                      : 'Download and validate Gemma 4',
                ),
              ),
            if (_modelState != _ModelState.loading &&
                _modelState != _ModelState.downloading &&
                _modelState != _ModelState.extracting &&
                _modelState != _ModelState.validating) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() => _step = _Step.health),
                child: const Text('Back to Health'),
              ),
            ],
          ],
        ),
      _Step.health => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_healthState == _HealthState.requesting ||
                _healthState == _HealthState.syncing)
              const SizedBox.shrink()
            else if (_healthState == _HealthState.validated)
              FilledButton(
                onPressed: _enterModelStep,
                child: const Text('Continue to Gemma 4'),
              )
            else
              FilledButton.icon(
                onPressed: _authorizeSyncAndValidateHealth,
                icon: const Icon(Icons.favorite_rounded, size: 18),
                label: Text(
                  _healthState == _HealthState.failed
                      ? 'Retry Health access'
                      : 'Open Health access',
                ),
              ),
            if (_healthState == _HealthState.failed) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => unawaited(_finish(healthEnabled: false)),
                child: const Text('Continue without Health'),
              ),
            ],
            if (_healthState != _HealthState.requesting &&
                _healthState != _HealthState.syncing) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() => _step = _Step.profile),
                child: const Text('Back to Profile'),
              ),
            ],
          ],
        ),
    };
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current});

  final _Step current;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final labels = ['Profile', 'Health', 'Gemma 4'];
    return Row(
      children: [
        for (var i = 0; i < _Step.values.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Divider(
                color: i <= current.index
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
                thickness: 2,
              ),
            ),
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < current.index
                      ? colorScheme.primary
                      : i == current.index
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest,
                  border: Border.all(
                    color: i == current.index
                        ? colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: i < current.index
                      ? Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: colorScheme.onPrimary,
                        )
                      : Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: i == current.index
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(labels[i], style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ],
      ],
    );
  }
}

class _ProfileStep extends StatelessWidget {
  const _ProfileStep({
    required this.ageController,
    required this.heightController,
    required this.weightController,
    required this.weightUnit,
    required this.diagnosisYearController,
    required this.surgeryYearController,
    required this.otherConditionsController,
    required this.diseaseType,
    required this.biologicalSex,
    required this.cdLocation,
    required this.cdBehavior,
    required this.cdPerianal,
    required this.ucExtent,
    required this.hadSurgery,
    required this.deviceType,
    required this.watchModel,
    required this.smokingStatus,
    required this.medicationClasses,
    required this.onDiseaseTypeChanged,
    required this.onBiologicalSexChanged,
    required this.onCdLocationChanged,
    required this.onCdBehaviorChanged,
    required this.onCdPerianalChanged,
    required this.onUcExtentChanged,
    required this.onHadSurgeryChanged,
    required this.onDeviceTypeChanged,
    required this.onWatchModelChanged,
    required this.onSmokingStatusChanged,
    required this.onWeightUnitChanged,
    required this.onMedicationToggled,
    this.validation,
  });

  final TextEditingController ageController;
  final TextEditingController heightController;
  final TextEditingController weightController;
  final String weightUnit;
  final TextEditingController diagnosisYearController;
  final TextEditingController surgeryYearController;
  final TextEditingController otherConditionsController;
  final String? diseaseType;
  final String? biologicalSex;
  final String? cdLocation;
  final String? cdBehavior;
  final bool? cdPerianal;
  final String? ucExtent;
  final bool? hadSurgery;
  final String? deviceType;
  final String? watchModel;
  final String? smokingStatus;
  final Set<String> medicationClasses;
  final ValueChanged<String?> onDiseaseTypeChanged;
  final ValueChanged<String?> onBiologicalSexChanged;
  final ValueChanged<String?> onCdLocationChanged;
  final ValueChanged<String?> onCdBehaviorChanged;
  final ValueChanged<bool?> onCdPerianalChanged;
  final ValueChanged<String?> onUcExtentChanged;
  final ValueChanged<bool?> onHadSurgeryChanged;
  final ValueChanged<String?> onDeviceTypeChanged;
  final ValueChanged<String?> onWatchModelChanged;
  final ValueChanged<String?> onSmokingStatusChanged;
  final ValueChanged<String> onWeightUnitChanged;
  final void Function(String value, bool selected) onMedicationToggled;
  final _PhaseValidation? validation;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Profile', style: textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'These match the Mount Sinai wearable flare study covariates: age, sex, BMI, IBD type, surgery history, medication class, comorbidities, smoking status, and wearable device.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        _DropdownField(
          label: 'Diagnosis',
          value: diseaseType,
          items: const {
            'CD': 'Crohn\'s disease',
            'UC': 'Ulcerative colitis',
            'IC': 'Indeterminate colitis',
            'IBS': 'IBS (irritable bowel syndrome)',
          },
          onChanged: onDiseaseTypeChanged,
        ),
        if (diseaseType == 'CD') ...[
          _DropdownField(
            label: 'Crohn\'s location',
            value: cdLocation,
            items: const {
              'L1': 'Ileal (L1)',
              'L2': 'Colonic (L2)',
              'L3': 'Ileocolonic (L3)',
              'L4': 'Upper GI (L4)',
            },
            onChanged: onCdLocationChanged,
          ),
          _DropdownField(
            label: 'Crohn\'s behavior',
            value: cdBehavior,
            items: const {
              'B1': 'Inflammatory (B1)',
              'B2': 'Stricturing (B2)',
              'B3': 'Penetrating (B3)',
            },
            onChanged: onCdBehaviorChanged,
          ),
          _BoolSegment(
            label: 'Perianal involvement',
            value: cdPerianal,
            onChanged: onCdPerianalChanged,
          ),
        ],
        if (diseaseType == 'UC')
          _DropdownField(
            label: 'UC extent',
            value: ucExtent,
            items: const {
              'proctitis': 'Proctitis',
              'left_sided': 'Left-sided disease',
              'extensive': 'Extensive colitis',
            },
            onChanged: onUcExtentChanged,
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _NumberField(
                controller: ageController,
                label: 'Age',
                suffix: 'years',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DropdownField(
                label: 'Sex',
                value: biologicalSex,
                items: const {
                  'female': 'Female',
                  'male': 'Male',
                  'other': 'Other',
                  'prefer_not': 'Prefer not',
                },
                onChanged: onBiologicalSexChanged,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _NumberField(
                controller: heightController,
                label: 'Height',
                suffix: 'cm',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment<String>(value: 'kg', label: Text('kg')),
                      ButtonSegment<String>(value: 'lb', label: Text('lbs')),
                    ],
                    selected: {weightUnit},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) {
                      if (selection.isNotEmpty) {
                        onWeightUnitChanged(selection.first);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  _NumberField(
                    controller: weightController,
                    label: 'Weight',
                    suffix: weightUnit == 'lb' ? 'lbs' : 'kg',
                  ),
                ],
              ),
            ),
          ],
        ),
        _NumberField(
          controller: diagnosisYearController,
          label: 'Diagnosis year',
          suffix: 'year',
        ),
        _BoolSegment(
          label: 'IBD-related surgery',
          value: hadSurgery,
          onChanged: onHadSurgeryChanged,
        ),
        if (hadSurgery == true)
          _NumberField(
            controller: surgeryYearController,
            label: 'Most recent surgery year',
            suffix: 'year',
          ),
        const SizedBox(height: 10),
        Text('Medication class', style: textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final item in const [
              'Mesalamines',
              'Corticosteroids',
              'Biologic agents',
              'Small molecules',
              'Immune modulators',
            ])
              FilterChip(
                label: Text(item),
                selected: medicationClasses.contains(item),
                onSelected: (selected) => onMedicationToggled(item, selected),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _DropdownField(
          label: 'Smoking status',
          value: smokingStatus,
          items: const {
            'never': 'Never',
            'past': 'Past smoker',
            'current': 'Current smoker',
            'prefer_not': 'Prefer not',
          },
          onChanged: onSmokingStatusChanged,
        ),
        _TextInput(
          controller: otherConditionsController,
          label: 'Other conditions',
          hint: 'Asthma, hypertension, diabetes...',
        ),
        Row(
          children: [
            Expanded(
              child: _DropdownField(
                label: 'Wearable',
                value: deviceType,
                items: const {
                  'Apple Watch': 'Apple Watch',
                  'Fitbit': 'Fitbit',
                  'Oura Ring': 'Oura Ring',
                  'None': 'None',
                },
                onChanged: onDeviceTypeChanged,
              ),
            ),
            if (deviceType == 'Apple Watch') ...[
              const SizedBox(width: 10),
              Expanded(
                child: _DropdownField(
                  label: 'Watch model',
                  value:
                      watchModel ?? AppleWatchCapabilityService.unknownModelId,
                  items: AppleWatchCapabilityService.dropdownItems,
                  onChanged: onWatchModelChanged,
                ),
              ),
            ],
          ],
        ),
        if (validation != null) ...[
          const SizedBox(height: 12),
          _ValidationCard(validation: validation!),
        ],
      ],
    );
  }
}

class _ModelStep extends StatelessWidget {
  const _ModelStep({
    required this.state,
    required this.onLoad,
    this.progressLabel,
    this.progress,
    this.validation,
  });

  final _ModelState state;
  final VoidCallback onLoad;
  final String? progressLabel;
  final double? progress;
  final _PhaseValidation? validation;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Gemma 4', style: textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Gemma Flares downloads Gemma 4 once, verifies its integrity, stores it locally on this iPhone, then runs a short validation prompt before chat is enabled.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: switch (state) {
            _ModelState.idle => Icon(
                Icons.memory_rounded,
                size: 54,
                color: colorScheme.primary.withValues(alpha: 0.65),
              ),
            _ModelState.downloading => _BusyBlock(
                title: 'Downloading Gemma 4...',
                message: progressLabel ??
                    'Keep Gemma Flares open while models download.',
                progress: progress,
              ),
            _ModelState.extracting => _BusyBlock(
                title: 'Installing Gemma 4...',
                message: progressLabel ?? 'Preparing local model files.',
              ),
            _ModelState.loading => const _BusyBlock(
                title: 'Loading Gemma 4...',
                message: 'First load can take about a minute.',
              ),
            _ModelState.validating => const _BusyBlock(
                title: 'Validating inference...',
                message: 'Running one local probe generation.',
              ),
            _ModelState.loaded => Icon(
                Icons.check_circle_rounded,
                size: 54,
                color: Colors.teal.shade500,
              ),
            _ModelState.failed => Icon(
                Icons.warning_amber_rounded,
                size: 54,
                color: colorScheme.error,
              ),
          },
        ),
        if (validation != null) ...[
          const SizedBox(height: 18),
          _ValidationCard(validation: validation!),
        ],
      ],
    );
  }
}

class _HealthStep extends StatelessWidget {
  const _HealthStep({
    required this.state,
    required this.onSync,
    this.validation,
  });

  final _HealthState state;
  final VoidCallback onSync;
  final _PhaseValidation? validation;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Apple Health', style: textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'The next button opens Apple\'s Health access sheet. Turn on all categories Gemma Flares requests, then Gemma Flares validates by running a 30-day core metric sync.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: switch (state) {
            _HealthState.idle => Icon(
                Icons.monitor_heart_outlined,
                size: 54,
                color: colorScheme.primary.withValues(alpha: 0.65),
              ),
            _HealthState.requesting => const _BusyBlock(
                title: 'Opening Health access...',
                message: 'Use Turn On All, then tap Allow.',
              ),
            _HealthState.syncing => const _BusyBlock(
                title: 'Validating Health data...',
                message:
                    'Reading recent HRV, heart rate, sleep, steps, SpO2, and wrist temperature.',
              ),
            _HealthState.validated => Icon(
                Icons.favorite_rounded,
                size: 54,
                color: Colors.red.shade400,
              ),
            _HealthState.failed => Icon(
                Icons.warning_amber_rounded,
                size: 54,
                color: colorScheme.error,
              ),
          },
        ),
        if (validation != null) ...[
          const SizedBox(height: 18),
          _ValidationCard(validation: validation!),
        ],
      ],
    );
  }
}

class _ValidationCard extends StatelessWidget {
  const _ValidationCard({required this.validation});

  final _PhaseValidation validation;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = validation.ok
        ? Colors.teal.withValues(alpha: 0.12)
        : colorScheme.errorContainer.withValues(alpha: 0.42);
    final foreground =
        validation.ok ? Colors.teal.shade800 : colorScheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            validation.ok ? Icons.verified_rounded : Icons.error_outline,
            size: 20,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  validation.title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  validation.message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BusyBlock extends StatelessWidget {
  const _BusyBlock({required this.title, required this.message, this.progress});

  final String title;
  final String message;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: progress, strokeWidth: 3),
        ),
        const SizedBox(height: 14),
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final Map<String, String> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        initialValue: items.containsKey(value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: items.entries
            .map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(growable: false),
        onChanged: onChanged,
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _BoolSegment extends StatelessWidget {
  const _BoolSegment({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          SegmentedButton<bool?>(
            segments: const [
              ButtonSegment<bool?>(value: true, label: Text('Yes')),
              ButtonSegment<bool?>(value: false, label: Text('No')),
              ButtonSegment<bool?>(value: null, label: Text('Unsure')),
            ],
            selected: {value},
            onSelectionChanged: (selected) => onChanged(selected.first),
          ),
        ],
      ),
    );
  }
}
