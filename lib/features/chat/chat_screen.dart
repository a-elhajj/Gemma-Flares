import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/lab_logging_service.dart';
import 'chat_controller.dart';
import 'chat_widgets.dart';
import '../health_records/lab_report_import_screen.dart';
import '../voice/voice_log_screen.dart';

enum _ChatMenuAction { copyLastAnswer, clearChat }

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.controller,
    this.queuedPrompt,
    this.queuedPromptToken = 0,
    this.onOpenSymptomsRequested,
  });

  final ChatController? controller;
  final String? queuedPrompt;
  final int queuedPromptToken;
  final VoidCallback? onOpenSymptomsRequested;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller;
  late final bool _ownsController;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? ChatController();
    _ownsController = widget.controller == null;
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize(restoreHistory: !_controller.restored));
    _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      if (_controller.modelReady) {
        _statusPollTimer?.cancel();
        return;
      }
      unawaited(_controller.refreshRuntime());
    });
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
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
    _statusPollTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _send(String prompt) async {
    _textController.clear();
    await _controller.send(prompt);
  }

  Future<void> _sendPreset(String label, String prompt) async {
    _textController.clear();
    await _controller.send(prompt);
  }

  Future<void> _copyText(String text, {String label = 'Message'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied.')));
  }

  Future<void> _copyLastAssistant() async {
    final assistantMessages = _controller.messages
        .where((message) => message.role == 'assistant')
        .toList();
    if (assistantMessages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No assistant answer to copy yet.')),
      );
      return;
    }
    await _copyText(assistantMessages.last.text, label: 'Latest answer');
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

  Future<void> _clearChat() async {
    if (_controller.messages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Chat is already empty.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'This removes saved chat messages from this phone. Health records, symptoms, labs, and scores stay untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear chat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.clearChat();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chat cleared from this phone.')),
    );
  }

  void _editPendingAction(ChatMessage message) {
    final source = _controller.editPendingAction(message);
    if (source == null) return;
    _textController.text = source;
    _textController.selection = TextSelection.collapsed(offset: source.length);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(cs),
            const SizedBox(height: 4),
            Expanded(
              child: ChatThreadView(
                messages: _controller.messages,
                busy: _controller.busy,
                scrollController: _scrollController,
                onCopy: (message) => _copyText(message.text),
                onAskAgain: (message) => _send(message.text),
                onConfirmPending: _controller.confirmPendingAction,
                onEditPending: _editPendingAction,
                onCancelPending: _controller.cancelPendingAction,
                onOpenSymptoms: widget.onOpenSymptomsRequested,
                emptyBuilder: _emptyState,
              ),
            ),
            _buildFollowUpChips(),
            ChatComposer(
              controller: _textController,
              busy: _controller.busy,
              modelReady: _controller.modelReady,
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
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    final status = _controller.runtimeStatus;
    final statusText = status == null
        ? 'Initialising…'
        : _controller.modelReady
            ? 'Gemma 4 · on-device'
            : status.status == 'model_missing'
                ? 'Model file missing'
                : 'Waiting for Gemma 4…';
    final statusColor = _controller.modelReady
        ? Colors.teal.shade600
        : status?.status == 'model_missing'
            ? cs.error
            : cs.outline;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Chat', style: tt.headlineMedium),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (!_controller.modelReady &&
                        status?.status != 'model_missing' &&
                        status != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: cs.outline,
                          ),
                        ),
                      ),
                    Text(
                      statusText,
                      style: tt.bodySmall?.copyWith(color: statusColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _controller.busy
                ? null
                : () {
                    unawaited(_controller.refreshRuntime());
                    unawaited(_controller.restoreHistoryFromStore());
                  },
            icon: const Icon(Icons.refresh_rounded, size: 20),
            color: cs.outline,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<_ChatMenuAction>(
            enabled: !_controller.busy,
            tooltip: 'Chat options',
            onSelected: (action) {
              switch (action) {
                case _ChatMenuAction.copyLastAnswer:
                  _copyLastAssistant();
                  break;
                case _ChatMenuAction.clearChat:
                  _clearChat();
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ChatMenuAction.copyLastAnswer,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.copy_outlined),
                  title: Text('Copy latest answer'),
                ),
              ),
              PopupMenuItem(
                value: _ChatMenuAction.clearChat,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_outline),
                  title: Text('Clear chat'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFollowUpChips() {
    if (_controller.busy) {
      return const SizedBox.shrink();
    }
    final suggestions = _controller.messages.isEmpty
        ? kChatStarterPrompts
        : _suggestedFollowUps();
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        itemCount: suggestions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) => ActionChip(
          label: Text(
            suggestions[index].label,
            style: const TextStyle(fontSize: 13),
          ),
          visualDensity: VisualDensity.compact,
          onPressed: () => _sendPreset(
            suggestions[index].label,
            suggestions[index].prompt,
          ),
        ),
      ),
    );
  }

  List<({String label, String prompt})> _suggestedFollowUps() {
    ChatMessage? latestAssistant;
    for (final message in _controller.messages.reversed) {
      if (message.role == 'assistant') {
        latestAssistant = message;
        break;
      }
    }
    final intent = latestAssistant?.evidence?['agent_intent'] as String?;
    switch (intent) {
      case 'risk_question':
        return const [
          (
            label: 'What changed?',
            prompt: 'What changed most compared with my recent baseline?',
          ),
          (
            label: 'Lab context',
            prompt: 'Do my recent labs add context to this risk score?',
          ),
          (
            label: 'GI summary',
            prompt: 'Prepare a doctor-ready GI visit summary.',
          ),
        ];
      case 'confidence_question':
        return const [
          (
            label: 'Improve it',
            prompt: 'What can I do to improve my confidence score?',
          ),
          (
            label: 'Risk score',
            prompt: 'What does my current risk score mean?',
          ),
          (
            label: 'Sync data',
            prompt: 'Is my Apple Watch data syncing properly?',
          ),
        ];
      default:
        return const [
          (label: 'Why higher?', prompt: 'Why is my flare risk higher today?'),
          (
            label: 'Summarize week',
            prompt: 'Summarize my health patterns from the past week.',
          ),
          (
            label: 'GI summary',
            prompt: 'Prepare a doctor-ready GI visit summary.',
          ),
          (
            label: 'Confidence',
            prompt: 'How is my confidence score calculated?',
          ),
        ];
    }
  }

  Widget _emptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.health_and_safety_rounded,
                size: 36,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Your health companion',
              style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              'Ask about your recent patterns, score changes, symptoms, or what to watch next. Everything stays on this phone.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Try asking:',
              style: tt.labelMedium?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: kChatStarterPrompts
                  .take(4)
                  .map((c) => ActionChip(
                        label:
                            Text(c.label, style: const TextStyle(fontSize: 13)),
                        onPressed: () => _sendPreset(c.label, c.prompt),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
