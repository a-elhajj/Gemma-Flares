import 'package:flutter/material.dart';

import '../../core/services/prompt_templates.dart' as prompts;
import '../../core/widgets/model_use_badge.dart';
import 'chat_controller.dart';

final kChatStarterPrompts = prompts.kChatStarterPromptDefinitions
    .map((item) => (label: item.label, prompt: item.prompt))
    .toList(growable: false);

class ChatThreadView extends StatelessWidget {
  const ChatThreadView({
    super.key,
    required this.messages,
    required this.busy,
    required this.onCopy,
    this.onAskAgain,
    this.onConfirmPending,
    this.onEditPending,
    this.onCancelPending,
    this.onOpenSymptoms,
    this.scrollController,
    this.compact = false,
    this.emptyBuilder,
  });

  final List<ChatMessage> messages;
  final bool busy;
  final ValueChanged<ChatMessage> onCopy;
  final ValueChanged<ChatMessage>? onAskAgain;
  final ValueChanged<ChatMessage>? onConfirmPending;
  final ValueChanged<ChatMessage>? onEditPending;
  final ValueChanged<ChatMessage>? onCancelPending;
  final VoidCallback? onOpenSymptoms;
  final ScrollController? scrollController;
  final bool compact;
  final WidgetBuilder? emptyBuilder;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && !busy) {
      return emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }

    final visibleMessages = compact && messages.length > 3
        ? messages.sublist(messages.length - 3)
        : messages;
    return ListView.builder(
      controller: scrollController,
      shrinkWrap: compact,
      physics: compact
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, compact ? 4 : 8),
      itemCount: visibleMessages.length + (busy ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == visibleMessages.length) {
          return const ChatTypingIndicator();
        }
        final message = visibleMessages[i];
        return ChatBubble(
          message: message,
          compact: compact,
          onCopy: () => onCopy(message),
          onAskAgain: message.role == 'user' && onAskAgain != null
              ? () => onAskAgain!(message)
              : null,
          onConfirmPending:
              message.pendingAction == null || onConfirmPending == null
                  ? null
                  : () => onConfirmPending!(message),
          onEditPending: message.pendingAction == null || onEditPending == null
              ? null
              : () => onEditPending!(message),
          onCancelPending:
              message.pendingAction == null || onCancelPending == null
                  ? null
                  : () => onCancelPending!(message),
          onOpenSymptoms: onOpenSymptoms,
        );
      },
    );
  }
}

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.busy,
    required this.modelReady,
    required this.onSend,
    this.onAttachLabReport,
    this.onMic,
    this.compact = false,
  });

  final TextEditingController controller;
  final bool busy;
  final bool modelReady;
  final ValueChanged<String> onSend;
  final VoidCallback? onAttachLabReport;
  final VoidCallback? onMic;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(12, compact ? 6 : 8, 8, compact ? 8 : 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: busy ? null : onAttachLabReport,
            icon: const Icon(Icons.attach_file_rounded),
            tooltip: 'Scan lab report',
            visualDensity: compact ? VisualDensity.compact : null,
          ),
          IconButton(
            onPressed: busy ? null : onMic,
            icon: const Icon(Icons.mic_none_rounded),
            tooltip: 'Voice log',
            visualDensity: compact ? VisualDensity.compact : null,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              autocorrect: true,
              enableSuggestions: true,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              spellCheckConfiguration: SpellCheckConfiguration.disabled(),
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: compact ? 3 : 5,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: modelReady
                    ? 'Ask Gemma Flares anything…'
                    : 'Ask a question…',
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              onSubmitted: busy ? null : onSend,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: busy ? null : () => onSend(controller.text),
            icon: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward_rounded, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: busy ? null : cs.primary,
              foregroundColor: busy ? null : cs.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatTypingIndicator extends StatefulWidget {
  const ChatTypingIndicator({super.key});

  @override
  State<ChatTypingIndicator> createState() => _ChatTypingIndicatorState();
}

class _ChatTypingIndicatorState extends State<ChatTypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final phase = (_ctrl.value - i * 0.2).clamp(0.0, 1.0);
              final opacity =
                  (0.3 + 0.7 * (1.0 - (phase - 0.5).abs() * 2).clamp(0.0, 1.0));
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    required this.onCopy,
    this.onAskAgain,
    this.onConfirmPending,
    this.onEditPending,
    this.onCancelPending,
    this.onOpenSymptoms,
    this.compact = false,
  });

  final ChatMessage message;
  final VoidCallback onCopy;
  final VoidCallback? onAskAgain;
  final VoidCallback? onConfirmPending;
  final VoidCallback? onEditPending;
  final VoidCallback? onCancelPending;
  final VoidCallback? onOpenSymptoms;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // Long-press anywhere on the bubble copies the raw message text.
        onLongPress: onCopy,
        child: Tooltip(
          message: 'Long-press to copy',
          waitDuration: const Duration(seconds: 1),
          child: Container(
            constraints: BoxConstraints(
              maxWidth:
                  MediaQuery.of(context).size.width * (compact ? 0.88 : 0.82),
            ),
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: isUser ? cs.primary : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isUser ? 20 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 20),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 14 : 16,
                vertical: compact ? 10 : 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isUser) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.health_and_safety_rounded,
                          size: 13,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Gemma Flares',
                          style: tt.labelSmall?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        ModelUseBadge(
                          usedModelOutput: message.isModel == true,
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  _ExpandableText(
                    text: message.text,
                    style: tt.bodyMedium?.copyWith(
                      color: isUser ? cs.onPrimary : cs.onSurface,
                      height: 1.45,
                    ),
                    expandColor: isUser ? cs.onPrimary : cs.primary,
                    // User messages are always short; only truncate assistant.
                    collapsedMaxLines: isUser ? null : 8,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _BubbleAction(
                        icon: Icons.copy_outlined,
                        label: 'Copy',
                        foregroundColor: isUser ? cs.onPrimary : cs.outline,
                        onPressed: onCopy,
                      ),
                      if (onAskAgain != null) ...[
                        const SizedBox(width: 4),
                        _BubbleAction(
                          icon: Icons.replay_outlined,
                          label: 'Ask again',
                          foregroundColor: isUser ? cs.onPrimary : cs.outline,
                          onPressed: onAskAgain!,
                        ),
                      ],
                    ],
                  ),
                  if (!isUser && message.pendingAction != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        FilledButton(
                          onPressed: onConfirmPending,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Confirm'),
                        ),
                        OutlinedButton(
                          onPressed: onEditPending,
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Edit'),
                        ),
                        TextButton(
                          onPressed: onCancelPending,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                  if (!isUser &&
                      message.evidence?['open_symptoms_action'] == true &&
                      onOpenSymptoms != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: onOpenSymptoms,
                      icon: const Icon(Icons.list_alt_rounded, size: 18),
                      label: const Text('Open Symptoms'),
                    ),
                  ],
                  if (!isUser && message.evidence != null && !compact) ...[
                    Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          'Why this answer?',
                          style: tt.labelMedium?.copyWith(color: cs.outline),
                        ),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              evidenceLabel(message.evidence!),
                              style: tt.bodySmall?.copyWith(color: cs.outline),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ), // Container
        ), // Tooltip
      ), // GestureDetector
    );
  }

  static String evidenceLabel(Map<String, Object?> evidence) {
    final tools = evidence['tools_called'];
    final toolText = tools is List && tools.isNotEmpty
        ? tools.map((item) => item.toString()).join(', ')
        : 'local risk and health context';
    final taskRun = evidence['gemma_task_run_id'];
    final model = evidence['used_model_output'] == true
        ? 'Gemma 4 used local evidence'
        : 'Fallback answer; Gemma unavailable';
    final status = evidence['model_generation_status'];
    final fallbackReason = evidence['model_fallback_reason'];
    final outputQuality = evidence['output_quality_status'];
    final outputReason = evidence['output_quality_reason'];
    final nativeQuality = evidence['native_output_quality_status'];
    final nativeReason = evidence['native_output_quality_reason'];
    final profile = evidence['active_runtime_profile'];
    final promptTokens = evidence['estimated_prompt_tokens'];
    final promptBudget = evidence['prompt_budget'];
    final latency = evidence['generation_latency_ms'];
    final decodeRc = evidence['native_decode_rc'];
    final failureStage = evidence['failure_stage'];
    final template = evidence['prompt_template_version'];
    final sanitizer = evidence['sanitizer_version'];
    final stopReason = evidence['stop_reason'];
    final generatedTokens = evidence['generated_token_count'];
    final sampler = evidence['sampler_profile'];
    final pendingAction = evidence['pending_action_type'];
    final modelRole = evidence['model_role_used'];
    final modelId = evidence['model_id_used'];
    final engine = evidence['engine_used'];
    final contextPolicy = evidence['context_policy_used'];
    final evidenceHash = evidence['answer_evidence_hash'];
    final localOnly = evidence['local_only_verified'];
    return [
      'Tools: $toolText',
      model,
      if (engine != null) 'Engine: $engine',
      if (modelId != null) 'Model: $modelId',
      if (modelRole != null) 'Model role: $modelRole',
      if (contextPolicy != null) 'Context policy: $contextPolicy',
      if (localOnly != null) 'Local-only verified: $localOnly',
      if (evidenceHash != null) 'Evidence hash: $evidenceHash',
      if (status != null) 'Generation status: $status',
      if (fallbackReason != null) 'Fallback reason: $fallbackReason',
      if (outputQuality != null) 'Output quality: $outputQuality',
      if (outputReason != null) 'Quality reason: $outputReason',
      if (nativeQuality != null) 'Native quality: $nativeQuality',
      if (nativeReason != null) 'Native reason: $nativeReason',
      if (profile != null) 'Runtime profile: $profile',
      if (promptTokens != null && promptBudget != null)
        'Prompt: about $promptTokens tokens / budget $promptBudget',
      if (latency != null) 'Latency: ${latency}ms',
      if (generatedTokens != null) 'Generated tokens: $generatedTokens',
      if (stopReason != null) 'Stop reason: $stopReason',
      if (sampler != null) 'Sampler: $sampler',
      if (decodeRc != null) 'Native decode rc: $decodeRc',
      if (failureStage != null) 'Failure stage: $failureStage',
      if (template != null) 'Prompt template: $template',
      if (sanitizer != null) 'Sanitizer: $sanitizer',
      if (pendingAction != null) 'Pending action: $pendingAction',
      if (taskRun != null) 'Task run: $taskRun',
    ].join('\n');
  }
}

class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    required this.icon,
    required this.label,
    required this.foregroundColor,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color foregroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foregroundColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: foregroundColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ExpandableText — M3 chat bubble text with optional "Show more / less" toggle.
// FEA-021: prevents paragraph dumps from dominating the chat surface.
// ─────────────────────────────────────────────────────────────────────────────

class _ExpandableText extends StatefulWidget {
  const _ExpandableText({
    required this.text,
    this.style,
    this.expandColor,
    this.collapsedMaxLines,
  });

  final String text;
  final TextStyle? style;
  final Color? expandColor;
  // When null, no truncation is applied (used for user messages).
  final int? collapsedMaxLines;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    if (widget.collapsedMaxLines == null) {
      return Text(widget.text, style: widget.style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded ? null : widget.collapsedMaxLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.fade,
        ),
        // Only show toggle when text may exceed the limit.
        // LayoutBuilder alternative would be more precise, but adds complexity
        // with no measurable UX gain for the lines we expect here.
        if (!_expanded || widget.text.length > 300)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _expanded ? 'Show less' : 'Show more',
                style: tt.labelSmall?.copyWith(
                  color: widget.expandColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
