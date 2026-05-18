import 'package:flutter/material.dart';

import '../../../core/services/pinned_fact_service.dart';

/// Editable card showing the user's pinned health facts (Tier 1 memory).
///
/// Shows a scrollable list of key→value rows derived from [fact.content].
/// Each row has an inline edit button. Changes are submitted via [onUpdate].
class FactCardEditorWidget extends StatefulWidget {
  const FactCardEditorWidget({
    super.key,
    required this.fact,
    required this.onUpdate,
    required this.onDelete,
  });

  final PinnedFact? fact;
  final Future<void> Function(String field, Object? value) onUpdate;
  final Future<void> Function() onDelete;

  @override
  State<FactCardEditorWidget> createState() => _FactCardEditorWidgetState();
}

class _FactCardEditorWidgetState extends State<FactCardEditorWidget> {
  bool _editing = false;
  String? _editingKey;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static const _fieldLabels = <String, String>{
    'name': 'Name',
    'age': 'Age',
    'diagnosis': 'Diagnosis',
    'diagnosis_year': 'Diagnosed year',
    'current_medications': 'Medications',
    'allergies': 'Allergies',
    'surgeon': 'Surgeon / GI doctor',
    'last_colonoscopy': 'Last colonoscopy',
    'baseline_crp': 'Baseline CRP',
    'baseline_calprotectin': 'Baseline calprotectin',
    'typical_flare_triggers': 'Known triggers',
    'goals': 'Goals',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = widget.fact?.content ?? {};

    return Card(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Your health profile',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (widget.fact != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete health profile',
                    onPressed: _confirmDelete,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (content.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No health facts saved yet. '
                  'Gemma Flares will fill this in as you chat.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              )
            else
              ..._fieldLabels.entries.map((entry) {
                final value = content[entry.key];
                if (value == null) return const SizedBox.shrink();
                return _FactRow(
                  label: entry.value,
                  fieldKey: entry.key,
                  value: value.toString(),
                  onEdit: _startEdit,
                );
              }),
            const SizedBox(height: 4),
            if (_editing && _editingKey != null)
              _InlineEditRow(
                label: _fieldLabels[_editingKey!] ?? _editingKey!,
                controller: _controller,
                onSave: _saveEdit,
                onCancel: _cancelEdit,
              ),
          ],
        ),
      ),
    );
  }

  void _startEdit(String key, String currentValue) {
    setState(() {
      _editing = true;
      _editingKey = key;
      _controller.text = currentValue;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _editingKey = null;
    });
  }

  Future<void> _saveEdit() async {
    final key = _editingKey;
    if (key == null) return;
    final value = _controller.text.trim();
    _cancelEdit();
    await widget.onUpdate(key, value.isEmpty ? null : value);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete health profile?'),
        content: const Text(
          'This removes all pinned facts. Gemma Flares will start fresh. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onDelete();
    }
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.fieldKey,
    required this.value,
    required this.onEdit,
  });

  final String label;
  final String fieldKey;
  final String value;
  final void Function(String key, String value) onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: 'Edit $label',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => onEdit(fieldKey, value),
          ),
        ],
      ),
    );
  }
}

class _InlineEditRow extends StatelessWidget {
  const _InlineEditRow({
    required this.label,
    required this.controller,
    required this.onSave,
    required this.onCancel,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer.withAlpha(80),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Editing: $label',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(isDense: true),
            onSubmitted: (_) => onSave(),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onSave, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
