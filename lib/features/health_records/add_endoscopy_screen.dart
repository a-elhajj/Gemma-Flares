import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';

class AddEndoscopyScreen extends StatefulWidget {
  const AddEndoscopyScreen({super.key});

  @override
  State<AddEndoscopyScreen> createState() => _AddEndoscopyScreenState();
}

class _AddEndoscopyScreenState extends State<AddEndoscopyScreen> {
  static const _procedureTypes = [
    ('colonoscopy', 'Colonoscopy'),
    ('sigmoidoscopy', 'Sigmoidoscopy'),
    ('upper_endoscopy', 'Upper endoscopy'),
    ('capsule', 'Capsule'),
  ];

  static const _rutgeertsOptions = ['i0', 'i1', 'i2a', 'i2b', 'i3', 'i4'];
  static const _biopsyOptions = [
    ('active_inflammation', 'Active inflammation'),
    ('remission', 'Remission'),
    ('uncertain', 'Uncertain'),
    ('other', 'Other'),
  ];

  DateTime _procedureDate = DateTime.now();
  String _procedureType = 'colonoscopy';
  int? _mayoScore;
  final _sesCdController = TextEditingController();
  String? _rutgeertsScore;
  bool _biopsiesTaken = false;
  String? _biopsyResult;
  final _providerController = TextEditingController();
  final _findingsController = TextEditingController();
  final _notesController = TextEditingController();
  bool _saving = false;
  bool _isCrohns = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _sesCdController.dispose();
    _providerController.dispose();
    _findingsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final profile = await AppServices.profileService.loadProfile();
    if (!mounted) {
      return;
    }
    setState(() {
      _isCrohns = profile.diseaseType != 'UC';
    });
  }

  Future<void> _pickProcedureDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _procedureDate,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() => _procedureDate = picked);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final record = EndoscopyRecord(
        procedureDate: _dateOnly(_procedureDate),
        procedureType: _procedureType,
        mayoEndoscopicScore: _mayoScore,
        sesCdScore: int.tryParse(_sesCdController.text.trim()),
        rutgeertsScore: _rutgeertsScore,
        findingsText: _findingsController.text.trim().isEmpty
            ? null
            : _findingsController.text.trim(),
        biopsiesTaken: _biopsiesTaken,
        biopsyResult: _biopsiesTaken ? _biopsyResult : null,
        provider: _providerController.text.trim().isEmpty
            ? null
            : _providerController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        createdAt: DateTime.now().toUtc(),
      );

      final id = await AppServices.wearableSampleRepository
          .insertEndoscopyRecord(record);
      unawaited(_indexProcedureForRag(id, record));
      await AppServices.analyticsRefreshService.refreshForProcedure(
        procedureDate: _dateOnly(_procedureDate),
      );
      _refreshGuidance('procedure_saved');

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Procedure saved.')));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "We couldn't save that procedure. Please try again.",
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

  String _dateOnly(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _indexProcedureForRag(int id, EndoscopyRecord record) async {
    try {
      await AppServices.ragIndexService.indexEndoscopyRecord(
        id: id,
        record: record,
      );
    } catch (_) {}
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Procedure saves should not fail because guidance refresh did.
    }
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(title: const Text('Add Procedure Result')),
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Procedure date'),
                  subtitle: Text(_prettyDate(_procedureDate)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: _pickProcedureDate,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _procedureType,
                  items: _procedureTypes
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.$1,
                          child: Text(item.$2),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _procedureType = value);
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: 'Procedure type',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _providerController,
                  decoration: const InputDecoration(
                    labelText: 'Doctor or hospital (optional)',
                  ),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 16),
                if (_isCrohns) ...[
                  TextField(
                    controller: _sesCdController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'SES-CD score (optional)',
                      hintText: '0 to 56',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _rutgeertsScore,
                    items: _rutgeertsOptions
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item,
                            child: Text(item),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) =>
                        setState(() => _rutgeertsScore = value),
                    decoration: const InputDecoration(
                      labelText: 'Rutgeerts score (optional)',
                    ),
                  ),
                ] else ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Normal')),
                      ButtonSegment(value: 1, label: Text('Mild')),
                      ButtonSegment(value: 2, label: Text('Moderate')),
                      ButtonSegment(value: 3, label: Text('Severe')),
                    ],
                    selected: _mayoScore == null ? const {} : {_mayoScore!},
                    emptySelectionAllowed: true,
                    onSelectionChanged: (selection) {
                      setState(() {
                        _mayoScore = selection.isEmpty ? null : selection.first;
                      });
                    },
                  ),
                ],
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Biopsies: Yes')),
                    ButtonSegment(value: false, label: Text('Biopsies: No')),
                  ],
                  selected: {_biopsiesTaken},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _biopsiesTaken = selection.first;
                      if (!_biopsiesTaken) {
                        _biopsyResult = null;
                      }
                    });
                  },
                ),
                if (_biopsiesTaken) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _biopsyResult,
                    items: _biopsyOptions
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item.$1,
                            child: Text(item.$2),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) => setState(() => _biopsyResult = value),
                    decoration: const InputDecoration(
                      labelText: 'Biopsy result',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _findingsController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Findings (optional)',
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving...' : 'Save procedure'),
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
}
