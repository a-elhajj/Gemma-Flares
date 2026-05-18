import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/app_services.dart';
import '../../core/services/symptom_logging_service.dart';
import '../../core/services/symptom_parser_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/model_use_badge.dart';

class VoiceLogScreen extends StatefulWidget {
  const VoiceLogScreen({super.key});

  @override
  State<VoiceLogScreen> createState() => _VoiceLogScreenState();
}

class _VoiceLogScreenState extends State<VoiceLogScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final stt.SpeechToText _speech = stt.SpeechToText();
  SymptomLoggingResult? _lastResult;
  String? _statusMessage;
  bool _saving = false;
  bool _speechAvailable = false;
  bool _isListening = false;
  late AnimationController _pulseCtrl;

  // Pre-save review state — non-null while waiting for user confirmation.
  SymptomParseResult? _pendingParseResult;
  String? _pendingText;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _initSpeech();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _controller.dispose();
    _speech.stop();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _isListening = false;
          _statusMessage = 'Speech error: ${error.errorMsg}';
        });
      },
    );
    if (mounted) setState(() => _speechAvailable = available);
  }

  Future<void> _toggleListening() async {
    FocusScope.of(context).unfocus();
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }
    if (!_speechAvailable) {
      setState(
        () =>
            _statusMessage = 'Speech recognition not available on this device.',
      );
      return;
    }
    setState(() {
      _isListening = true;
      _statusMessage = 'Listening… speak your symptom.';
      _lastResult = null;
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _controller.text = result.recognizedWords);
        if (result.finalResult) {
          setState(() {
            _isListening = false;
            _statusMessage = 'Got it — tap Save to confirm.';
          });
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
      localeId: 'en_US',
      listenOptions: stt.SpeechListenOptions(partialResults: true),
    );
  }

  /// Stage 1: parse the transcript and show a review card before persisting.
  void _reviewBeforeSave() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _statusMessage = 'Type or dictate a symptom note first.');
      return;
    }
    final parsed = AppServices.symptomParserService.parse(
      transcript: text,
      loggedAt: DateTime.now(),
    );
    setState(() {
      _pendingText = text;
      _pendingParseResult = parsed;
      _lastResult = null;
      _statusMessage = null;
    });
  }

  /// Stage 2: user confirmed — persist and clear review state.
  Future<void> _confirmSave() async {
    final text = _pendingText;
    if (text == null) return;

    setState(() {
      _saving = true;
      _statusMessage = null;
    });

    try {
      final result = await AppServices.symptomLoggingService.saveTranscript(
        transcript: text,
      );
      _refreshGuidance('voice_symptom_saved');
      final safetyFlags = result.parseResult.structuredSymptom.safetyFlags;
      setState(() {
        _pendingParseResult = null;
        _pendingText = null;
        _lastResult = result;
        _statusMessage = result.parseResult.needsClarification
            ? result.parseResult.clarificationQuestion ??
                'Saved with uncertainty. Add more detail in your own words if needed.'
            : safetyFlags.contains('urgent_review')
                ? 'Saved locally. Because this note mentioned higher-risk symptoms, contact urgent care or your GI team if you feel unsafe.'
                : safetyFlags.contains('bleeding_reported')
                    ? 'Saved locally. Because you mentioned bleeding, keep clinician follow-up in mind.'
                    : result.savedSymptom.extractionMethod ==
                            'gemma4_e2b_structured'
                        ? 'Gemma 4 extracted the note, saved it locally, and refreshed risk.'
                        : 'Saved locally with fallback parsing and refreshed risk.';
      });
    } catch (_) {
      setState(
        () => _statusMessage =
            "We couldn't save that symptom note. Please try again.",
      );
    } finally {
      setState(() => _saving = false);
    }
  }

  void _cancelReview() {
    setState(() {
      _pendingParseResult = null;
      _pendingText = null;
      _statusMessage = 'Cancelled — nothing was saved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final parsed = _lastResult?.parseResult.structuredSymptom;
    final needsClarification =
        _lastResult?.parseResult.needsClarification ?? false;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                children: [
                  Text('Voice Log', style: tt.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Tap the mic and describe symptoms in your own words, or type them below.',
                    style: tt.bodyMedium?.copyWith(color: cs.outline),
                  ),
                  const SizedBox(height: 28),

                  // ── Mic button ──────────────────────────────────────────
                  Center(
                    child: GestureDetector(
                      onTap: _saving ? null : _toggleListening,
                      child: AnimatedBuilder(
                        animation: _pulseCtrl,
                        builder: (_, child) => Transform.scale(
                          scale: _isListening
                              ? 1.0 + _pulseCtrl.value * 0.08
                              : 1.0,
                          child: child,
                        ),
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isListening
                                ? Colors.red.shade400
                                : cs.primaryContainer,
                            boxShadow: [
                              BoxShadow(
                                color: _isListening
                                    ? Colors.red.withValues(alpha: 0.35)
                                    : cs.primary.withValues(alpha: 0.15),
                                blurRadius: _isListening ? 20 : 10,
                                spreadRadius: _isListening ? 4 : 2,
                              ),
                            ],
                          ),
                          child: Icon(
                            _isListening
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                            size: 44,
                            color: _isListening
                                ? Colors.white
                                : cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      _isListening
                          ? 'Listening… tap to stop'
                          : _speechAvailable
                              ? 'Tap mic to speak'
                              : 'Type below',
                      style: tt.bodySmall?.copyWith(
                        color: _isListening ? Colors.red.shade400 : cs.outline,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'Speak naturally. Examples: "cramping after dinner, around 5 out of 10" or "loose stools this morning for about 20 minutes."',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Text field ──────────────────────────────────────────
                  TextField(
                    controller: _controller,
                    minLines: 3,
                    maxLines: 6,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Symptom note',
                      hintText:
                          'e.g. Had some cramping after lunch, maybe a 4 out of 10',
                      alignLabelWithHint: true,
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () => setState(() {
                                _controller.clear();
                                _statusMessage = null;
                                _lastResult = null;
                              }),
                            )
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),

                  // ── Review-before-save button ────────────────────────────
                  if (_pendingParseResult == null)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: (_saving || _isListening)
                            ? null
                            : _reviewBeforeSave,
                        icon: const Icon(Icons.preview_rounded, size: 18),
                        label: const Text('Review before saving'),
                      ),
                    ),

                  // ── Review card ──────────────────────────────────────────
                  if (_pendingParseResult != null) ...[
                    const SizedBox(height: 12),
                    _ReviewCard(
                      pendingText: _pendingText!,
                      parsed: _pendingParseResult!,
                      saving: _saving,
                      onConfirm: _confirmSave,
                      onCancel: _cancelReview,
                    ),
                  ],

                  if (needsClarification) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: cs.secondaryContainer.withValues(alpha: 0.3),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          'Add any missing detail in your own words, then save again. Severity and symptom type help the score update more reliably.',
                          style: tt.bodySmall,
                        ),
                      ),
                    ),
                  ],

                  // ── Status message ──────────────────────────────────────
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(
                          alpha: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_statusMessage!, style: tt.bodySmall),
                    ),
                  ],

                  // ── Parsed preview ──────────────────────────────────────
                  if (parsed != null) ...[
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Parsed symptom',
                                    style: tt.titleSmall,
                                  ),
                                ),
                                ModelUseBadge(
                                  usedModelOutput: _lastResult!
                                          .savedSymptom.extractionMethod ==
                                      'gemma4_e2b_structured',
                                ),
                              ],
                            ),
                            const Divider(height: 20),
                            _DetailRow('Summary', parsed.userFacingDescription),
                            _DetailRow('Type', parsed.symptomType),
                            _DetailRow(
                              'Severity',
                              parsed.severity1To10 != null
                                  ? '${parsed.severity1To10}/10'
                                  : 'not specified',
                            ),
                            _DetailRow(
                              'Duration',
                              parsed.durationMinutes != null
                                  ? '${parsed.durationMinutes} min'
                                  : 'not specified',
                            ),
                            _DetailRow(
                              'Meal',
                              parsed.mealRelation?.replaceAll('_', ' ') ??
                                  'not specified',
                            ),
                            _DetailRow(
                              'Confidence',
                              '${(parsed.extractionConfidence * 100).round()}%',
                            ),
                            _DetailRow(
                              'Extraction',
                              _lastResult!.savedSymptom.extractionMethod
                                  .replaceAll('_', ' '),
                            ),
                            if (parsed.uncertaintyNotes.isNotEmpty)
                              _DetailRow(
                                'Uncertainty',
                                parsed.uncertaintyNotes.join('; '),
                              ),
                            if (parsed.safetyFlags.isNotEmpty)
                              _DetailRow(
                                'Safety',
                                parsed.safetyFlags
                                    .map(_prettySafetyFlag)
                                    .join(', '),
                              ),
                            if (_lastResult!.savedIntakeEvents.isNotEmpty)
                              _DetailRow(
                                'Context',
                                _lastResult!.savedIntakeEvents
                                    .map(
                                      (item) =>
                                          item.eventType.replaceAll('_', ' '),
                                    )
                                    .join(', '),
                              ),
                            if (_lastResult!.gemmaTaskRunId != null)
                              _DetailRow(
                                'Task',
                                'Gemma run ${_lastResult!.gemmaTaskRunId}',
                              ),
                            if (_lastResult?.updatedRiskScore != null) ...[
                              const Divider(height: 20),
                              Row(
                                children: [
                                  Icon(
                                    Icons.trending_up_rounded,
                                    size: 18,
                                    color: AppTheme.riskColor(
                                      _lastResult!.updatedRiskScore!.riskBand,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Risk after save: ${_lastResult!.updatedRiskScore!.riskScore.round()}/100 ${_lastResult!.updatedRiskScore!.riskBand}',
                                    style: tt.bodyMedium,
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                  Text(
                    'Symptom notes are stored locally. This is not a diagnosis.',
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.outline),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          // Keyboard spacer — content floats above keyboard without hiding nav bar
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            height: MediaQuery.of(context).viewInsets.bottom,
          ),
        ],
      ),
    );
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Symptom save already succeeded; guidance can retry on resume.
    }
  }
}

/// Compact pre-save review card — shown after parsing, before persisting.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.pendingText,
    required this.parsed,
    required this.saving,
    required this.onConfirm,
    required this.onCancel,
  });

  final String pendingText;
  final SymptomParseResult parsed;
  final bool saving;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final sym = parsed.structuredSymptom;
    return Card(
      color: cs.secondaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.preview_rounded, size: 18),
                const SizedBox(width: 8),
                Text('Review before saving', style: tt.titleSmall),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '"$pendingText"',
              style: tt.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: cs.outline,
              ),
            ),
            const Divider(height: 18),
            _DetailRow('Symptom', sym.userFacingDescription),
            _DetailRow('Type', sym.symptomType.replaceAll('_', ' ')),
            if (sym.severity1To10 != null)
              _DetailRow('Severity', '${sym.severity1To10}/10'),
            if (parsed.needsClarification)
              _DetailRow(
                'Note',
                parsed.clarificationQuestion ??
                    'Uncertainty detected — description may be incomplete.',
              ),
            if (sym.safetyFlags.isNotEmpty)
              _DetailRow(
                'Safety',
                sym.safetyFlags.map(_prettySafetyFlag).join(', '),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving ? null : onCancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: saving ? null : onConfirm,
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Confirm save'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Type "cancel" or tap Cancel to discard.',
              style: tt.bodySmall?.copyWith(color: cs.outline),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _prettySafetyFlag(String flag) {
  return switch (flag) {
    'urgent_review' => 'urgent review',
    'bleeding_reported' => 'bleeding mentioned',
    'severe_symptom' => 'high severity',
    _ => flag.replaceAll('_', ' '),
  };
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
