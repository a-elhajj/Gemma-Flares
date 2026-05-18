import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/services/prompt_templates.dart' as prompts;

@visibleForTesting
String normalizeAssistantMarkdownForDisplay(String rawText) {
  if (rawText.trim().isEmpty) return rawText.trim();

  final headingPattern = RegExp(r'^\s*#{1,3}\s+');
  final bulletPattern = RegExp(r'^\s*[-*]\s+');
  final unicodeBulletPattern = RegExp(r'^\s*[•●◦▪‣·]\s+');
  final numberedBulletPattern = RegExp(r'^\s*(\d+)\)\s+');

  var canonical = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (!canonical.contains('\n') && canonical.contains(r'\n')) {
    canonical = canonical.replaceAll(r'\n', '\n');
  }

  final normalizedLines = <String>[];
  var inCodeFence = false;
  for (final rawLine in canonical.split('\n')) {
    var line = rawLine.replaceAll(RegExp(r'[ \t]+$'), '');
    final trimmedLeft = line.trimLeft();
    if (trimmedLeft.startsWith('```')) {
      inCodeFence = !inCodeFence;
      normalizedLines.add(trimmedLeft);
      continue;
    }
    if (!inCodeFence) {
      if (headingPattern.hasMatch(line)) {
        line = line.trimLeft();
      } else if (bulletPattern.hasMatch(line)) {
        line = '- ${line.trimLeft().replaceFirst(RegExp(r'^[-*]\s+'), '')}';
      } else if (unicodeBulletPattern.hasMatch(line)) {
        line = '- ${line.trimLeft().replaceFirst(unicodeBulletPattern, '')}';
      } else if (numberedBulletPattern.hasMatch(line)) {
        line = line.trimLeft().replaceFirstMapped(
              numberedBulletPattern,
              (m) => '${m[1]}. ',
            );
      }
    }
    normalizedLines.add(line);
  }

  final structured = <String>[];
  var inCodeBlock = false;
  for (var i = 0; i < normalizedLines.length; i++) {
    final line = normalizedLines[i];
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      structured.add(trimmed);
      continue;
    }

    if (inCodeBlock) {
      structured.add(line);
      continue;
    }

    final isHeading = headingPattern.hasMatch(line);
    final isBullet = RegExp(r'^\s*(?:[-*]|\d+\.)\s+').hasMatch(line);

    String? previousNonEmpty;
    for (var p = structured.length - 1; p >= 0; p--) {
      final candidate = structured[p].trim();
      if (candidate.isNotEmpty) {
        previousNonEmpty = candidate;
        break;
      }
    }

    if (isBullet &&
        previousNonEmpty != null &&
        !RegExp(r'^\s*(?:[-*]|\d+\.)\s+').hasMatch(previousNonEmpty) &&
        !headingPattern.hasMatch(previousNonEmpty) &&
        !previousNonEmpty.endsWith(':') &&
        structured.isNotEmpty &&
        structured.last.trim().isNotEmpty) {
      structured.add('');
    }

    if (!isBullet &&
        previousNonEmpty != null &&
        RegExp(r'^\s*(?:[-*]|\d+\.)\s+').hasMatch(previousNonEmpty) &&
        trimmed.isNotEmpty &&
        structured.isNotEmpty &&
        structured.last.trim().isNotEmpty) {
      structured.add('');
    }

    if (isHeading &&
        structured.isNotEmpty &&
        structured.last.trim().isNotEmpty) {
      structured.add('');
    }

    structured.add(line);

    final next = i + 1 < normalizedLines.length ? normalizedLines[i + 1] : '';
    if (isHeading && next.trim().isNotEmpty) {
      structured.add('');
    }
  }

  var text = structured.join('\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  text = text.replaceAll(RegExp(r':\s*-\s+'), ':\n- ');
  text = text.replaceAllMapped(RegExp(r':\s*(\d+\.)\s+'), (m) => ':\n${m[1]} ');

  if (!text.contains('\n') && text.length > 280) {
    final sentences = text
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (sentences.length >= 3) {
      final rebuilt = <String>[];
      for (var i = 0; i < sentences.length; i++) {
        rebuilt.add(sentences[i].trim());
        if (i < sentences.length - 1) {
          rebuilt.add((i % 2 == 1) ? '\n\n' : ' ');
        }
      }
      text = rebuilt.join().trim();
    }
  }

  if (!text.contains('\n') && text.length > 140 && text.contains(';')) {
    final semicolonClauses = text
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (semicolonClauses.length >= 2) {
      text = semicolonClauses.join(';\n\n');
    }
  }

  // Last-resort fallback: if a very long answer is still a single run-on
  // sentence, split by clauses for mobile readability.
  if (!text.contains('\n') && text.length > 240) {
    final clauses = text
        .split(
          RegExp(
            r'(?<=[;:])\s+|,\s+(?=(and|but|while|when|if)\b)',
            caseSensitive: false,
          ),
        )
        .where((part) => part.trim().isNotEmpty)
        .map((part) => part.trim())
        .toList(growable: false);
    if (clauses.length >= 3) {
      text = clauses.join('\n\n');
    }
  }

  // Heuristic rescue for dense section-style outputs that arrive as one run-on
  // block without markdown breaks.
  if (!text.contains('\n') && text.length > 180) {
    const sectionHeads = [
      'Overview',
      'GI Activity & Symptoms',
      'Pattern overview',
      'Recent logged symptoms',
      'Lab Results',
      'Check-in Summary',
      'Medication and Supplement Log',
      'Bowel Pattern Baseline',
      'Condensed Diet and Trigger Log',
      'Questions for Your GI Doctor',
      'Triage and Red Flags',
    ];
    for (final head in sectionHeads) {
      final first = text.indexOf(head);
      if (first <= 0) continue;
      text =
          '${text.substring(0, first).trimRight()}\n\n${text.substring(first)}';
    }
    for (final head in sectionHeads) {
      if (text.startsWith('$head ')) {
        text = text.replaceFirst('$head ', '$head\n\n');
      }
    }
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  // Single long bullet often renders awkwardly in chat; unwrap it to prose.
  final lines = text.split('\n');
  final bulletIndexes = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^\s*-\s+').hasMatch(lines[i])) {
      bulletIndexes.add(i);
    }
  }
  if (bulletIndexes.length == 1) {
    final index = bulletIndexes.single;
    if (lines[index].trim().length > 100) {
      lines[index] = lines[index].replaceFirst(RegExp(r'^\s*-\s+'), '');
      text = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    }
  }

  return text;
}

/// Chat message surface. Shows conversation history, a streaming token
/// animation while the model is generating, and an empty-state with starter
/// chips when there are no messages in the current session.
class ChatSurfaceWidget extends StatelessWidget {
  const ChatSurfaceWidget({
    super.key,
    required this.isGenerating,
    required this.streamingText,
    required this.scrollController,
    this.onStarterPrompt,
    this.onShareMessage,
    this.messages = const [],
  });

  final bool isGenerating;
  final String streamingText;
  final ScrollController scrollController;
  final List<ChatMessage> messages;
  final ValueChanged<String>? onStarterPrompt;
  final Future<void> Function(ChatMessage message)? onShareMessage;

  @override
  Widget build(BuildContext context) {
    final hasContent =
        messages.isNotEmpty || isGenerating || streamingText.isNotEmpty;

    if (!hasContent) {
      return _EmptyState(onStarterPrompt: onStarterPrompt);
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount:
          messages.length + (isGenerating || streamingText.isNotEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          return _MessageBubble(
            message: messages[index],
            onShareMessage: onShareMessage,
          );
        }
        // Streaming bubble
        return _StreamingBubble(text: streamingText);
      },
    );
  }
}

/// Immutable record of a single chat message.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    required this.timestamp,
    this.interrupted = false,
    this.isGiSummary = false,
  });

  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime timestamp;
  final bool interrupted;

  /// True when this message is a full GI doctor-summary — shows export buttons.
  final bool isGiSummary;
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onStarterPrompt});

  final ValueChanged<String>? onStarterPrompt;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How\'s your gut today?',
              style: textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _StarterChip(
                  label: prompts.kPromptPresetDefinitions[0].label,
                  onPressed: onStarterPrompt,
                ),
                _StarterChip(
                  label: prompts.kPromptPresetDefinitions[1].label,
                  onPressed: onStarterPrompt,
                ),
                _StarterChip(
                  label: prompts.kPromptPresetDefinitions[2].label,
                  onPressed: onStarterPrompt,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StarterChip extends StatelessWidget {
  const _StarterChip({required this.label, this.onPressed});

  final String label;
  final ValueChanged<String>? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ActionChip(
        label: Text(label),
        onPressed: onPressed == null ? null : () => onPressed!(label),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message bubbles
// ---------------------------------------------------------------------------

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onShareMessage});

  final ChatMessage message;
  final Future<void> Function(ChatMessage message)? onShareMessage;

  Future<void> _copyMessage(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareMessage(BuildContext context) async {
    try {
      final handler = onShareMessage;
      if (handler != null) {
        // Handler owns its own feedback (PDF loading indicator + share sheet).
        await handler(message);
      } else {
        final object = context.findRenderObject();
        final origin = object is RenderBox && object.hasSize
            ? object.localToGlobal(Offset.zero) & object.size
            : null;
        await Share.share(
          message.text,
          subject: 'Gemma Flares GI Summary',
          sharePositionOrigin: origin,
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Share sheet opened.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open share sheet. Try copying instead.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final colorScheme = Theme.of(context).colorScheme;
    final bubbleColor =
        isUser ? colorScheme.primaryContainer : colorScheme.surfaceContainerLow;
    final textColor =
        isUser ? colorScheme.onPrimaryContainer : colorScheme.onSurface;

    // GI summaries fill full width; assistant messages use 92% for readability;
    // user messages stay at 78% for natural chat alignment.
    final maxFraction = message.isGiSummary
        ? 1.0
        : isUser
            ? 0.78
            : 0.92;
    final bubbleConstraints = BoxConstraints(
      maxWidth: MediaQuery.of(context).size.width * maxFraction -
          (message.isGiSummary ? 32 : 0),
    );

    // Shared M3-aligned markdown stylesheet for all assistant bubbles.
    // Keeps chat conversational: no heavy headers, compact bullets, warm tone.
    MarkdownStyleSheet assistantStyle() {
      final tt = Theme.of(context).textTheme;
      return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: tt.bodyMedium?.copyWith(color: textColor, height: 1.45),
        // h1 is never expected in chat; treat as bold sentence
        h1: tt.bodyMedium?.copyWith(
          color: textColor,
          fontWeight: FontWeight.bold,
        ),
        h2: tt.titleSmall?.copyWith(
          color: textColor,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h3: tt.bodyMedium?.copyWith(
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
        listBullet: tt.bodyMedium?.copyWith(color: textColor),
        strong: tt.bodyMedium?.copyWith(
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
        em: tt.bodyMedium?.copyWith(
          color: textColor,
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(color: colorScheme.primary, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        listIndent: 16,
        blockSpacing: 6,
      );
    }

    final bubble = GestureDetector(
      onLongPress: () => _copyMessage(context),
      child: Container(
        constraints: bubbleConstraints,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
        ),
        child: isUser
            ? Text(
                message.text,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: textColor),
              )
            : MarkdownBody(
                data: normalizeAssistantMarkdownForDisplay(message.text),
                selectable: true,
                softLineBreak: true,
                styleSheet: assistantStyle(),
              ),
      ),
    );

    // Action row shown below assistant bubbles — always shows Copy;
    // GI summaries also get Share.
    Widget? actionRow;
    if (!isUser) {
      actionRow = Padding(
        padding: const EdgeInsets.only(left: 4, top: 0, bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: () => _copyMessage(context),
              icon: const Icon(Icons.copy, size: 15),
              label: const Text('Copy'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
            if (message.isGiSummary) ...[
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => _shareMessage(context),
                icon: const Icon(Icons.share, size: 15),
                label: const Text('Share'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Semantics(
      label: '${isUser ? 'You' : 'Gemma Flares'}: ${message.text}',
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: actionRow != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [bubble, actionRow],
              )
            : bubble,
      ),
    );
  }
}

class _StreamingBubble extends StatefulWidget {
  const _StreamingBubble({required this.text});

  final String text;

  @override
  State<_StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<_StreamingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _caretController;

  @override
  void initState() {
    super.initState();
    _caretController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 530),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _caretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                widget.text.isEmpty ? ' ' : widget.text,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            AnimatedBuilder(
              animation: _caretController,
              builder: (_, __) => Opacity(
                opacity: _caretController.value > 0.5 ? 1.0 : 0.0,
                child: Container(
                  width: 2,
                  height: 14,
                  margin: const EdgeInsets.only(left: 2, bottom: 1),
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
