import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LabEntryScreen
//
// Allows the user to enter CRP / ESR / Fecal Calprotectin results from clinic.
// These are the ONLY inputs that can't come from Apple Watch.
//
// Paper thresholds (Hirten et al. 2025 Methods):
//   CRP > 5 mg/dL          → inflammatory flare signal
//   ESR > 30 mm/h          → inflammatory flare signal
//   FC  > 150 μg/g         → inflammatory flare signal
//
// After saving: triggers FlareLabelService recompute for ±7d window
// so the logistic model gets updated ground-truth labels.
// ─────────────────────────────────────────────────────────────────────────────

class LabEntryScreen extends StatefulWidget {
  const LabEntryScreen({super.key});

  @override
  State<LabEntryScreen> createState() => _LabEntryScreenState();
}

class _LabEntryScreenState extends State<LabEntryScreen> {
  static const _labTypes = ['crp', 'esr', 'fc'];
  static const _labLabels = {
    'crp': 'C-Reactive Protein (CRP)',
    'esr': 'Sed Rate (ESR)',
    'fc': 'Fecal Calprotectin (FC)',
  };
  static const _labUnits = {'crp': 'mg/dL', 'esr': 'mm/h', 'fc': 'μg/g'};
  static const _labThresholds = {'crp': 5.0, 'esr': 30.0, 'fc': 150.0};
  static const _labHints = {
    'crp': 'e.g. 2.4',
    'esr': 'e.g. 18',
    'fc': 'e.g. 120',
  };

  String _selectedType = 'crp';
  final _valueController = TextEditingController();
  DateTime _drawnDate = DateTime.now();
  final _notesController = TextEditingController();
  bool _submitting = false;
  List<LabValueRecord> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _valueController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final vals = await AppServices.wearableSampleRepository.getLabValues();
    if (!mounted) return;
    setState(() {
      _history = vals;
      _loading = false;
    });
  }

  // ── Derived state ─────────────────────────────────────────────────────────

  double? get _parsedValue => double.tryParse(_valueController.text.trim());
  double get _threshold => _labThresholds[_selectedType]!;
  String get _unit => _labUnits[_selectedType]!;
  bool get _isElevated => (_parsedValue ?? 0) > _threshold;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _drawnDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() => _drawnDate = picked);
    }
  }

  String get _formattedDate {
    return '${_drawnDate.year.toString().padLeft(4, '0')}-'
        '${_drawnDate.month.toString().padLeft(2, '0')}-'
        '${_drawnDate.day.toString().padLeft(2, '0')}';
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final value = _parsedValue;
    if (value == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid number.')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final now = DateTime.now().toUtc();
      final record = LabValueRecord(
        drawnDate: _formattedDate,
        labType: _selectedType,
        valueNumeric: value,
        unit: _unit,
        referenceHigh: _threshold,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        createdAt: now,
        updatedAt: now,
      );
      final id = await AppServices.wearableSampleRepository.upsertLabValue(
        record,
      );
      unawaited(_indexLabForRag(id, record));

      try {
        await AppServices.analyticsRefreshService
            .refreshForLab(drawnDate: _formattedDate)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Saving the lab should not fail because analytics refresh is slow.
      }
      _refreshGuidance('legacy_lab_saved');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved: ${_labLabels[_selectedType]} $value $_unit — '
            '${_isElevated ? "Elevated (above ${_threshold.toStringAsFixed(0)})" : "Normal"}',
          ),
        ),
      );
      _valueController.clear();
      _notesController.clear();
      await _loadHistory();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "We couldn't save that lab result. Please try again.",
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _indexLabForRag(int id, LabValueRecord record) async {
    try {
      await AppServices.ragIndexService.indexLabValue(
        id: id,
        lab: record,
      );
    } catch (_) {}
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _delete(LabValueRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete lab result?'),
        content: Text(
          'Remove ${_labLabels[record.labType] ?? record.labType} '
          '${record.valueNumeric} ${record.unit} from ${record.drawnDate}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || record.id == null) return;
    await AppServices.wearableSampleRepository.deleteLabValue(record.id!);
    try {
      await AppServices.analyticsRefreshService
          .refreshForLab(drawnDate: record.drawnDate)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Deleting the lab should not fail because analytics refresh is slow.
    }
    _refreshGuidance('legacy_lab_deleted');
    await _loadHistory();
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Lab save/delete should not fail because background guidance refresh did.
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(title: const Text('Add Lab Result')),
        body: SafeArea(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              Text('Lab Results', style: tt.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Enter results from clinic visits. CRP, ESR, and fecal calprotectin define inflammatory flare.',
                style: tt.bodySmall?.copyWith(color: cs.outline),
              ),

              const SizedBox(height: 20),

              // ── Lab type picker ────────────────────────────────────────────────
              SegmentedButton<String>(
                segments: _labTypes
                    .map(
                      (t) => ButtonSegment<String>(
                        value: t,
                        label: Text(t.toUpperCase()),
                      ),
                    )
                    .toList(),
                selected: {_selectedType},
                onSelectionChanged: (s) => setState(() {
                  _selectedType = s.first;
                  _valueController.clear();
                }),
              ),

              const SizedBox(height: 6),
              Text(
                _labLabels[_selectedType]!,
                style: tt.bodySmall?.copyWith(color: cs.outline),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 20),

              // ── Value entry ────────────────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _valueController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d*'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Value',
                        hintText: _labHints[_selectedType],
                        suffixText: _unit,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: _pickDate,
                      borderRadius: BorderRadius.circular(12),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Draw date',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          suffixIcon: const Icon(
                            Icons.calendar_today_rounded,
                            size: 18,
                          ),
                        ),
                        child: Text(_formattedDate),
                      ),
                    ),
                  ),
                ],
              ),

              // ── Threshold indicator ────────────────────────────────────────────
              if (_parsedValue != null) ...[
                const SizedBox(height: 10),
                _ThresholdIndicator(
                  value: _parsedValue!,
                  threshold: _threshold,
                  unit: _unit,
                  isElevated: _isElevated,
                ),
              ],

              const SizedBox(height: 16),

              TextField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'Lab name, symptoms at time of draw...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
              ),

              const SizedBox(height: 16),

              FilledButton.icon(
                onPressed: _submitting || _parsedValue == null ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(_submitting ? 'Saving...' : 'Save result'),
              ),

              // ── History ────────────────────────────────────────────────────────
              if (!_loading && _history.isNotEmpty) ...[
                const SizedBox(height: 28),
                Row(
                  children: [
                    Icon(Icons.history_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Lab history',
                      style: tt.titleMedium?.copyWith(color: cs.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._history.map(
                  (r) => _LabHistoryTile(
                    record: r,
                    label: _labLabels[r.labType] ?? r.labType,
                    threshold: _labThresholds[r.labType] ?? 0,
                    onDelete: () => _delete(r),
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Text(
                'Lab data stays on your device and is used only to calibrate your personal flare forecast model.',
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(color: cs.outline),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ThresholdIndicator
// ─────────────────────────────────────────────────────────────────────────────

class _ThresholdIndicator extends StatelessWidget {
  const _ThresholdIndicator({
    required this.value,
    required this.threshold,
    required this.unit,
    required this.isElevated,
  });

  final double value;
  final double threshold;
  final String unit;
  final bool isElevated;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final color = isElevated ? cs.error : Colors.green.shade600;
    final label = isElevated
        ? 'Elevated — above threshold of ${threshold.toStringAsFixed(0)} $unit'
        : 'Normal — below threshold of ${threshold.toStringAsFixed(0)} $unit';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(
            isElevated
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Text(label, style: tt.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _LabHistoryTile
// ─────────────────────────────────────────────────────────────────────────────

class _LabHistoryTile extends StatelessWidget {
  const _LabHistoryTile({
    required this.record,
    required this.label,
    required this.threshold,
    required this.onDelete,
  });

  final LabValueRecord record;
  final String label;
  final double threshold;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final elevated = record.valueNumeric > threshold;
    final color = elevated ? cs.error : Colors.green.shade600;

    return Dismissible(
      key: ValueKey('lab_${record.id}_${record.drawnDate}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: cs.errorContainer,
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // We handle deletion manually via onDelete
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                record.valueNumeric.toStringAsFixed(
                  record.valueNumeric < 10 ? 1 : 0,
                ),
                style: tt.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: tt.bodyMedium),
                  Text(
                    '${record.drawnDate} · ${record.unit} · '
                    '${elevated ? "Elevated" : "Normal"}',
                    style: tt.bodySmall?.copyWith(color: cs.outline),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: cs.outline,
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
