import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/widgets/research_link.dart';

class AddLabScreen extends StatefulWidget {
  const AddLabScreen({super.key, this.initialRecord});

  final LabValueRecord? initialRecord;

  @override
  State<AddLabScreen> createState() => _AddLabScreenState();
}

class _AddLabScreenState extends State<AddLabScreen> {
  static const _labDefinitions = <_LabDefinition>[
    _LabDefinition(
      key: 'crp',
      label: 'CRP (Inflammation marker)',
      unit: 'mg/dL',
      helper: 'Normal: below 5 mg/dL',
      hint: 'e.g. 7.2',
      referenceHigh: 5,
      group: 'Inflammation Blood Tests',
    ),
    _LabDefinition(
      key: 'esr',
      label: 'ESR (Sedimentation rate)',
      unit: 'mm/h',
      helper: 'Normal: below 30 mm/h',
      hint: 'e.g. 22',
      referenceHigh: 30,
      group: 'Inflammation Blood Tests',
    ),
    _LabDefinition(
      key: 'fc',
      label: 'Fecal Calprotectin',
      unit: 'μg/g',
      helper: 'Normal: below 150 μg/g',
      hint: 'e.g. 180',
      referenceHigh: 150,
      group: 'Stool Tests',
    ),
    _LabDefinition(
      key: 'lactoferrin',
      label: 'Lactoferrin',
      unit: 'μg/mL',
      helper: 'Optional stool inflammation marker.',
      hint: 'e.g. 12.0',
      group: 'Stool Tests',
    ),
    _LabDefinition(
      key: 'hemoglobin',
      label: 'Hemoglobin',
      unit: 'g/dL',
      helper: 'Normal: about 12.0-17.5 g/dL',
      hint: 'e.g. 13.8',
      group: 'Blood Count & Nutrients',
    ),
    _LabDefinition(
      key: 'wbc',
      label: 'WBC (White blood cells)',
      unit: '×10⁹/L',
      helper: 'General immune-system count.',
      hint: 'e.g. 8.1',
      group: 'Blood Count & Nutrients',
    ),
    _LabDefinition(
      key: 'albumin',
      label: 'Albumin',
      unit: 'g/dL',
      helper: 'Normal: about 3.5-5.0 g/dL',
      hint: 'e.g. 4.1',
      group: 'Blood Count & Nutrients',
    ),
    _LabDefinition(
      key: 'vitamin_d',
      label: 'Vitamin D',
      unit: 'ng/mL',
      helper: 'Optional nutrient marker.',
      hint: 'e.g. 31',
      group: 'Blood Count & Nutrients',
    ),
    _LabDefinition(
      key: 'ferritin',
      label: 'Ferritin',
      unit: 'ng/mL',
      helper: 'Iron storage marker.',
      hint: 'e.g. 48',
      group: 'Blood Count & Nutrients',
    ),
    _LabDefinition(
      key: 'b12',
      label: 'Vitamin B12',
      unit: 'pg/mL',
      helper: 'Optional nutrient marker.',
      hint: 'e.g. 550',
      group: 'Blood Count & Nutrients',
    ),
  ];

  final _labNameController = TextEditingController();
  final _providerController = TextEditingController();
  final _notesController = TextEditingController();
  final Map<String, TextEditingController> _valueControllers = {
    for (final definition in _labDefinitions)
      definition.key: TextEditingController(),
  };
  final Map<String, FocusNode> _valueFocusNodes = {
    for (final definition in _labDefinitions) definition.key: FocusNode(),
  };

  DateTime _drawnDate = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRecord;
    if (initial == null) {
      return;
    }
    _drawnDate = DateTime.parse('${initial.drawnDate}T00:00:00Z');
    _labNameController.text = initial.labName ?? '';
    _providerController.text = initial.orderingProvider ?? '';
    _notesController.text = initial.notes ?? '';
    _valueControllers[initial.labType]?.text = initial.valueNumeric.toString();
  }

  @override
  void dispose() {
    _labNameController.dispose();
    _providerController.dispose();
    _notesController.dispose();
    for (final controller in _valueControllers.values) {
      controller.dispose();
    }
    for (final node in _valueFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _drawnDate,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() => _drawnDate = picked);
    }
  }

  Future<void> _save() async {
    final enteredDefinitions = _labDefinitions.where((definition) {
      return double.tryParse(
            _valueControllers[definition.key]!.text.trim(),
          ) !=
          null;
    }).toList(growable: false);

    if (enteredDefinitions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least one lab value before saving.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final now = DateTime.now().toUtc();
      for (var index = 0; index < enteredDefinitions.length; index++) {
        final definition = enteredDefinitions[index];
        final value = double.parse(
          _valueControllers[definition.key]!.text.trim(),
        );
        final record = LabValueRecord(
          id: widget.initialRecord?.labType == definition.key
              ? widget.initialRecord?.id
              : null,
          drawnDate: _dateOnly(_drawnDate),
          labType: definition.key,
          valueNumeric: value,
          unit: definition.unit,
          referenceHigh: definition.referenceHigh,
          labName: _emptyToNull(_labNameController.text),
          orderingProvider: _emptyToNull(_providerController.text),
          notes: _emptyToNull(_notesController.text),
          createdAt: widget.initialRecord?.createdAt ?? now,
          updatedAt: now,
        );
        final id = await AppServices.wearableSampleRepository.upsertLabValue(
          record,
        );
        unawaited(_indexLabForRag(id, record));
      }

      await AppServices.analyticsRefreshService.refreshForLab(
        drawnDate: _dateOnly(_drawnDate),
      );
      _refreshGuidance('lab_saved');

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.initialRecord == null
                ? 'Saved ${enteredDefinitions.length} lab result${enteredDefinitions.length == 1 ? '' : 's'}.'
                : 'Updated lab result.',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "We couldn't save those lab results. Please try again.",
          ),
          action: SnackBarAction(label: 'Retry', onPressed: _save),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final groupedDefinitions = <String, List<_LabDefinition>>{};
    for (final definition in _labDefinitions) {
      groupedDefinitions
          .putIfAbsent(definition.group, () => <_LabDefinition>[])
          .add(definition);
    }
    final orderedDefinitions = _labDefinitions.toList(growable: false);

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(title: const Text('Add Lab Result')),
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'When were your samples collected?',
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: const Icon(Icons.calendar_today_outlined),
                    ),
                    child: Text(_prettyDate(_drawnDate)),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _labNameController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Where were these done? (optional)',
                    hintText: 'Lab or doctor\'s office',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _providerController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Ordering doctor (optional)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Fill in what you have. Leave anything blank if you do not have that result.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 20),
                for (final group in groupedDefinitions.entries) ...[
                  Text(group.key, style: textTheme.titleMedium),
                  const SizedBox(height: 12),
                  for (final definition in group.value) ...[
                    _LabInputCard(
                      definition: definition,
                      controller: _valueControllers[definition.key]!,
                      focusNode: _valueFocusNodes[definition.key]!,
                      textInputAction:
                          definition.key == orderedDefinitions.last.key
                              ? TextInputAction.done
                              : TextInputAction.next,
                      onSubmitted: (_) =>
                          _focusNext(definition.key, orderedDefinitions),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _notesController,
                  minLines: 2,
                  maxLines: 3,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText:
                        'Symptoms, report comments, or anything you want to remember',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  title: const Text('Why add these?'),
                  children: const [
                    Text(
                      'Your lab results help Gemma Flares confirm when inflammation was active. They do not replace your Apple Watch data. They act as a reality check so the forecast model learns when the wearable signals were right.',
                    ),
                    ResearchLink(),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'These results stay on your phone only. They are not uploaded or shared.',
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving...' : 'Save lab results'),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _focusNext(String key, List<_LabDefinition> orderedDefinitions) {
    final index = orderedDefinitions.indexWhere(
      (definition) => definition.key == key,
    );
    if (index == -1 || index == orderedDefinitions.length - 1) {
      FocusScope.of(context).unfocus();
      return;
    }
    final nextKey = orderedDefinitions[index + 1].key;
    FocusScope.of(context).requestFocus(_valueFocusNodes[nextKey]);
  }

  Future<void> _indexLabForRag(int id, LabValueRecord record) async {
    try {
      await AppServices.ragIndexService.indexLabValue(
        id: id,
        lab: record,
      );
    } catch (_) {}
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Lab saves should not fail because background guidance refresh did.
    }
  }

  String _dateOnly(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _prettyDate(DateTime date) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month]} ${date.day}, ${date.year}';
  }

  String? _emptyToNull(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _LabInputCard extends StatelessWidget {
  const _LabInputCard({
    required this.definition,
    required this.controller,
    required this.focusNode,
    required this.textInputAction,
    required this.onSubmitted,
  });

  final _LabDefinition definition;
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextInputAction textInputAction;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              definition.label,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: textInputAction,
              onSubmitted: onSubmitted,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              decoration: InputDecoration(
                hintText: definition.hint,
                suffixText: definition.unit,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              definition.helper,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabDefinition {
  const _LabDefinition({
    required this.key,
    required this.label,
    required this.unit,
    required this.helper,
    required this.hint,
    required this.group,
    this.referenceHigh,
  });

  final String key;
  final String label;
  final String unit;
  final String helper;
  final String hint;
  final String group;
  final double? referenceHigh;
}
