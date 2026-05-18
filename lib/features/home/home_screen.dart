import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/model_readiness_service.dart';
import '../../core/services/doctor_summary_pdf_service.dart';
import '../../core/services/gemma_task_service.dart';
import '../../core/services/ibd_checkin_service.dart';
import '../../core/services/lab_logging_service.dart';
import '../../core/services/local_agent_service.dart' as agent;
import '../../core/services/medication_logging_service.dart';
import '../../core/services/pending_reply_classifier_service.dart';
import '../../core/services/photo_crop_service.dart';
import '../../core/services/photo_intake_service.dart';
import '../../core/services/proactive_open_service.dart';
import '../../core/services/prompt_templates.dart' as prompts;
import '../../core/services/text_normalization_service.dart';
import '../health_records/lab_report_import_screen.dart';
import '../settings/settings_modal.dart';
import 'setup_wizard_dialog.dart';
import 'widgets/chat_surface_widget.dart';
import 'widgets/composer_widget.dart';
import 'widgets/risk_strip_widget.dart';

@visibleForTesting
String? buildDeterministicPhotoReply({
  required PhotoIntakeResult? result,
  required String userText,
  String? lastPhotoFilename,
}) {
  if (result == null) return null;
  final lower = userText.toLowerCase();
  final asksForPhoto = lower.contains('attached') ||
      lower.contains('photo') ||
      lower.contains('image') ||
      lower.contains('print result') ||
      lower.contains('print the result') ||
      lower.contains('print results') ||
      lower.contains('print ocr') ||
      lower.contains('show ocr') ||
      lower.contains('show results') ||
      lower.contains('show result') ||
      lower.contains('what does it say');
  if (!asksForPhoto) return null;
  final text = result.ocrText?.trim() ?? '';
  if (text.isEmpty) {
    return 'I do not have readable OCR text from the last photo${lastPhotoFilename == null ? '' : ' ($lastPhotoFilename)'}. Try retaking it in brighter light, or paste the lab text here.';
  }
  if (lower.contains('print') || lower.contains('show')) {
    return 'Here is the OCR text I read from the last photo:\n\n${_clipPhotoReplyText(text, 1600)}';
  }
  if (result.kind == PhotoIntakeKind.labReport) {
    return 'I see the lab photo. I read text from it, but nothing is saved yet. Say "confirm" on the review card to save, or say "print results" if you want the OCR text here first.';
  }
  return result.userFacingSummary;
}

String _clipPhotoReplyText(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}...';
}

@visibleForTesting
bool isGiSummaryTrace(Map<String, Object?>? toolTraceJson) {
  if (toolTraceJson == null || toolTraceJson.isEmpty) return false;
  final contract = toolTraceJson['task_contract']?.toString();
  final intent = toolTraceJson['agent_intent']?.toString();
  final route = toolTraceJson['task_route']?.toString();
  return contract == 'doctorSummary' ||
      intent == 'doctor_summary' ||
      route == 'doctor_summary_export';
}

@visibleForTesting
const Duration kHomeModelWarmLoadTimeout = Duration(seconds: 25);

bool shouldAutoWarmInstalledModelOnLaunch({bool isReleaseMode = kReleaseMode}) {
  return isReleaseMode;
}

@visibleForTesting
String homeModelLoadTimeoutBannerText() {
  return 'Gemma 4 is taking longer than expected — tap to retry.';
}

@visibleForTesting
Rect? resolveShareSheetOrigin(BuildContext context) {
  final object = context.findRenderObject();
  if (object is! RenderBox || !object.hasSize) return null;
  return object.localToGlobal(Offset.zero) & object.size;
}

@visibleForTesting
Future<bool> shareGiSummaryPdfFirst({
  required ChatMessage message,
  required DoctorSummaryPdfService pdfService,
  required Future<void> Function(XFile file) sharePdf,
}) async {
  final summary = message.text.trim();
  if (summary.isEmpty) {
    throw ArgumentError('Cannot share an empty GI summary.');
  }

  final pdfFile = await pdfService.writePdfToTemp(
    input: DoctorSummaryPdfRenderInput(
      summaryText: summary,
      generatedAt: message.timestamp,
      title: 'Gemma Flares GI Visit Summary',
    ),
  );

  if (!await pdfFile.exists()) {
    throw StateError('Doctor summary PDF file was not created.');
  }
  final sizeBytes = await pdfFile.length();
  if (sizeBytes <= 0) {
    throw StateError('Doctor summary PDF file is empty.');
  }

  final shareFile = XFile(pdfFile.path, mimeType: 'application/pdf');
  await sharePdf(shareFile);
  return true;
}

/// Single-screen root for Gemma Flares v2. There is no tab bar.
/// All navigation is modal sheets or full-screen modals presented over this
/// screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _imagePicker = ImagePicker();

  // Cached risk from DB — rendered immediately on first build; async refresh
  // populates it without blocking.
  double? _cachedRiskScore;
  String _cachedRiskBand = 'low';
  // Horizon outlook probabilities in 0–1 scale (from featureSnapshotJson).
  // Null until the first risk refresh completes.
  double? _outlook7d;
  double? _outlook14d;
  double? _outlook21d;

  bool _isGenerating = false;
  bool _modelReady = false;
  bool _modelLoading = false;
  Future<void>? _modelReadyCheck;
  Future<void>? _modelWarmLoad;
  bool _isSharingGiSummary = false;
  bool _openingPromptStarted = false;
  String? _profileDiseaseType;
  final _streamBuffer = StringBuffer();
  String _streamingText = '';
  final List<ChatMessage> _messages = [];
  agent.ChatPendingAction? _pendingAction;
  _RecentSymptomSave? _lastSavedSymptom;
  List<int>? _pendingSavedSymptomReplacementIds;
  _CheckInSession? _activeCheckIn;
  PhotoIntakeResult? _lastPhotoIntakeResult;
  String? _lastPhotoFilename;
  late final String _sessionId;

  @override
  void initState() {
    super.initState();
    _sessionId = 'home_${DateTime.now().toUtc().microsecondsSinceEpoch}';
    _loadProfileDiseaseType();
    _loadCachedRisk();
    _loadRecentMessages();
    _checkModelReady();
  }

  Future<void> _loadProfileDiseaseType() async {
    try {
      final profile = await AppServices.profileService.loadProfile();
      if (!mounted) return;
      setState(() {
        _profileDiseaseType = _normalizeDiseaseType(profile.diseaseType);
      });
    } catch (_) {
      // Badge is best-effort; UI can render without profile metadata.
    }
  }

  String? _normalizeDiseaseType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final upper = raw.trim().toUpperCase();
    if (upper == 'CD' || upper == 'UC' || upper == 'IC' || upper == 'IBS') {
      return upper;
    }
    return null;
  }

  String _diseaseLabelForBadge(String diseaseType) {
    return switch (diseaseType) {
      'CD' => "Crohn's",
      'UC' => 'Colitis',
      'IC' => 'Indeterminate colitis',
      'IBS' => 'IBS',
      _ => diseaseType,
    };
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkModelReady() async {
    final existing = _modelReadyCheck;
    if (existing != null) return existing;
    final check = _checkModelReadyInternal();
    _modelReadyCheck = check;
    try {
      await check;
    } finally {
      if (identical(_modelReadyCheck, check)) {
        _modelReadyCheck = null;
      }
    }
  }

  Future<void> _checkModelReadyInternal() async {
    try {
      final setupStatusFuture = AppServices.setupStateService.loadStatus();
      final statusFuture = AppServices.localModelRuntime.getRuntimeStatus();
      final setupStatus = await setupStatusFuture;
      final status = await statusFuture;
      final hasInstalledModel = status.isBundledModelPresent ||
          await AppServices.liteRtLmDownloadService.hasInstalledArtifact();
      final setupComplete = setupStatus.isReadyForAppUse && hasInstalledModel;
      if (mounted) {
        setState(() {
          _modelReady = setupComplete && status.isModelLoaded;
        });
        unawaited(_maybeStartOpeningPrompt());
        // The wizard is opened exclusively by app.dart._checkSetup() on cold
        // launch. HomeScreen never auto-opens it to avoid redundant dialogs
        // and false-positive triggers caused by transient file-system checks
        // at app startup. Tap the banner below to repair a missing model.
      }
      if (setupComplete &&
          !status.isModelLoaded &&
          shouldAutoWarmInstalledModelOnLaunch()) {
        unawaited(_warmLoadInstalledModel());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _modelLoading = false;
      });
    }
  }

  Future<void> _warmLoadInstalledModel() async {
    final existing = _modelWarmLoad;
    if (existing != null) return existing;
    final load = _warmLoadInstalledModelInternal();
    _modelWarmLoad = load;
    try {
      await load;
    } finally {
      if (identical(_modelWarmLoad, load)) {
        _modelWarmLoad = null;
      }
    }
  }

  Future<void> _warmLoadInstalledModelInternal() async {
    if (_modelReady || _modelLoading) return;
    try {
      final setupStatus = await AppServices.setupStateService.loadStatus();
      if (!setupStatus.isReadyForAppUse || !setupStatus.hasValidatedModel) {
        return;
      }
      // Use the LiteRT-LM service; model artifacts are managed by setup.
      final hasInstalledModel =
          await AppServices.liteRtLmDownloadService.hasInstalledArtifact();
      if (!hasInstalledModel) return;
      if (!mounted) return;
      setState(() => _modelLoading = true);
      // Delegate to the shared notifier so the badge and this state stay in sync.
      await AppServices.modelReadiness
          .warmLoad(AppServices.localModelRuntime)
          .timeout(kHomeModelWarmLoadTimeout);
      if (!mounted) return;
      setState(() {
        _modelReady = AppServices.modelReadiness.isReady;
        _modelLoading = false;
      });
      if (_modelReady) unawaited(_maybeStartOpeningPrompt());
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _modelLoading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _modelLoading = false);
    }
  }

  Future<void> _loadCachedRisk() async {
    try {
      final snapshot =
          await AppServices.dashboardSnapshotService.loadDashboardSnapshot();
      // BUG-078: use session-anchored score when a session is active; this
      // prevents background Apple Health sync from mutating the displayed score.
      // Falls back to latest score if no session is running.
      final sessionId = AppServices.healthRefreshCoordinator.currentSessionId;
      final score = sessionId != null
          ? await AppServices.wearableSampleRepository.getDisplayedSessionScore(
              sessionId: sessionId,
            )
          : await AppServices.wearableSampleRepository
              .getLatestUserFacingFlareRiskScore();
      if (score != null) {
        if (!mounted) return;
        final horizons = _resolveHorizonProbs(
          featureJson: score.featureSnapshotJson,
          fallback7dCandidates: [
            snapshot.logistic7dInflammatoryProb,
            snapshot.logistic7dSymptomaticProb,
            // riskScore/100 intentionally removed: riskScore is a heuristic
            // point total (0–100 int), not a probability. Using it here would
            // display a fake "25%" from 25 heuristic points. When both logistic
            // fallbacks are null (cold-start), outlook7d stays null → 'Learning'.
          ],
        );
        setState(() {
          _cachedRiskScore = score.riskScore;
          _outlook7d = horizons.$1;
          _outlook14d = horizons.$2;
          _outlook21d = horizons.$3;
          _cachedRiskBand = _displayRiskBand(
            outlook7d: horizons.$1,
            fallbackBand: score.riskBand,
          );
        });
        return;
      }
      // Fallback (first launch / no stored score yet): use the snapshot's
      // latestScore field, which is also a FlareRiskScoreRecord.
      if (!mounted) return;
      final ls = snapshot.latestScore;
      if (ls != null) {
        final horizons = _resolveHorizonProbs(
          featureJson: ls.featureSnapshotJson,
          fallback7dCandidates: [
            snapshot.logistic7dInflammatoryProb,
            snapshot.logistic7dSymptomaticProb,
            // ls.riskScore/100 removed — same reason as primary path above.
          ],
        );
        setState(() {
          _cachedRiskScore = ls.riskScore;
          _outlook7d = horizons.$1;
          _outlook14d = horizons.$2;
          _outlook21d = horizons.$3;
          _cachedRiskBand = _displayRiskBand(
            outlook7d: horizons.$1,
            fallbackBand: ls.riskBand,
          );
        });
      }
      // If both are null the user has no data yet; the strip renders without a
      // score, which is correct.
    } catch (_) {
      // Best-effort; screen renders without it.
    }
  }

  /// Extracts calibrated 7/14/21-day horizon flare probabilities (0–1 scale)
  /// from the feature snapshot JSON stored alongside a risk record.  Returns
  /// null for each horizon when the model was in cold-start for that window.
  (double?, double?, double?) _extractHorizonProbs(
    Map<String, Object?> featureJson,
  ) {
    double? parseProb(
      String key, {
      required String coldStartKey,
      required String rawKey,
      required String uncappedKey,
    }) {
      final coldStart = (featureJson[coldStartKey] as num?)?.toInt() == 1;
      if (coldStart) return null;
      final v = featureJson[key];
      if (v == null) return null;
      final d = (v as num?)?.toDouble();
      if (d == null) return null;

      // Values should be calibrated probabilities in [0,1]. For backward
      // compatibility with older snapshots, apply a conservative clamp and
      // bounded fallback if raw-only fields are present.
      final clamped = d.clamp(0.0, 0.92).toDouble();
      if (featureJson.containsKey(uncappedKey) ||
          featureJson.containsKey(rawKey)) {
        return clamped;
      }

      // Legacy snapshots may carry pre-calibration horizon probabilities.
      return clamped.clamp(0.08, 0.85).toDouble();
    }

    return (
      parseProb(
        'logistic_p_flare_7d',
        coldStartKey: 'logistic_7d_cold_start',
        rawKey: 'logistic_p_flare_7d_raw',
        uncappedKey: 'logistic_p_flare_7d_uncapped',
      ),
      parseProb(
        'logistic_p_flare_14d',
        coldStartKey: 'logistic_14d_cold_start',
        rawKey: 'logistic_p_flare_14d_raw',
        uncappedKey: 'logistic_p_flare_14d_uncapped',
      ),
      parseProb(
        'logistic_p_flare_21d',
        coldStartKey: 'logistic_21d_cold_start',
        rawKey: 'logistic_p_flare_21d_raw',
        uncappedKey: 'logistic_p_flare_21d_uncapped',
      ),
    );
  }

  (double?, double?, double?) _resolveHorizonProbs({
    required Map<String, Object?> featureJson,
    required List<double?> fallback7dCandidates,
  }) {
    final extracted = _extractHorizonProbs(featureJson);
    // The logistic model produced a valid p7 from featureJson. Inter-horizon
    // extrapolation (+5% per step) is meaningful here because the same model
    // run generated all horizons coherently.
    if (extracted.$1 != null) {
      final p14 = extracted.$2 ?? (extracted.$1! + 0.05).clamp(0.0, 1.0);
      final p21 = extracted.$3 ?? (p14 + 0.05).clamp(0.0, 1.0);
      return (extracted.$1, p14, p21);
    }
    // p7 is null (cold-start or no logistic data). Try snapshot fallback probs.
    // Do NOT fabricate p14/p21 from a fallback p7 — +5% extrapolation has no
    // model basis when the source is a snapshot fallback, not featureJson.
    // The 14d/21d horizon pills will show "N/A" which is correct.
    final p7 = _firstValidProbability(fallback7dCandidates);
    return (p7, null, null);
  }

  double? _firstValidProbability(List<double?> values) {
    for (final value in values) {
      if (value == null) continue;
      final clamped = value.clamp(0.0, 1.0);
      return clamped;
    }
    return null;
  }

  String _displayRiskBand({
    required double? outlook7d,
    required String fallbackBand,
  }) {
    if (outlook7d == null) return fallbackBand;
    if (outlook7d < 0.2) return 'low';
    if (outlook7d < 0.4) return 'moderate';
    if (outlook7d < 0.6) return 'high';
    return 'critical';
  }

  /// Refresh risk strip after any data-writing event (check-in, symptom save).
  Future<void> _refreshRiskScore() async {
    try {
      final score = await AppServices.wearableSampleRepository
          .getLatestUserFacingFlareRiskScore();
      if (!mounted) return;
      if (score != null) {
        final horizons = _resolveHorizonProbs(
          featureJson: score.featureSnapshotJson,
          // No probability fallback in the refresh path either.
          // Cold-start → 'Learning' until the logistic model has ≥14 samples.
          fallback7dCandidates: const [],
        );
        setState(() {
          _cachedRiskScore = score.riskScore;
          _outlook7d = horizons.$1;
          _outlook14d = horizons.$2;
          _outlook21d = horizons.$3;
          _cachedRiskBand = _displayRiskBand(
            outlook7d: horizons.$1,
            fallbackBand: score.riskBand,
          );
        });
      }
    } catch (_) {}
  }

  Future<void> _loadRecentMessages() async {
    try {
      final rows = await AppServices.wearableSampleRepository
          .getRecentConversations(limit: 8);
      if (!mounted) return;
      final restored = rows.reversed.expand((row) {
        final restoredIsGiSummary = isGiSummaryTrace(row.toolTraceJson);
        return [
          ChatMessage(
            role: 'user',
            text: row.userMessage,
            timestamp: row.createdAt,
          ),
          ChatMessage(
            role: 'assistant',
            text: row.assistantMessage,
            timestamp: row.createdAt,
            isGiSummary: restoredIsGiSummary,
          ),
        ];
      }).toList(growable: false);
      setState(() {
        _messages.addAll(restored);
      });
      _scrollToBottom();
      unawaited(_maybeStartOpeningPrompt());
    } catch (_) {
      // Empty chat is still usable when history cannot be restored.
      unawaited(_maybeStartOpeningPrompt());
    }
  }

  Future<void> _clearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'Removes saved messages from this iPhone. Health records, symptoms, labs, and scores are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await AppServices.wearableSampleRepository.clearConversations();
      await AppServices.localAgentService.resetSession(
        reason: 'user_cleared_chat',
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _messages.clear());
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Chat cleared.')));
  }

  Future<void> _copyAllChat() async {
    if (_messages.isEmpty) return;
    final buffer = StringBuffer();
    for (final m in _messages) {
      buffer.writeln('${m.role == 'user' ? 'You' : 'Gemma Flares'}: ${m.text}');
      buffer.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Chat copied to clipboard.')));
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1280,
        maxHeight: 1280,
      );
      if (file == null || !mounted) return;
      final croppedPath = await PhotoCropService.cropImageForUpload(
        context: context,
        sourcePath: file.path,
      );
      if (croppedPath == null || !mounted) return;
      final inspected = await AppServices.photoIntakeService.inspectImagePath(
        croppedPath,
      );
      final result = _photoResultForCurrentChatContext(inspected);
      if (!mounted) return;
      _lastPhotoIntakeResult = result;
      _lastPhotoFilename = file.name;
      // Lab photos go through a review screen and may be cancelled. Defer the
      // chat bubble until the user confirms the save, otherwise a cancelled
      // attempt leaves an orphaned "[Photo attached: ...]" message and an
      // assistant "Review the extracted values..." reply in the transcript.
      // For non-lab photos (food, general intake) the photo is the artifact —
      // append immediately as before.
      if (result.kind != PhotoIntakeKind.labReport) {
        _appendPhotoIntakeMessages(file.name, result);
      }
      if (result.kind == PhotoIntakeKind.labReport) {
        final saved = await Navigator.of(context).push<LabLoggingResult?>(
          MaterialPageRoute<LabLoggingResult?>(
            builder: (_) => LabReportImportScreen(
              initialText: result.ocrText,
              initialStatus:
                  'Photo looks like a lab report. Review the OCR text, then extract values.',
            ),
          ),
        );
        if (saved != null && mounted) {
          // Now that the lab is confirmed, render both the photo bubble and
          // the confirmation message so the transcript reads in order.
          _appendPhotoIntakeMessages(file.name, result);
          _appendLabImportConfirmationMessage(saved);
          setState(() {
            _lastPhotoIntakeResult = null;
            _lastPhotoFilename = null;
          });
        } else if (mounted) {
          // User cancelled the lab review — drop the in-memory photo state
          // so a subsequent message doesn't grounded against it.
          setState(() {
            _lastPhotoIntakeResult = null;
            _lastPhotoFilename = null;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not attach photo: $e')));
    }
  }

  void _appendPhotoIntakeMessages(String filename, PhotoIntakeResult result) {
    setState(() {
      _messages.add(
        ChatMessage(
          role: 'user',
          text: '[Photo attached: $filename]',
          timestamp: DateTime.now().toUtc(),
        ),
      );
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text: result.userFacingSummary,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    });
    _scrollToBottom();
  }

  PhotoIntakeResult _photoResultForCurrentChatContext(
    PhotoIntakeResult result,
  ) {
    if (result.kind != PhotoIntakeKind.unrelated &&
        result.kind != PhotoIntakeKind.unknown) {
      return result;
    }
    if (!_recentChatAskedForLabPhoto()) return result;
    return PhotoIntakeResult(
      transactionId: result.transactionId,
      kind: PhotoIntakeKind.labReport,
      confidence: result.confidence < 0.7 ? 0.7 : result.confidence,
      ocrText: result.ocrText,
      userFacingSummary: result.ocrText?.trim().isNotEmpty == true
          ? 'You said this is a lab result. I found readable text, but confidence is low, so review it before anything is saved.'
          : 'You said this is a lab result. I could not read it clearly, so review or paste the values before anything is saved.',
      requiresConfirmation: true,
      metadata: {
        ...result.metadata,
        'chat_context_override': 'recent_lab_attachment_intent',
      },
    );
  }

  bool _recentChatAskedForLabPhoto() {
    for (final message in _messages.reversed.take(4)) {
      if (message.role != 'user') continue;
      final lower = message.text.toLowerCase();
      if (lower.contains('lab') ||
          lower.contains('blood work') ||
          lower.contains('bloodwork') ||
          lower.contains('test result') ||
          lower.contains('cbc') ||
          lower.contains('cmp') ||
          lower.contains('vitamin')) {
        return true;
      }
    }
    return false;
  }

  void _showCameraSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(ImageSource.camera));
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(ImageSource.gallery));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _onSendMessage(String text) {
    if (text.trim().isEmpty || _isGenerating) return;
    _messageController.clear();
    setState(() {
      _messages.add(
        ChatMessage(
          role: 'user',
          text: text.trim(),
          timestamp: DateTime.now().toUtc(),
        ),
      );
      _isGenerating = true;
      _streamBuffer.clear();
      _streamingText = '';
    });
    _scrollToBottom();
    unawaited(_generateReply(text.trim()));
  }

  Future<void> _generateReply(String userText) async {
    final startedAt = DateTime.now().toUtc();
    try {
      final guarded = await AppServices.promptInjectionGuardService.inspect(
        userText,
        source: 'home_chat',
      );

      final photoReply = _deterministicPhotoReply(guarded.sanitizedText);
      if (photoReply != null) {
        _finishAssistantMessage(photoReply);
        await _persistTurn(
          userText: userText,
          assistantText: photoReply,
          startedAt: startedAt,
          toolTrace: {
            'status': 'deterministic_photo_context',
            'used_model_output': false,
            'photo_transaction_id': _lastPhotoIntakeResult?.transactionId,
            'photo_kind': _lastPhotoIntakeResult?.kind.name,
          },
        );
        return;
      }

      // ── Structured check-in state machine (deterministic, no Gemma call) ──
      final checkInReply = await _maybeHandleCheckIn(guarded.sanitizedText);
      if (checkInReply != null) {
        _finishAssistantMessage(checkInReply);
        await _persistTurn(
          userText: userText,
          assistantText: checkInReply,
          startedAt: startedAt,
          toolTrace: {
            'status': 'check_in_deterministic',
            'check_in_step': _activeCheckIn?.currentStep ?? 'complete',
            'used_model_output': false,
          },
        );
        return;
      }

      final pendingReply = await _maybeHandlePendingActionConfirmation(
        guarded.sanitizedText,
      );
      if (pendingReply != null) {
        _finishAssistantMessage(pendingReply, clearPendingAction: true);
        await _persistTurn(
          userText: userText,
          assistantText: pendingReply,
          startedAt: startedAt,
          toolTrace: {
            'status': 'pending_action_confirmed',
            'used_model_output': false,
          },
        );
        unawaited(_refreshRiskScore());
        return;
      }

      final savedSymptomReply = await _maybeHandleSavedSymptomFollowup(
        guarded.sanitizedText,
      );
      if (savedSymptomReply != null) {
        _finishAssistantMessage(savedSymptomReply);
        await _persistTurn(
          userText: userText,
          assistantText: savedSymptomReply,
          startedAt: startedAt,
          toolTrace: {
            'status': 'saved_symptom_followup',
            'used_model_output': false,
          },
        );
        unawaited(_refreshRiskScore());
        return;
      }

      final redFlag = await AppServices.redFlagClassifierService.classify(
        guarded.sanitizedText,
        source: 'home_chat',
      );
      if (redFlag.triggered) {
        final assistantText = redFlag.message;
        _finishAssistantMessage(assistantText);
        await _persistTurn(
          userText: userText,
          assistantText: assistantText,
          startedAt: startedAt,
          toolTrace: {
            'status': 'red_flag_escalation',
            'category': redFlag.category,
            'urgency': redFlag.urgency,
          },
        );
        return;
      }

      // Refresh the strip before the agent query so the displayed risk score
      // matches what the model will read from DB.  Runs in parallel with the
      // agent call — by the time the response arrives the strip is current.
      unawaited(_refreshRiskScore());

      final reply = await AppServices.localAgentService
          .ask(guarded.sanitizedText)
          .timeout(
            const Duration(seconds: 75),
            onTimeout: () => const agent.LocalAgentReply(
              status: 'timeout',
              message:
                  'The local model took too long, so I stopped waiting. Try a shorter message, or close other apps if your phone feels low on memory.',
              runtimeName: 'timeout_guard',
              toolTraceJson: {
                'used_model_output': false,
                'agent_intent': 'runtime_timeout',
                'tools_called': ['chat_timeout_guard'],
                'model_generation_status': 'timeout',
              },
              groundedSummaryJson: {},
            ),
          );
      _pendingAction = reply.pendingAction;
      if (mounted) {
        setState(() {
          if (reply.runtimeName != 'unavailable' &&
              reply.status != 'unavailable') {
            _modelReady = true;
          } else {
            unawaited(_checkModelReady());
          }
        });
      }
      _finishAssistantMessage(
        _homeMessageForReply(reply),
        isGiSummary: reply.toolTraceJson['task_contract'] == 'doctorSummary' ||
            reply.toolTraceJson['agent_intent'] == 'doctor_summary',
      );
      // Second refresh after response to catch any score changes the agent's
      // tool calls may have written to DB (symptom saves, check-in commits).
      unawaited(_refreshRiskScore());
    } catch (e) {
      final msg = e is StateError
          ? 'The AI model is not loaded. Tap "Set up Gemma Flares" to load Gemma 4.'
          : 'Something went wrong locally while preparing that response. Your data stayed on this iPhone.';
      _finishAssistantMessage(msg);
    }
  }

  String _homeMessageForReply(agent.LocalAgentReply reply) {
    final action = reply.pendingAction;
    if (action == null) return reply.message;
    if (action.type == 'symptom_review') {
      return '${reply.message}\n\nReply "confirm" to save, "edit" to change, or say "stop" / "cancel" to discard.';
    }
    if (action.type == 'medication_review') {
      return '${reply.message}\n\nReply "confirm" to save, "edit" to change, or say "stop" / "cancel" to discard.';
    }
    if (action.type == 'lab_review') {
      return '${reply.message}\n\nReply "confirm" to save these labs, "edit" to paste corrected text, or say "stop" / "cancel" to discard.';
    }
    return reply.message;
  }

  String? _deterministicPhotoReply(String userText) {
    return buildDeterministicPhotoReply(
      result: _lastPhotoIntakeResult,
      userText: userText,
      lastPhotoFilename: _lastPhotoFilename,
    );
  }

  void _appendLabImportConfirmationMessage(LabLoggingResult result) {
    final savedLabels = result.savedLabs
        .map((lab) => '${lab.labType} ${lab.valueNumeric} ${lab.unit}')
        .join(', ');
    final txIds = result.ragTransactionIdByLabId.values
        .where((tx) => tx.trim().isNotEmpty)
        .toList(growable: false);
    final validatedCount =
        result.ragValidatedByLabId.values.where((value) => value).length;
    final validationLine = txIds.isEmpty
        ? 'Saved to Health Records.'
        : validatedCount == txIds.length
            ? 'Saved and validated in local memory (${txIds.join(', ')}).'
            : 'Saved locally. Memory validation confirmed $validatedCount/${txIds.length} transaction${txIds.length == 1 ? '' : 's'} (${txIds.join(', ')}).';
    setState(() {
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text:
              'Saved ${result.savedLabs.length} lab value${result.savedLabs.length == 1 ? '' : 's'}: $savedLabels. $validationLine Tap "Scan a lab photo" to add another result.',
          timestamp: DateTime.now().toUtc(),
        ),
      );
    });
    _scrollToBottom();
  }

  Future<String?> _maybeHandlePendingActionConfirmation(String userText) async {
    final action = _pendingAction;
    if (action == null) return null;
    final lower = userText.toLowerCase().trim();
    final normalized = TextNormalizationService.normalizeForIntent(lower);
    // If the user issues a top-level "start over" command (e.g. "log a symptom")
    // while a review card is pending, drop the pending action and let the
    // message route normally. This prevents accidental saves.
    if (_looksLikeNewDraftCommand(normalized)) {
      _pendingAction = null;
      unawaited(
        AppServices.localAgentService.resetSession(
          reason: 'pending_action_abandoned_for_new_flow',
        ),
      );
      return null;
    }
    if (_isCancelPendingReply(normalized)) {
      _pendingAction = null;
      unawaited(
        AppServices.localAgentService.resetSession(
          reason: 'pending_action_cancelled',
        ),
      );
      return 'Cancelled. I did not save anything.';
    }
    if (_isEditPendingReply(normalized)) {
      final source = action.payloadJson['source_text']?.toString();
      _pendingAction = null;
      if (source != null && mounted) {
        _messageController.text = source;
        _messageController.selection = TextSelection.collapsed(
          offset: source.length,
        );
      }
      // Reset in-memory session so the next edited draft doesn't stitch prior
      // draft attempts into the extraction transcript.
      unawaited(
        AppServices.localAgentService.resetSession(
          reason: 'pending_action_edit',
        ),
      );
      return 'Loaded the draft back into the composer so you can edit it.';
    }
    if (!_isConfirmPendingReply(normalized)) return null;
    if (action.type == 'symptom_review') {
      final source = action.payloadJson['source_text']?.toString();
      if (source == null || source.trim().isEmpty) return null;

      // Use the already-extracted all_symptoms list from the payload when
      // available — avoids a second Gemma call and saves EVERY symptom that
      // was identified (e.g. "pooped 3 times AND bloating" → both saved).
      final rawAll = action.payloadJson['all_symptoms'];
      final allSymptoms = rawAll is List
          ? rawAll
              .whereType<Map>()
              .map((m) => Map<String, Object?>.from(m))
              .toList()
          : <Map<String, Object?>>[];

      _pendingAction = null;

      // Use the already-extracted payload for both single and multi-symptom
      // saves. By confirm time the user has reviewed the card — re-running
      // Gemma is redundant, adds 1-2 s latency, and risks diverging from what
      // the user approved. The multi-symptom path already did this correctly;
      // the single-symptom path previously called saveTranscript(preferGemma:true).
      if (allSymptoms.isNotEmpty) {
        final now = DateTime.now().toUtc();
        final ids = await AppServices.symptomLoggingService.saveAllFromPayload(
          allSymptoms: allSymptoms,
          sourceTranscript: source,
          loggedAt: now,
        );
        await _deletePendingReplacementSymptoms();
        // Human-readable labels using the same mapping as the review card.
        final labels = allSymptoms.map((s) {
          final t = s['symptom_type']?.toString() ?? 'symptom';
          return switch (t) {
            'diarrhea' ||
            'stool_frequency' ||
            'frequency' =>
              'Frequency / Increased Bowel Movements',
            'blood' || 'bleeding' || 'rectal_bleeding' => 'rectal bleeding',
            'pain' || 'abdominal_pain' => 'abdominal pain',
            _ => t.replaceAll('_', ' '),
          };
        }).toList(growable: false);
        final labelStr = labels.length == 2
            ? '${labels[0]} and ${labels[1]}'
            : labels.length >= 3
                ? '${labels.take(labels.length - 1).join(', ')}, and ${labels.last}'
                : labels.join(', ');
        // Reset session so the NEXT "log a symptom" starts fresh.
        unawaited(
          AppServices.localAgentService.resetSession(
            reason: ids.length == 1
                ? 'symptom_confirmed_single'
                : 'symptom_confirmed_multi',
          ),
        );
        _lastSavedSymptom = _RecentSymptomSave(
          ids: ids,
          label: labelStr,
          sourceText: source,
        );
        return 'Saved. ${ids.length == 1 ? 'Your $labelStr note' : '${ids.length} symptoms ($labelStr)'} '
            '${ids.length == 1 ? 'is' : 'are'} now in your health log.';
      }

      // Fallback: payload had no extracted symptoms (edge case — forced review
      // card with no structured extraction). Use deterministic parser only;
      // no Gemma call at confirm time.
      final result = await AppServices.symptomLoggingService.saveTranscript(
        transcript: source,
        preferGemma: false,
      );
      await _deletePendingReplacementSymptoms();
      unawaited(
        AppServices.localAgentService.resetSession(
          reason: 'symptom_confirmed_fallback',
        ),
      );
      final saved = result.savedSymptom;
      final label = _symptomLabel(saved.symptomType);
      _lastSavedSymptom = _RecentSymptomSave(
        ids: [if (saved.id != null) saved.id!],
        label: label,
        sourceText: source,
      );
      return 'Saved. Your $label note is now in your health log.';
    }
    if (action.type == 'lab_review') {
      final candidates = _labCandidatesFromPendingAction(action);
      if (candidates.isEmpty) return null;
      final result = await AppServices.labLoggingService.saveCandidates(
        candidates: candidates,
        reviewId: action.reviewId,
        source: 'home_chat_lab_review',
      );
      _pendingAction = null;
      // Clear the stale photo session state so the next "Scan a lab photo"
      // tap starts fresh instead of replaying the just-confirmed OCR text.
      setState(() {
        _lastPhotoIntakeResult = null;
        _lastPhotoFilename = null;
      });
      final labels = result.savedLabs
          .map((lab) => '${lab.labType} ${lab.valueNumeric} ${lab.unit}')
          .join(', ');
      final txIds = result.ragTransactionIdByLabId.values.toList(
        growable: false,
      );
      return [
        'Saved ${result.savedLabs.length} lab value${result.savedLabs.length == 1 ? '' : 's'}: $labels.',
        if (txIds.isNotEmpty)
          'Memory transaction${txIds.length == 1 ? '' : 's'}: ${txIds.join(', ')}.',
        'Tap "Scan a lab photo" to add another result.',
      ].join(' ');
    }
    if (action.type == 'medication_review') {
      final payload = action.payloadJson;
      final medicationName = payload['medication_name']?.toString().trim();
      final sourceText = payload['source_text']?.toString().trim();
      if (medicationName == null ||
          medicationName.isEmpty ||
          sourceText == null ||
          sourceText.isEmpty) {
        return null;
      }
      final loggedAt =
          DateTime.tryParse(payload['logged_at']?.toString() ?? '') ??
              DateTime.now().toUtc();
      final result =
          await AppServices.medicationLoggingService.saveConfirmedDraft(
        MedicationLoggingDraft(
          eventType: payload['event_type']?.toString() ?? 'medication_taken',
          medicationName: medicationName,
          dose: payload['dose']?.toString(),
          schedule: payload['schedule']?.toString(),
          notes: payload['notes']?.toString(),
          loggedAt: loggedAt,
          sourceTranscript: sourceText,
          confidence:
              ((payload['confidence'] as num?)?.toDouble().clamp(0, 1) ?? 0.9)
                  .toDouble(),
        ),
      );
      _pendingAction = null;
      unawaited(
        AppServices.localAgentService.resetSession(
          reason: 'medication_confirmed',
        ),
      );
      final tx = result.ragTransactionId.trim();
      final memoryLine = tx.isEmpty
          ? 'Saved to your medication timeline.'
          : 'Saved to your medication timeline and queued in local memory ($tx).';
      return '$medicationName was saved as a ${result.savedEvent.eventType == 'medication_skipped' ? 'missed/skipped' : 'taken'} medication or supplement entry. $memoryLine';
    }
    return null;
  }

  Future<String?> _maybeHandleSavedSymptomFollowup(String userText) async {
    final lower = userText.toLowerCase().trim();
    final latest = _lastSavedSymptom;
    final asksSaved = lower.contains('did you log') ||
        lower.contains('was that saved') ||
        lower.contains('is that saved') ||
        lower.contains('did that save');
    if (asksSaved) {
      if (latest == null || latest.ids.isEmpty) {
        return 'I do not have a confirmed symptom save in this chat yet.';
      }
      return 'Yes. I saved ${latest.ids.length == 1 ? 'that symptom' : 'those symptoms'} (${latest.label}) to your timeline.';
    }
    if (latest == null || latest.ids.isEmpty) return null;

    final asksRemove = lower == 'remove it' ||
        lower == 'delete it' ||
        lower == 'remove last symptom' ||
        lower == 'delete last symptom' ||
        lower.contains('remove the last symptom') ||
        lower.contains('delete the last symptom');
    if (asksRemove) {
      var deleted = 0;
      for (final id in latest.ids) {
        deleted += await AppServices.wearableSampleRepository.deleteSymptom(id);
      }
      _lastSavedSymptom = null;
      _pendingSavedSymptomReplacementIds = null;
      return deleted == 0
          ? 'I could not find that saved symptom to remove.'
          : 'Removed ${deleted == 1 ? 'that symptom' : 'those symptoms'} from your timeline.';
    }

    final asksEdit = lower == 'edit it' ||
        lower == 'edit that' ||
        lower == 'change it' ||
        lower == 'fix it' ||
        lower.contains('edit the last symptom') ||
        lower.contains('change the last symptom');
    if (!asksEdit) return null;
    _pendingSavedSymptomReplacementIds = latest.ids;
    final source = latest.sourceText;
    if (mounted) {
      _messageController.text = source;
      _messageController.selection = TextSelection.collapsed(
        offset: source.length,
      );
    }
    return 'Loaded the last saved symptom back into the composer. Edit it and send it again; when you confirm the new review, I will replace the old saved entry.';
  }

  Future<void> _deletePendingReplacementSymptoms() async {
    final ids = _pendingSavedSymptomReplacementIds;
    if (ids == null || ids.isEmpty) return;
    for (final id in ids) {
      await AppServices.wearableSampleRepository.deleteSymptom(id);
    }
    _pendingSavedSymptomReplacementIds = null;
  }

  String _symptomLabel(String type) {
    return switch (type) {
      'diarrhea' ||
      'stool_frequency' ||
      'frequency' =>
        'Frequency / Increased Bowel Movements',
      'blood' || 'bleeding' || 'rectal_bleeding' => 'rectal bleeding',
      'pain' || 'abdominal_pain' => 'abdominal pain',
      _ => type.replaceAll('_', ' '),
    };
  }

  // ── Structured check-in state machine ──────────────────────────────────────
  // Runs entirely deterministically — no Gemma call, zero latency per question.
  // Detects start → asks 5 IBD-validated questions one at a time → saves
  // Pro2SurveyRecord → refreshes the risk strip.

  bool _isCheckInStartRequest(String lower) {
    final n = lower
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return n == 'check in' ||
        n == 'checkin' ||
        n == 'start a check in' ||
        n.contains('start a check in') ||
        n == 'start check in' ||
        n.contains('start check in') ||
        n == 'daily check in' ||
        n.contains('daily check in') ||
        n.contains('daily ibd check') ||
        n == 'start daily check in' ||
        n.contains('start daily check in') ||
        n == 'check me in' ||
        n.contains('check me in') ||
        n.contains('do a check in') ||
        n.contains('run a check in');
  }

  Future<String?> _maybeHandleCheckIn(String userText) async {
    final lower = userText.toLowerCase().trim();

    // Cancel an active check-in with any natural-language exit signal.
    if (_activeCheckIn != null) {
      if (_isCancelPendingReply(lower) || lower == 'quit' || lower == 'exit') {
        setState(() => _activeCheckIn = null);
        return 'Check-in cancelled. Nothing was saved.';
      }
    }

    // Start a new check-in
    if (_isCheckInStartRequest(lower)) {
      if (_activeCheckIn != null) {
        // Already mid-session — restart
        setState(() => _activeCheckIn = null);
      }
      // Load disease type for question routing
      String diseaseType = 'CD'; // default
      try {
        final profile = await AppServices.profileService.loadProfile();
        diseaseType = profile.diseaseType ?? 'CD';
      } catch (_) {}
      final session = _CheckInSession(diseaseType: diseaseType);
      setState(() => _activeCheckIn = session);
      return session.currentQuestion;
    }

    // Active session — process user's answer and advance
    final session = _activeCheckIn;
    if (session == null) return null;

    final advance = session.processAnswer(userText);
    if (!advance) {
      // Answer not parseable — re-ask
      return 'I didn\'t catch that.\n\n${session.currentQuestion}';
    }

    setState(() {}); // update progress indicator

    if (session.isComplete) {
      setState(() => _activeCheckIn = null);
      // Save to DB
      final saved = await _saveCheckInSession(session);
      unawaited(_refreshRiskScore());
      return saved;
    }

    return session.currentQuestion;
  }

  Future<String> _saveCheckInSession(_CheckInSession session) async {
    try {
      final now = DateTime.now().toUtc();
      final today = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final answers = session.answers;
      final diseaseType = session.diseaseType;

      // Compute PRO-2 score (Harvey-Bradshaw simplified for CD, Mayo lite for UC)
      final pain = answers['abdominal_pain'] ?? 0; // 0-3
      final stool = answers['stool_frequency'] ?? 0; // 0-3
      final bleeding = answers['rectal_bleeding'] ?? 0; // 0-3
      final wellbeing = answers['general_wellbeing'] ?? 0; // 0-3
      final urgency = answers['urgency'] ?? 0; // 0-3

      // CD PRO-2: pain(0-3) × 7 + stool(0-3); flare if ≥ 8
      // UC PRO-2: bleeding(0-3) + stool(0-3); flare if ≥ 2
      late double pro2Score;
      late bool isFlare;
      late String scoreVersion;

      if (diseaseType == 'UC') {
        pro2Score = (bleeding + stool).toDouble();
        isFlare = pro2Score >= 2;
        scoreVersion = Pro2SurveyRecord.ucV1BleedingStool;
      } else {
        // CD (and IBS treated as CD-like for scoring)
        pro2Score = (pain * 2 + stool).toDouble();
        isFlare = pro2Score >= 4;
        scoreVersion = Pro2SurveyRecord.cdV2Pain2Stool1;
      }

      final notes = IbdCheckInService.encodeNotes(
        diseaseType: diseaseType,
        dailyCore: {
          'abdominal_pain': pain,
          'stool_frequency': stool,
          'rectal_bleeding': bleeding,
          'general_wellbeing': wellbeing,
          'urgency': urgency,
        },
        completedSections: const ['core'],
        source: 'gemma_chat_checkin',
      );

      final record = Pro2SurveyRecord(
        surveyDate: today,
        diseaseType: diseaseType,
        cdAbdominalPain: diseaseType != 'UC' ? pain : null,
        cdStoolFrequency: diseaseType != 'UC' ? stool : null,
        ucRectalBleeding: diseaseType == 'UC' ? bleeding : null,
        ucStoolFrequency: diseaseType == 'UC' ? stool : null,
        pro2Score: pro2Score,
        isFlare: isFlare,
        scoreVersion: scoreVersion,
        notes: notes,
        createdAt: now,
      );
      final surveyId =
          await AppServices.wearableSampleRepository.insertPro2Survey(record);
      try {
        await AppServices.ragMemoryService.writeAndVerify(
          transactionId: 'checkin_tx_$surveyId',
          sourceType: 'pro2_survey',
          sourceId: '$surveyId',
          text: IbdCheckInService.memoryTextForSurvey(
            surveyId: surveyId,
            survey: record,
          ),
          metadata: IbdCheckInService.memoryMetadataForSurvey(
            surveyId: surveyId,
            survey: record,
          ),
        );
      } catch (_) {
        // Check-in persistence should remain reliable even if RAG indexing
        // temporarily fails; retry can be triggered from settings.
      }

      // Severity-tiered completion note — escalates language proportionally.
      // Total score for CD: pain(0-3) + stool(0-3) + urgency(0-3) + wellbeing(0-3) = 0-12
      // Total score for UC: bleeding(0-3) + stool(0-3) + urgency(0-3) + wellbeing(0-3) = 0-12
      final totalScore =
          (diseaseType == 'UC' ? bleeding : pain) + stool + urgency + wellbeing;
      final hasSevereBlood =
          (diseaseType == 'UC' ? bleeding : 0) >= 2 || bleeding >= 2;

      final String completionNote;
      if (hasSevereBlood || totalScore >= 11) {
        completionNote =
            '\n\nYour scores are in the severe range — your body is working hard right now. '
            'Please check in with your GI team today. Tap "Create a GI summary" to build a quick note for them.';
      } else if (totalScore >= 8) {
        completionNote =
            '\n\nThings are a bit rough today — that\'s okay, you\'re paying attention to your body. '
            'Rest when you can, and log anything new as it comes up.';
      } else if (isFlare) {
        completionNote =
            '\n\nYour answers show some flare signals today. Keep an eye on things and log any new symptoms as they come up.';
      } else {
        completionNote = wellbeing >= 2
            ? '\n\nLet me know if you want to talk through how you\'re feeling.'
            : '';
      }

      return 'Check-in saved for today.\n\nSummary: pain $pain/3 · stool $stool/3 · ${diseaseType == "UC" ? "bleeding $bleeding/3 · " : ""}urgency $urgency/3 · wellbeing $wellbeing/3$completionNote';
    } catch (e) {
      return 'Check-in answers collected but could not be saved (error: $e). Try again in a moment.';
    }
  }

  bool _isConfirmPendingReply(String lower) =>
      PendingReplyClassifierService.isConfirmation(lower);

  /// Returns true when the user clearly wants to abandon the current pending
  /// action (symptom review, lab review, etc.). "quit" alone is intentionally
  /// excluded here — it exits the app and is handled upstream.
  bool _isCancelPendingReply(String lower) {
    final t = TextNormalizationService.normalizeForIntent(lower).trim();
    // Exact-match shortcuts
    const exactCancels = {
      'cancel',
      'discard',
      'remove',
      'remove it',
      'delete',
      'delete it',
      'never mind',
      'nevermind',
      'nope',
      'nah',
      'no',
      'no thanks',
      'nope thanks',
      'stop',
      'end',
      'clear',
      'abort',
      'exit',
      'forget it',
      'forget that',
      'scratch that',
      'skip it',
      'skip',
      'leave it',
      'not now',
      'start over',
      'reset',
      'done',
      'done with this',
      'stop this',
      'stop that',
      'go back',
    };
    if (exactCancels.contains(t)) return true;
    // Prefix patterns
    if (t.startsWith('cancel') ||
        t.startsWith('discard') ||
        t.startsWith('never mind') ||
        t.startsWith('nevermind') ||
        t.startsWith('forget') ||
        t.startsWith('scratch') ||
        t.startsWith('stop ') ||
        t.startsWith('end ') ||
        t.startsWith('abort') ||
        t.startsWith('skip')) {
      return true;
    }
    return false;
  }

  bool _isEditPendingReply(String lower) =>
      PendingReplyClassifierService.isEditRequest(lower);

  bool _looksLikeNewDraftCommand(String normalizedLower) {
    const exact = {
      'log a symptom',
      'log symptom',
      'log symptoms',
      'record a symptom',
      'record symptom',
      'save a symptom',
      'save symptom',
      'scan a lab photo',
      'scan lab photo',
      'scan photo',
      'scan a photo',
    };
    if (exact.contains(normalizedLower)) return true;
    if (normalizedLower.startsWith('scan a lab photo ')) return true;
    if (normalizedLower.startsWith('scan lab photo ')) return true;
    return false;
  }

  List<GemmaLabCandidate> _labCandidatesFromPendingAction(
    agent.ChatPendingAction action,
  ) {
    final rawCandidates = action.payloadJson['candidate_labs'];
    if (rawCandidates is! List) return const [];
    return rawCandidates.whereType<Map>().map((raw) {
      final json = Map<String, Object?>.from(raw);
      return GemmaLabCandidate(
        labType: json['lab_type']?.toString() ?? 'unknown',
        valueNumeric: (json['value_numeric'] as num?)?.toDouble() ?? 0,
        unit: json['unit']?.toString() ?? '',
        drawnDate: json['drawn_date']?.toString() ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        referenceHigh: (json['reference_high'] as num?)?.toDouble(),
        labName: json['lab_name']?.toString(),
        orderingProvider: json['ordering_provider']?.toString(),
        abnormalFlag: json['abnormal_flag'] as bool?,
        sourceTextSnippet: json['source_text_snippet']?.toString(),
      );
    }).toList(growable: false);
  }

  Future<void> _maybeStartOpeningPrompt() async {
    if (_openingPromptStarted || !_modelReady) return;
    if (_isGenerating) return;
    _openingPromptStarted = true;
    Map<String, Object?> context = const {};
    try {
      context = await _buildGroundedContext();
    } catch (_) {
      context = await _buildGroundedContext();
    }
    final decision = await AppServices.proactiveOpenService
        .evaluateFromGroundedContext(context)
        .catchError(
          (_) => const ProactiveOpenDecision(
            shouldSpeakFirst: false,
            reason: 'proactive_open_unavailable',
          ),
        );
    if (!decision.shouldSpeakFirst) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _isGenerating = true;
      _streamBuffer.clear();
      _streamingText = '';
    });
    final startedAt = DateTime.now().toUtc();
    var assistantText = '';
    try {
      final systemPrompt = _systemPromptForOpening(context);
      var lastFlush = DateTime.now();
      await for (final chunk in AppServices.gemmaRouterService.sendChat(
        _openingPromptInstruction,
        taskType: 'proactive_open',
        systemPrompt: systemPrompt,
        groundedContext: context,
        conversationId: _sessionId,
      )) {
        assistantText += chunk;
        _streamBuffer.write(chunk);
        final now = DateTime.now();
        if (now.difference(lastFlush).inMilliseconds < 33) continue;
        lastFlush = now;
        if (!mounted) return;
        setState(() => _streamingText = _streamBuffer.toString());
        _scrollToBottom();
      }
    } catch (_) {
      context = await _buildGroundedContext();
    }
    if (assistantText.trim().isEmpty ||
        assistantText.contains('could not generate a response')) {
      assistantText = _deterministicOpeningPrompt(context);
    }
    _finishAssistantMessage(assistantText);
    await _persistTurn(
      userText: '[app_open_proactive_checkin]',
      assistantText: assistantText,
      startedAt: startedAt,
      groundedContext: context,
      toolTrace: {
        'status': 'proactive_open',
        'reason': decision.reason,
        'trigger_type': decision.triggerType,
        'open_count_today': decision.openCountToday,
        'minutes_since_last_open': decision.minutesSinceLastOpen,
      },
      isProactiveOpen: true,
    );
  }

  static const _openingPromptInstruction =
      'Start this app session with exactly one warm, useful check-in question. Use only grounded context. If recent check-ins show high stool frequency, ask about bathroom or stool frequency today. If recent symptoms show pain, ask about pain. If data is sparse, ask how their gut is feeling today. One sentence only.';

  String _systemPromptForOpening(Map<String, Object?> context) =>
      prompts.buildSystemPrompt(
        'proactive_open',
        dataRichness: _openingDataRichness(context),
      );

  String _openingDataRichness(Map<String, Object?> context) {
    var signals = 0;
    final risk = context['cached_risk'];
    if (risk is Map && risk['risk_score'] != null) signals++;
    final symptoms = context['recent_symptoms'];
    if (symptoms is List && symptoms.isNotEmpty) signals++;
    final checkins = context['recent_checkins'];
    if (checkins is List && checkins.isNotEmpty) signals++;
    if (signals == 0) return 'none';
    if (signals == 1) return 'sparse';
    return 'rich';
  }

  Future<Map<String, Object?>> _buildGroundedContext() async {
    final recentSymptoms = await AppServices.wearableSampleRepository
        .getRecentSymptoms(limit: 8)
        .catchError((_) => const <SymptomRecord>[]);
    final recentCheckins = await AppServices.wearableSampleRepository
        .getRecentPro2Surveys(limit: 5)
        .catchError((_) => const <Pro2SurveyRecord>[]);
    return {
      'current_date': DateTime.now().toUtc().toIso8601String(),
      'cached_risk': {
        // riskScore is stored on the 0–100 integer scale by risk_engine_service.
        // Both dashboard strip and Gemma grounding read from flare_risk_scores
        // via getLatestUserFacingFlareRiskScore() — single source of truth.
        // Never multiply by 100 in UI code; the value is already a percentage.
        'risk_score': _cachedRiskScore,
        'risk_band': _cachedRiskBand,
        // Horizon probs are in 0–1 scale from featureSnapshotJson.
        // Display in the system prompt as percentages for Gemma readability.
        'outlook_7d_pct':
            _outlook7d != null ? (_outlook7d! * 100).round() : null,
        'outlook_14d_pct':
            _outlook14d != null ? (_outlook14d! * 100).round() : null,
        'outlook_21d_pct':
            _outlook21d != null ? (_outlook21d! * 100).round() : null,
        // Human-readable interpretation for Gemma to reference in chat.
        'interpretation': _riskInterpretation(
          riskScore: _cachedRiskScore,
          riskBand: _cachedRiskBand,
          outlook7dPct: _outlook7d != null ? (_outlook7d! * 100).round() : null,
        ),
        'source': 'flare_risk_scores_db',
      },
      'recent_visible_messages': _messages
          .where((message) => message.text.trim().isNotEmpty)
          .toList(growable: false)
          .reversed
          .take(6)
          .map(
            (message) => {
              'role': message.role,
              'text': message.text,
              'timestamp': message.timestamp.toUtc().toIso8601String(),
            },
          )
          .toList(growable: false)
          .reversed
          .toList(growable: false),
      'recent_symptoms': recentSymptoms
          .map(
            (symptom) => {
              'type': symptom.symptomType,
              'severity': symptom.severity,
              'logged_at': symptom.loggedAt.toUtc().toIso8601String(),
            },
          )
          .toList(growable: false),
      'recent_checkins': recentCheckins
          .map(
            (checkin) => {
              'date': checkin.surveyDate,
              'disease_type': checkin.diseaseType,
              'cd_stool_frequency': checkin.cdStoolFrequency,
              'uc_stool_frequency': checkin.ucStoolFrequency,
              'cd_abdominal_pain': checkin.cdAbdominalPain,
              'uc_rectal_bleeding': checkin.ucRectalBleeding,
              'is_flare': checkin.isFlare,
            },
          )
          .toList(growable: false),
      'safety': {'local_only': true, 'non_diagnostic': true},
    };
  }

  /// Returns a one-sentence English interpretation of the current flare risk
  /// that Gemma can include verbatim in grounding context.  Keeps the model
  /// from having to infer semantics from raw numbers.
  String? _riskInterpretation({
    required double? riskScore,
    required String riskBand,
    required int? outlook7dPct,
  }) {
    if (riskScore == null && outlook7dPct == null) return null;
    final signalIndex = riskScore?.clamp(0.0, 100.0).round();
    if (outlook7dPct != null) {
      final signalTail =
          signalIndex == null ? '' : ' Today signal index is $signalIndex/100.';
      switch (riskBand) {
        case 'critical':
          return 'Estimated 7-day flare chance is $outlook7dPct% (critical risk). Monitor symptoms closely and contact your care team if worsening.$signalTail';
        case 'high':
          return 'Estimated 7-day flare chance is $outlook7dPct% (high risk). Watch for new symptoms over the next 24-48 hours.$signalTail';
        case 'moderate':
          return 'Estimated 7-day flare chance is $outlook7dPct% (moderate risk). Keep routines steady and continue logging changes.$signalTail';
        default:
          return 'Estimated 7-day flare chance is $outlook7dPct% (low risk). Signals look stable right now.$signalTail';
      }
    }

    final pct = signalIndex!;
    switch (riskBand) {
      case 'critical':
        return 'Current flare signal index is critical at $pct/100. Keep monitoring and contact your care team if symptoms worsen.';
      case 'high':
        return 'Current flare signal index is high at $pct/100. Watch for new or worsening symptoms.';
      case 'moderate':
        return 'Current flare signal index is moderate at $pct/100. Maintain routines and log any changes.';
      default:
        return 'Current flare signal index is low at $pct/100. Things look stable.';
    }
  }

  String _deterministicOpeningPrompt(Map<String, Object?> context) {
    final checkins = context['recent_checkins'];
    if (checkins is List) {
      for (final item in checkins) {
        if (item is! Map) continue;
        final stool = item['cd_stool_frequency'] ?? item['uc_stool_frequency'];
        if (stool is num && stool >= 2) {
          return 'How many times have you used the bathroom today?';
        }
      }
    }
    final symptoms = context['recent_symptoms'];
    if (symptoms is List) {
      for (final item in symptoms) {
        if (item is! Map) continue;
        final type = item['type']?.toString() ?? '';
        if (type.contains('pain') || type.contains('cramp')) {
          return 'How has your gut pain been today?';
        }
      }
    }
    return 'How\'s your gut feeling today?';
  }

  void _finishAssistantMessage(
    String text, {
    bool clearPendingAction = false,
    bool isGiSummary = false,
  }) {
    if (!mounted) return;
    setState(() {
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text: text.trim(),
          timestamp: DateTime.now().toUtc(),
          isGiSummary: isGiSummary,
        ),
      );
      _isGenerating = false;
      _streamingText = '';
      _streamBuffer.clear();
      // Clear pending action atomically when the confirm/cancel path is done
      // so the review card dismisses in the same frame as the reply message.
      if (clearPendingAction) _pendingAction = null;
    });
    _scrollToBottom();
  }

  /// Generates a PDF from a GI summary message and opens the iOS share sheet.
  /// Shares only the PDF artifact (no plain-text companion share).
  Future<void> _shareGiSummaryMessage(ChatMessage message) async {
    if (_isSharingGiSummary) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Share already in progress.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _isSharingGiSummary = true;

    final shareOrigin = resolveShareSheetOrigin(context);
    // Show a brief loading indicator via a snackbar so the user knows work is
    // happening — PDF rendering can take ~0.5–1s on device.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Preparing PDF…'),
          duration: Duration(seconds: 3),
        ),
      );
    }
    try {
      final usedPdfShare = await shareGiSummaryPdfFirst(
        message: message,
        pdfService: AppServices.doctorSummaryPdfService,
        sharePdf: (file) => Share.shareXFiles(
          [file],
          subject: 'Gemma Flares GI Visit Summary',
          sharePositionOrigin: shareOrigin,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (!usedPdfShare) return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      rethrow;
    } finally {
      _isSharingGiSummary = false;
    }
  }

  Future<void> _persistTurn({
    required String userText,
    required String assistantText,
    required DateTime startedAt,
    Map<String, Object?> groundedContext = const {},
    Map<String, Object?> toolTrace = const {},
    bool isProactiveOpen = false,
  }) async {
    await AppServices.wearableSampleRepository.insertConversation(
      ConversationRecord(
        createdAt: startedAt,
        userMessage: userText,
        assistantMessage: assistantText,
        toolTraceJson: toolTrace,
        groundedSummaryJson: groundedContext,
        sessionId: _sessionId,
        isProactiveOpen: isProactiveOpen,
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _stopGeneration() {
    AppServices.gemmaRouterService.cancelCurrentGeneration();
    if (mounted) {
      setState(() {
        _isGenerating = false;
        _streamingText = '';
      });
    }
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<String?>(
      MaterialPageRoute<String?>(
        fullscreenDialog: true,
        builder: (_) => const SettingsModal(),
      ),
    );
    unawaited(_loadProfileDiseaseType());
    if (result == 'reset_setup' && mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const SetupWizardDialog(),
      );
    }
  }

  void _onStarterPrompt(String prompt) {
    _dismissKeyboard();
    _messageController.text = prompt;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    _onSendMessage(prompt);
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissKeyboard,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header row ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Gemma Flares',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              if (_profileDiseaseType != null) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant
                                          .withAlpha(140),
                                    ),
                                  ),
                                  child: Text(
                                    _diseaseLabelForBadge(_profileDiseaseType!),
                                    style:
                                        Theme.of(context).textTheme.labelSmall,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 1),
                          _GemmaStatusBadge(
                            onRetry: () => AppServices.modelReadiness
                                .warmLoad(AppServices.localModelRuntime),
                          ),
                        ],
                      ),
                    ),
                    if (_messages.isNotEmpty)
                      Semantics(
                        label: 'Copy all messages',
                        button: true,
                        child: IconButton(
                          icon: const Icon(Icons.copy_outlined),
                          tooltip: 'Copy all',
                          iconSize: 20,
                          onPressed: _copyAllChat,
                        ),
                      ),
                    if (_messages.isNotEmpty)
                      Semantics(
                        label: 'Clear chat history',
                        button: true,
                        child: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Clear chat',
                          iconSize: 20,
                          onPressed: _clearChat,
                        ),
                      ),
                  ],
                ),
              ),
              // ── Risk strip ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: RiskStripWidget(
                  riskScore: _cachedRiskScore,
                  riskBand: _cachedRiskBand,
                  outlook7d: _outlook7d,
                  outlook14d: _outlook14d,
                  outlook21d: _outlook21d,
                ),
              ),
              Expanded(
                child: ChatSurfaceWidget(
                  isGenerating: _isGenerating,
                  streamingText: _streamingText,
                  scrollController: _scrollController,
                  messages: _messages,
                  onStarterPrompt: _onStarterPrompt,
                  onShareMessage: _shareGiSummaryMessage,
                ),
              ),
              _PromptRail(
                prompts: prompts.kPromptPresetLabels,
                enabled: !_isGenerating,
                onPrompt: _onStarterPrompt,
              ),
              ComposerWidget(
                controller: _messageController,
                isGenerating: _isGenerating,
                onSend: _onSendMessage,
                onOpenSettings: _openSettings,
                onStopGeneration: _stopGeneration,
                onCameraPressed: _showCameraSheet,
                // Voice is handled inside ComposerWidget; no snackbar stub.
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Gemma model status badge — sits below the "Gemma Flares" title at ~50% the
// title font size. Tapping retries the warm-load; shows restart hint on
// missing/corrupt state.
// ---------------------------------------------------------------------------

class _GemmaStatusBadge extends StatelessWidget {
  const _GemmaStatusBadge({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppServices.modelReadiness,
      builder: (context, _) {
        final state = AppServices.modelReadiness.state;
        final (label, color, showDot) = switch (state) {
          ModelReadinessState.loading => (
              'Gemma E2B • Loading...',
              Theme.of(context).colorScheme.outline,
              false,
            ),
          ModelReadinessState.ready => (
              'Gemma E2B • Installed',
              const Color(0xFF2E7D32), // green-800
              true,
            ),
          ModelReadinessState.missing => (
              'Gemma E2B • Not installed · Tap to retry',
              Theme.of(context).colorScheme.error,
              true,
            ),
          ModelReadinessState.corrupt => (
              'Gemma E2B • Load failed · Tap to retry',
              Theme.of(context).colorScheme.error,
              true,
            ),
        };

        final titleStyle = Theme.of(context).textTheme.titleMedium;
        final badgeFontSize = (titleStyle?.fontSize ?? 16) * 0.5;

        Widget badge = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showDot) ...[
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: badgeFontSize,
                color: color,
                fontWeight: FontWeight.w500,
                height: 1.0,
              ),
            ),
          ],
        );

        if (state == ModelReadinessState.missing ||
            state == ModelReadinessState.corrupt) {
          badge = GestureDetector(
            onTap: () async {
              await onRetry();
              // If still broken after retry, prompt user to restart.
              if (context.mounted && AppServices.modelReadiness.isBroken) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Close and reopen Gemma Flares to reinstall Gemma 4.',
                    ),
                    duration: Duration(seconds: 5),
                  ),
                );
              }
            },
            child: badge,
          );
        }

        return badge;
      },
    );
  }
}

class _PromptRail extends StatelessWidget {
  const _PromptRail({
    required this.prompts,
    required this.enabled,
    required this.onPrompt,
  });

  final List<String> prompts;
  final bool enabled;
  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant.withAlpha(70)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: prompts.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final prompt = prompts[index];
            return ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(prompt),
              avatar: Icon(_promptIcon(prompt), size: 16),
              onPressed: enabled ? () => onPrompt(prompt) : null,
            );
          },
        ),
      ),
    );
  }

  IconData _promptIcon(String prompt) {
    final lower = prompt.toLowerCase();
    if (lower.contains('check-in')) return Icons.fact_check_outlined;
    if (lower.contains('symptom')) return Icons.edit_note_outlined;
    if (lower.contains('lab')) return Icons.science_outlined;
    if (lower.contains('photo') || lower.contains('scan')) {
      return Icons.camera_alt_outlined;
    }
    if (lower.contains('summary') || lower.contains('gi')) {
      return Icons.summarize_outlined;
    }
    if (lower.contains('risk') || lower.contains('watch')) {
      return Icons.monitor_heart_outlined;
    }
    if (lower.contains('memory')) return Icons.storage_outlined;
    return Icons.chat_bubble_outline;
  }
}

class _RecentSymptomSave {
  const _RecentSymptomSave({
    required this.ids,
    required this.label,
    required this.sourceText,
  });

  final List<int> ids;
  final String label;
  final String sourceText;
}

// ── Check-in state machine ─────────────────────────────────────────────────
// Five IBD-validated questions asked one at a time.  No Gemma involved —
// deterministic, immediate, stores a proper Pro2SurveyRecord.
//
// Question set (disease-type aware):
//  CD / default:  1. Abdominal pain (0-3) · 2. Stool frequency vs normal (0-3)
//                 3. Rectal bleeding? (0-3) · 4. Urgency (0-3)
//                 5. General wellbeing (0-3)
//  UC:            1. Stool frequency (0-3) · 2. Rectal bleeding (0-3)
//                 3. Abdominal pain (0-3) · 4. Urgency (0-3)
//                 5. General wellbeing (0-3)
//
// Scale: 0=none · 1=mild · 2=moderate · 3=severe

class _CheckInQuestion {
  const _CheckInQuestion({
    required this.key,
    required this.text,
    required this.hint,
    required this.scale,
  });

  final String key;
  final String text;
  final String hint;
  final String scale; // displayed under the question
}

class _CheckInSession {
  _CheckInSession({required this.diseaseType})
      : _questions = diseaseType == 'UC' ? _ucQuestions : _cdQuestions,
        answers = {};

  static const _scaleReplyHint =
      'Reply with 0, 1, 2, or 3. Say "cancel" to stop.';

  final String diseaseType;
  final List<_CheckInQuestion> _questions;
  final Map<String, int> answers;
  int _step = 0;

  static const _cdQuestions = [
    _CheckInQuestion(
      key: 'abdominal_pain',
      text: 'How\'s your belly pain or cramping right now?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = mild · 2 = moderate · 3 = severe',
    ),
    _CheckInQuestion(
      key: 'stool_frequency',
      text: 'Compared to your normal, how many extra bathroom trips today?',
      hint: _scaleReplyHint,
      scale: '0 = none extra · 1 = 1–2 extra · 2 = 3–4 extra · 3 = 5+ extra',
    ),
    _CheckInQuestion(
      key: 'rectal_bleeding',
      text: 'Any blood in your stool today?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = streaks · 2 = obvious blood · 3 = mostly blood',
    ),
    _CheckInQuestion(
      key: 'urgency',
      text: 'Any urgent need to use the bathroom (can\'t hold it)?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = mild · 2 = moderate · 3 = severe',
    ),
    _CheckInQuestion(
      key: 'general_wellbeing',
      text: 'How\'s your general wellbeing today?',
      hint: _scaleReplyHint,
      scale: '0 = well · 1 = slightly below par · 2 = poor · 3 = very poor',
    ),
  ];

  static const _ucQuestions = [
    _CheckInQuestion(
      key: 'stool_frequency',
      text: 'How many extra bowel movements compared to your normal today?',
      hint: _scaleReplyHint,
      scale: '0 = none extra · 1 = 1–2 extra · 2 = 3–4 extra · 3 = 5+ extra',
    ),
    _CheckInQuestion(
      key: 'rectal_bleeding',
      text: 'Any blood in your stool today?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = streaks · 2 = obvious blood · 3 = mostly blood',
    ),
    _CheckInQuestion(
      key: 'abdominal_pain',
      text: 'How\'s your belly cramping or pain?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = mild · 2 = moderate · 3 = severe',
    ),
    _CheckInQuestion(
      key: 'urgency',
      text: 'Any urgency — needing to rush to the bathroom?',
      hint: _scaleReplyHint,
      scale: '0 = none · 1 = mild · 2 = moderate · 3 = severe',
    ),
    _CheckInQuestion(
      key: 'general_wellbeing',
      text: 'How\'s your overall wellbeing today?',
      hint: _scaleReplyHint,
      scale: '0 = well · 1 = slightly below par · 2 = poor · 3 = very poor',
    ),
  ];

  int get totalSteps => _questions.length;
  int get currentStep => _step;
  bool get isComplete => _step >= _questions.length;

  String get currentQuestion {
    if (isComplete) return '';
    final q = _questions[_step];
    final progress = '(${_step + 1}/${_questions.length})';
    return '${q.text} $progress\n${q.scale}\n${q.hint}';
  }

  String get hint => isComplete ? '' : _questions[_step].hint;

  /// Parse and store the user's answer.  Returns true if the answer was valid.
  bool processAnswer(String userText) {
    if (isComplete) return false;
    final q = _questions[_step];
    final val = _parseScale(userText);
    if (val == null) return false;
    answers[q.key] = val;
    _step++;
    return true;
  }

  /// Parse natural language or numeric 0–3 scale answers.
  static int? _parseScale(String text) {
    final t = text.toLowerCase().trim();
    // Direct numeric
    if (t == '0' ||
        t == 'none' ||
        t == 'no' ||
        t == 'nope' ||
        t == 'nada' ||
        t == 'nothing') {
      return 0;
    }
    if (t == '1' ||
        t == 'mild' ||
        t == 'slight' ||
        t == 'a little' ||
        t == 'a bit' ||
        t == 'barely') {
      return 1;
    }
    if (t == '2' ||
        t == 'moderate' ||
        t == 'medium' ||
        t == 'some' ||
        t == 'somewhat' ||
        t == 'kind of') {
      return 2;
    }
    if (t == '3' ||
        t == 'severe' ||
        t == 'bad' ||
        t == 'very bad' ||
        t == 'awful' ||
        t == 'terrible' ||
        t == 'a lot' ||
        t == 'lots' ||
        t == 'worst') {
      return 3;
    }
    // "well" → 0 for wellbeing question
    if (t == 'well' || t == 'good' || t == 'great' || t == 'fine') {
      return 0;
    }
    // Extract first digit
    final m = RegExp(r'\b([0-3])\b').firstMatch(t);
    if (m != null) return int.parse(m.group(1)!);
    return null;
  }
}
