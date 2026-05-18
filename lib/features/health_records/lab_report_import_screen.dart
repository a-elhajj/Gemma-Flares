import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_services.dart';
import '../../core/services/gemma_task_service.dart';
import '../../core/services/lab_logging_service.dart';
import '../../core/services/photo_crop_service.dart';
import '../../core/widgets/model_use_badge.dart';

class LabReportImportScreen extends StatefulWidget {
  const LabReportImportScreen({
    super.key,
    this.initialText,
    this.initialStatus,
  });

  final String? initialText;
  final String? initialStatus;

  @override
  State<LabReportImportScreen> createState() => _LabReportImportScreenState();
}

class _LabReportImportScreenState extends State<LabReportImportScreen> {
  final _textController = TextEditingController();
  final _imagePicker = ImagePicker();
  GemmaLabExtractionResult? _result;
  final Set<int> _selectedCandidateIndexes = <int>{};
  String? _status;
  bool _working = false;
  bool _saving = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final initialText = widget.initialText?.trim();
    if (initialText != null && initialText.isNotEmpty) {
      _textController.text = initialText;
      _status = widget.initialStatus ??
          'OCR text loaded. Review it, then extract labs.';
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _status = 'Clipboard has no lab-report text.');
      return;
    }
    setState(() {
      _textController.text = text;
      _status = 'Pasted text. Review it, then extract labs.';
      _result = null;
      _selectedCandidateIndexes.clear();
    });
  }

  Future<void> _scan({required bool camera}) async {
    setState(() {
      _working = true;
      _status = camera ? 'Opening camera...' : 'Opening photo picker...';
    });
    try {
      final file = await _imagePicker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1280,
        maxHeight: 1280,
      );
      if (file == null || !mounted) {
        if (mounted) setState(() => _status = 'Photo selection cancelled.');
        return;
      }
      setState(() => _status = 'Crop the report area, then tap Use Photo.');
      final croppedPath = await PhotoCropService.cropImageForUpload(
        context: context,
        sourcePath: file.path,
      );
      if (croppedPath == null || !mounted) {
        if (mounted) setState(() => _status = 'Photo crop cancelled.');
        return;
      }
      setState(() => _status = 'Reading cropped photo...');
      final result = await AppServices.labReportOcrService.recognizeTextAtPath(
        croppedPath,
      );
      if (!mounted) return;
      if (result.status == 'success' && result.text.trim().isNotEmpty) {
        setState(() {
          _textController.text = result.text.trim();
          _status = 'OCR text loaded. Review it, then extract labs.';
          _result = null;
          _selectedCandidateIndexes.clear();
        });
      } else {
        setState(
          () => _status = result.reason ??
              'OCR did not return text. You can paste manually.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _extract() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() => _status = 'Paste or scan lab-report text first.');
      return;
    }
    setState(() {
      _working = true;
      _status = 'Gemma 4 is extracting structured lab values...';
      _result = null;
    });
    try {
      final result = await AppServices.gemmaTaskService.extractLabsFromText(
        reportText: text,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _selectedCandidateIndexes
          ..clear()
          ..addAll(
            List<int>.generate(result.candidates.length, (index) => index),
          );
        _status = result.candidates.isEmpty
            ? 'No supported lab values found. You can still add labs manually.'
            : 'Review extracted values before saving.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _status =
              'Could not extract labs right now. You can edit the text and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null || result.candidates.isEmpty) return;
    final selectedCandidates = _selectedCandidates(result);
    if (selectedCandidates.isEmpty) {
      setState(() => _status = 'Select at least one confirmed lab to save.');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await AppServices.labLoggingService.saveCandidates(
        candidates: selectedCandidates,
        reviewId: result.reviewId,
        source: 'lab_report_import',
      );
      _refreshGuidance('lab_report_import_saved');
      if (!mounted) return;
      await _showSaveReceipt(saved);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status =
            "We couldn't save those lab results. Nothing new was confirmed. Please try again.";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "We couldn't save those lab results. Please try again.",
          ),
          action: SnackBarAction(label: 'Retry', onPressed: _save),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<GemmaLabCandidate> _selectedCandidates(GemmaLabExtractionResult result) {
    return [
      for (var index = 0; index < result.candidates.length; index++)
        if (_selectedCandidateIndexes.contains(index)) result.candidates[index],
    ];
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Import save already succeeded; guidance can retry on resume.
    }
  }

  Future<void> _showSaveReceipt(LabLoggingResult saved) async {
    final savedLines = saved.savedLabs
        .map(
          (lab) =>
              '${lab.labType.toUpperCase()} ${lab.valueNumeric} ${lab.unit} (${lab.drawnDate})',
        )
        .toList(growable: false);
    final memoryLines = saved.savedLabs.map((lab) {
      final id = lab.id;
      final status = id == null ? 'not_recorded' : saved.ragStatusByLabId[id];
      final tx = id == null ? null : saved.ragTransactionIdByLabId[id];
      final validated = id == null ? null : saved.ragValidatedByLabId[id];
      final validationStatus =
          id == null ? null : saved.ragValidationStatusByLabId[id];
      final validationText = validated == true
          ? 'validated'
          : validationStatus == null
              ? 'validation_unavailable'
              : 'validation_$validationStatus';
      return '${lab.labType.toUpperCase()}: ${status ?? 'not_indexed'}${tx == null ? '' : ' • $tx'} • $validationText';
    }).toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('Labs saved'),
        content: SingleChildScrollView(
          child: Text(
            [
              'Saved ${saved.savedLabs.length} confirmed lab value${saved.savedLabs.length == 1 ? '' : 's'} to Health Records.',
              '',
              'Summary:',
              ...savedLines,
              '',
              'RAG memory:',
              ...memoryLines,
              '',
              'Tool audit: ${saved.toolAuditId == null ? 'not recorded' : '#${saved.toolAuditId}'}',
              'Risk context: ${saved.analyticsRefreshStatus}',
            ].join('\n'),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final result = _result;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Scan Lab Report')),
        body: SafeArea(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              Text('Gemma 4 Lab Import', style: tt.headlineSmall),
              const SizedBox(height: 6),
              Text(
                'Scan or paste report text. Gemma extracts candidates, and you confirm before anything is saved.',
                style: tt.bodyMedium?.copyWith(color: cs.outline),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _working ? null : () => _scan(camera: true),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Scan'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : () => _scan(camera: false),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Choose photo'),
                  ),
                  TextButton.icon(
                    onPressed: _working ? null : _paste,
                    icon: const Icon(Icons.content_paste_outlined),
                    label: const Text('Paste text'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _textController,
                minLines: 8,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Lab report text',
                  hintText: 'Paste OCR text or a lab report snippet here...',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _working ? null : _extract,
                icon: _working
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined),
                label: const Text('Extract with Gemma 4'),
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(
                  _status!,
                  style: tt.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
              if (result != null) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Review before saving',
                        style: tt.titleMedium,
                      ),
                    ),
                    ModelUseBadge(usedModelOutput: result.usedModelOutput),
                  ],
                ),
                const SizedBox(height: 8),
                if (result.validationErrors.isNotEmpty)
                  _Notice(
                    text: result.validationErrors.join('\n'),
                    color: cs.error,
                  ),
                for (var index = 0; index < result.candidates.length; index++)
                  _LabCandidateTile(
                    candidate: result.candidates[index],
                    selected: _selectedCandidateIndexes.contains(index),
                    onChanged: (selected) {
                      setState(() {
                        if (selected == true) {
                          _selectedCandidateIndexes.add(index);
                        } else {
                          _selectedCandidateIndexes.remove(index);
                        }
                      });
                    },
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _saving ||
                          result.candidates.isEmpty ||
                          _selectedCandidateIndexes.isEmpty
                      ? null
                      : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving...' : 'Save confirmed labs'),
                ),
                const SizedBox(height: 8),
                EvidenceReceipt(
                  usedModelOutput: result.usedModelOutput,
                  evidenceHash: null,
                  generatedAt: null,
                  status: result.status,
                  traceJson: {
                    'task_run_id': result.taskRunId,
                    'review_id': result.reviewId,
                  },
                ),
              ],
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _working || _saving
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabCandidateTile extends StatelessWidget {
  const _LabCandidateTile({
    required this.candidate,
    required this.selected,
    required this.onChanged,
  });

  final GemmaLabCandidate candidate;
  final bool selected;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final elevated = candidate.referenceHigh != null &&
        candidate.valueNumeric > candidate.referenceHigh!;
    return Card(
      child: CheckboxListTile(
        value: selected,
        onChanged: onChanged,
        title: Text(candidate.labType.toUpperCase(), style: tt.titleMedium),
        subtitle: Text(
          [
            '${candidate.valueNumeric} ${candidate.unit} on ${candidate.drawnDate}',
            if (candidate.referenceHigh != null)
              'Reference high ${candidate.referenceHigh}',
            if (candidate.sourceTextSnippet != null)
              candidate.sourceTextSnippet!,
          ].join('\n'),
        ),
        secondary: Chip(
          label: Text(elevated ? 'review' : 'ok'),
          backgroundColor:
              (elevated ? cs.errorContainer : cs.secondaryContainer).withValues(
            alpha: 0.7,
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
