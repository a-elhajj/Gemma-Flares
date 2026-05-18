import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/lab_logging_service.dart';
import '../../core/services/dashboard_snapshot_service.dart';
import 'chat_controller.dart';
import 'chat_widgets.dart';
import '../health_records/lab_report_import_screen.dart';
import '../voice/voice_log_screen.dart';

class EmbeddedTodayChat extends StatefulWidget {
  const EmbeddedTodayChat({
    super.key,
    required this.snapshot,
    this.controller,
    this.queuedPrompt,
    this.queuedPromptToken = 0,
    this.onExpand,
    this.onOpenSymptoms,
  });

  final DashboardSnapshot? snapshot;
  final ChatController? controller;
  final String? queuedPrompt;
  final int queuedPromptToken;
  final VoidCallback? onExpand;
  final VoidCallback? onOpenSymptoms;

  @override
  State<EmbeddedTodayChat> createState() => _EmbeddedTodayChatState();
}

class _EmbeddedTodayChatState extends State<EmbeddedTodayChat> {
  late final ChatController _controller;
  late final bool _ownsController;
  final _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? ChatController();
    _ownsController = widget.controller == null;
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize(restoreHistory: !_controller.restored));
  }

  @override
  void didUpdateWidget(covariant EmbeddedTodayChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.queuedPromptToken != oldWidget.queuedPromptToken &&
        (widget.queuedPrompt?.trim().isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _send(widget.queuedPrompt!);
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _send(String prompt) async {
    _textController.clear();
    await _controller.send(prompt);
  }

  Future<void> _copy(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copied.')));
  }

  Future<void> _openLabReportImport() async {
    final saved = await Navigator.of(context).push<LabLoggingResult?>(
      MaterialPageRoute<LabLoggingResult?>(
        fullscreenDialog: true,
        builder: (_) => const LabReportImportScreen(),
      ),
    );
    if (saved != null) {
      await _controller.handleLabImportSaved(saved);
    }
  }

  void _editPending(ChatMessage message) {
    final source = _controller.editPendingAction(message);
    if (source == null) return;
    _textController.text = source;
    _textController.selection = TextSelection.collapsed(offset: source.length);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 18,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ask Gemma Flares',
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: widget.onExpand,
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  label: const Text('Expand'),
                ),
              ],
            ),
          ),
          if (_controller.messages.isEmpty)
            _SeedMessage(snapshot: widget.snapshot),
          ChatThreadView(
            messages: _controller.messages,
            busy: _controller.busy,
            compact: true,
            onCopy: _copy,
            onAskAgain: (message) => _send(message.text),
            onConfirmPending: _controller.confirmPendingAction,
            onEditPending: _editPending,
            onCancelPending: _controller.cancelPendingAction,
            onOpenSymptoms: widget.onOpenSymptoms,
          ),
          _QuickPromptRow(onPrompt: _send),
          ChatComposer(
            controller: _textController,
            busy: _controller.busy,
            modelReady: _controller.modelReady,
            compact: true,
            onSend: _send,
            onAttachLabReport: _openLabReportImport,
            onMic: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => const VoiceLogScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeedMessage extends StatelessWidget {
  const _SeedMessage({required this.snapshot});

  final DashboardSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasScore = snapshot?.latestScore != null;
    final stale = snapshot?.isSyncStale == true;
    final text = stale
        ? 'Your data looks stale, so I’ll label anything uncertain. Ask me what is still useful today.'
        : hasScore
            ? 'I can explain today’s score, compare it to your baseline, or help you decide what to watch next.'
            : 'I need Health data and a baseline before I can explain a score. You can still ask about setup or log symptoms.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.health_and_safety_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickPromptRow extends StatelessWidget {
  const _QuickPromptRow({required this.onPrompt});

  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    final prompts = kChatStarterPrompts;
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        itemCount: prompts.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final prompt = prompts[index];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            label: Text(prompt.label, style: const TextStyle(fontSize: 12)),
            onPressed: () => onPrompt(prompt.prompt),
          );
        },
      ),
    );
  }
}
