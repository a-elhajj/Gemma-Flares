import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/app_services.dart';
import '../../core/services/medication_logging_service.dart';

class AddMedicationLogScreen extends StatefulWidget {
  const AddMedicationLogScreen({super.key});

  @override
  State<AddMedicationLogScreen> createState() => _AddMedicationLogScreenState();
}

class _AddMedicationLogScreenState extends State<AddMedicationLogScreen> {
  final _rawController = TextEditingController();
  final _nameController = TextEditingController();
  final _doseController = TextEditingController();
  final _scheduleController = TextEditingController();
  final _notesController = TextEditingController();

  final stt.SpeechToText _speech = stt.SpeechToText();

  MedicationLoggingDraft? _draft;
  bool _building = false;
  bool _saving = false;
  bool _listening = false;
  String _eventType = 'medication_taken';
  DateTime _loggedAt = DateTime.now().toUtc();
  String? _status;

  @override
  void dispose() {
    _speech.stop();
    _rawController.dispose();
    _nameController.dispose();
    _doseController.dispose();
    _scheduleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) {
        setState(() {
          _listening = false;
          _status = 'Voice capture stopped.';
        });
      }
      return;
    }

    final available = await _speech.initialize();
    if (!available) {
      if (mounted) {
        setState(() {
          _status = 'Voice input is not available on this device right now.';
        });
      }
      return;
    }

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _rawController.text = result.recognizedWords.trim();
          _rawController.selection = TextSelection.fromPosition(
            TextPosition(offset: _rawController.text.length),
          );
        });
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
    );

    if (mounted) {
      setState(() {
        _listening = true;
        _status = 'Listening... describe what medication you took or skipped.';
      });
    }
  }

  Future<void> _buildDraft() async {
    setState(() {
      _building = true;
      _status = 'Building a review card from your note...';
    });

    try {
      final draft = await AppServices.medicationLoggingService
          .buildDraftFromText(transcript: _rawController.text);
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _eventType = draft.eventType;
        _loggedAt = draft.loggedAt;
        _nameController.text = draft.medicationName;
        _doseController.text = draft.dose ?? '';
        _scheduleController.text = draft.schedule ?? '';
        _notesController.text = draft.notes ?? '';
        _status = draft.requiresClarification
            ? (draft.clarificationPrompt ??
                'Please review details before saving.')
            : 'Review details, then confirm save.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status =
            'Could not parse that note. You can still fill fields manually.';
      });
    } finally {
      if (mounted) {
        setState(() => _building = false);
      }
    }
  }

  Future<void> _confirmSave() async {
    final currentDraft = _draft;
    if (currentDraft == null) {
      return;
    }

    final medicationName = _nameController.text.trim();
    if (medicationName.isEmpty) {
      setState(() {
        _status = 'Medication name is required before saving.';
      });
      return;
    }

    final confirmed = currentDraft.copyWith(
      eventType: _eventType,
      medicationName: medicationName,
      dose: _doseController.text.trim().isEmpty ? null : _doseController.text,
      schedule: _scheduleController.text.trim().isEmpty
          ? null
          : _scheduleController.text,
      notes:
          _notesController.text.trim().isEmpty ? null : _notesController.text,
      loggedAt: _loggedAt,
      confidence: 1.0,
      requiresClarification: false,
      clarificationPrompt: null,
    );

    setState(() {
      _saving = true;
      _status = 'Saving medication log...';
    });

    try {
      await AppServices.medicationLoggingService.saveConfirmedDraft(confirmed);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status =
            'Could not save right now. Your note is still on this screen.';
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Log Medication')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            Text('Review-before-save medication log', style: tt.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Type or dictate what happened, review the parsed details, then confirm.',
              style: tt.bodyMedium,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _rawController,
              minLines: 3,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                labelText: 'What happened?',
                hintText:
                    'Example: Took Humira 40 mg this morning after breakfast.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: (_building || _saving) ? null : _buildDraft,
                  icon: const Icon(Icons.rule_folder_outlined),
                  label: Text(_building ? 'Building...' : 'Build review card'),
                ),
                OutlinedButton.icon(
                  onPressed: (_building || _saving) ? null : _toggleVoice,
                  icon: Icon(_listening ? Icons.stop : Icons.mic_none_outlined),
                  label: Text(_listening ? 'Stop voice' : 'Voice input'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: tt.bodySmall),
            ],
            if (_draft != null) ...[
              const SizedBox(height: 18),
              Text('Confirm details', style: tt.titleMedium),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _eventType,
                items: const [
                  DropdownMenuItem(
                    value: 'medication_taken',
                    child: Text('Medication taken'),
                  ),
                  DropdownMenuItem(
                    value: 'medication_skipped',
                    child: Text('Medication skipped'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _eventType = value);
                      },
                decoration: const InputDecoration(
                  labelText: 'Event type',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Medication name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _doseController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Dose (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _scheduleController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Timing/schedule (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notesController,
                enabled: !_saving,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _confirmSave,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(_saving ? 'Saving...' : 'Confirm and save'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () {
                              setState(() {
                                _draft = null;
                              });
                            },
                      child: const Text('Cancel review'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
