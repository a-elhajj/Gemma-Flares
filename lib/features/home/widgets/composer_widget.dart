import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Pinned composer bar at the bottom of HomeScreen.
/// Contains: camera button · microphone button · text field · settings button.
/// The settings icon opens the SettingsModal (not a tab).
class ComposerWidget extends StatefulWidget {
  const ComposerWidget({
    super.key,
    required this.controller,
    required this.isGenerating,
    required this.onSend,
    required this.onOpenSettings,
    this.onVoicePressed,
    this.onCameraPressed,
    this.onStopGeneration,
  });

  final TextEditingController controller;
  final bool isGenerating;
  final ValueChanged<String> onSend;
  final VoidCallback onOpenSettings;
  final VoidCallback? onVoicePressed;
  final VoidCallback? onCameraPressed;
  final VoidCallback? onStopGeneration;

  @override
  State<ComposerWidget> createState() => _ComposerWidgetState();
}

class _ComposerWidgetState extends State<ComposerWidget> {
  bool _hasText = false;
  final _speech = stt.SpeechToText();
  final _focusNode = FocusNode(debugLabel: 'Gemma Flares message composer');
  bool _speechAvailable = false;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _isListening = false);
      },
    );
    if (mounted) setState(() => _speechAvailable = available);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _speech.stop();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _submit() {
    final text = widget.controller.text;
    if (text.trim().isEmpty) return;
    if (_isListening) {
      _speech.stop();
      setState(() => _isListening = false);
    }
    widget.onSend(text);
    widget.controller.clear();
  }

  Future<void> _toggleVoice() async {
    if (widget.onVoicePressed != null) {
      widget.onVoicePressed!();
      return;
    }
    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone permission is required. Enable it in Settings → Gemma Flares.',
          ),
        ),
      );
      return;
    }
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      final baseText = widget.controller.text;
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          final words = result.recognizedWords;
          if (words.isEmpty) return;
          final prefix = baseText.isNotEmpty && !baseText.endsWith(' ')
              ? '$baseText '
              : baseText;
          widget.controller.value = TextEditingValue(
            text: '$prefix$words',
            selection: TextSelection.collapsed(
              offset: prefix.length + words.length,
            ),
          );
        },
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 4),
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant.withAlpha(100)),
        ),
      ),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 8 : 12,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Camera
            Semantics(
              label: 'Attach photo',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.camera_alt_outlined),
                onPressed: widget.onCameraPressed ?? _showCameraOptions,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                tooltip: 'Attach photo',
              ),
            ),
            // Voice / Stop
            Semantics(
              label: widget.isGenerating
                  ? 'Stop generation'
                  : _isListening
                      ? 'Stop listening'
                      : 'Voice input',
              button: true,
              child: IconButton(
                icon: Icon(
                  widget.isGenerating
                      ? Icons.stop_circle_outlined
                      : _isListening
                          ? Icons.mic
                          : Icons.mic_outlined,
                  color:
                      _isListening ? Theme.of(context).colorScheme.error : null,
                ),
                onPressed: widget.isGenerating
                    ? (widget.onStopGeneration ?? () {})
                    : _toggleVoice,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                tooltip: widget.isGenerating
                    ? 'Stop'
                    : _isListening
                        ? 'Stop listening'
                        : 'Voice input',
              ),
            ),
            const SizedBox(width: 4),
            // Text field
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                enabled: !widget.isGenerating,
                autocorrect: true,
                enableSuggestions: true,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                spellCheckConfiguration: SpellCheckConfiguration.disabled(),
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: widget.isGenerating ? null : (_) => _submit(),
                onTapOutside: (_) => _focusNode.unfocus(),
                decoration: InputDecoration(
                  hintText: 'Message Gemma Flares…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(
                      color: colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                  filled: true,
                  suffixIcon: _hasText && !widget.isGenerating
                      ? Semantics(
                          label: 'Send message',
                          button: true,
                          child: IconButton(
                            icon: const Icon(Icons.arrow_upward_rounded),
                            onPressed: _submit,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            tooltip: 'Send',
                          ),
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Settings
            Semantics(
              label: 'Open settings',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: widget.onOpenSettings,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                tooltip: 'Settings',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCameraOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.biotech_outlined),
              title: const Text('Lab result'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.restaurant_outlined),
              title: const Text('Food'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.water_drop_outlined),
              title: const Text('Other photo'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}
