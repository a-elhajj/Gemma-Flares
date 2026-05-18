import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/ibd_checkin_service.dart';
import 'add_endoscopy_screen.dart';
import 'add_lab_screen.dart';
import 'add_medication_log_screen.dart';
import 'doctor_summary_screen.dart';
import 'lab_report_import_screen.dart';

class HealthRecordsScreen extends StatefulWidget {
  const HealthRecordsScreen({super.key});

  @override
  State<HealthRecordsScreen> createState() => _HealthRecordsScreenState();
}

class _HealthRecordsScreenState extends State<HealthRecordsScreen> {
  List<FlareLabelRecord> _recentLabels = [];
  List<SymptomRecord> _symptoms = [];
  List<Pro2SurveyRecord> _checkIns = [];
  List<LabValueRecord> _labs = [];
  List<EndoscopyRecord> _procedures = [];
  List<IntakeEventRecord> _medicationEvents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final now = DateTime.now();
      final today = _dateOnly(now);
      final start = _dateOnly(now.subtract(const Duration(days: 29)));
      final results = await Future.wait([
        AppServices.wearableSampleRepository.getFlareLabelsInRange(
          start,
          today,
        ),
        AppServices.wearableSampleRepository.getRecentSymptoms(limit: null),
        AppServices.wearableSampleRepository.getRecentPro2Surveys(
          limit: 30,
        ),
        AppServices.wearableSampleRepository.getLabValues(),
        AppServices.wearableSampleRepository.getEndoscopyRecords(),
        AppServices.wearableSampleRepository.getIntakeEventsBetween(
          start: now.subtract(const Duration(days: 60)).toUtc(),
          end: now.toUtc(),
        ),
      ]).timeout(
        const Duration(seconds: 1),
        onTimeout: () => const [[], [], [], [], [], []],
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _recentLabels = (results[0] as List<FlareLabelRecord>)
            .where(
              (item) =>
                  item.inflammatoryFlare ||
                  item.symptomaticFlare ||
                  item.clinicalFlare,
            )
            .toList(growable: false);
        _symptoms = (results[1] as List<SymptomRecord>).toList(growable: false);
        _checkIns = (results[2] as List<Pro2SurveyRecord>).toList(
          growable: false,
        );
        _labs = (results[3] as List<LabValueRecord>).toList(growable: false);
        _procedures = (results[4] as List<EndoscopyRecord>).toList(
          growable: false,
        );
        _medicationEvents = (results[5] as List<IntakeEventRecord>)
            .where((item) => item.eventType.startsWith('medication_'))
            .toList(growable: false)
            .reversed
            .toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openLabEntry() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add lab result',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Choose the fastest way to add what you have.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('Enter manually'),
                onTap: () => Navigator.of(context).pop('manual'),
              ),
              ListTile(
                leading: const Icon(Icons.document_scanner_outlined),
                title: const Text('Scan or paste report'),
                onTap: () => Navigator.of(context).pop('scan'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    if (choice == 'scan') {
      await _openLabReportImport();
      return;
    }
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const AddLabScreen()));
    await _load();
    _refreshGuidance('lab_saved_from_health_records');
  }

  Future<void> _editLab(LabValueRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AddLabScreen(initialRecord: record),
      ),
    );
    await _load();
    _refreshGuidance('lab_edited_from_health_records');
  }

  Future<void> _deleteLab(LabValueRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete lab result?'),
        content: Text(
          'Remove ${_labDisplayName(record.labType)} from ${record.drawnDate}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || record.id == null) {
      return;
    }

    await AppServices.wearableSampleRepository.deleteLabValue(record.id!);
    await AppServices.analyticsRefreshService.refreshForLab(
      drawnDate: record.drawnDate,
    );
    await _load();
    _refreshGuidance('lab_deleted_from_health_records');
  }

  Future<void> _openLabReportImport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LabReportImportScreen()),
    );
    await _load();
    _refreshGuidance('lab_import_from_health_records');
  }

  Future<void> _openDoctorSummary() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const DoctorSummaryScreen()),
    );
    await _load();
  }

  Future<void> _openProcedureEntry() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AddEndoscopyScreen()),
    );
    await _load();
    _refreshGuidance('procedure_saved_from_health_records');
  }

  Future<void> _openMedicationLog() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const AddMedicationLogScreen()),
    );
    if (saved == true) {
      await _load();
      _refreshGuidance('medication_saved_from_health_records');
    }
  }

  Future<void> _deleteMedicationEvent(IntakeEventRecord record) async {
    if (record.id == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete medication log?'),
        content: Text(
          'Remove this medication event from ${_dateOnly(record.loggedAt.toLocal())}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    await AppServices.wearableSampleRepository.deleteIntakeEvent(record.id!);
    await AppServices.analyticsRefreshService.refreshForIntakeEvent(
      loggedAt: record.loggedAt,
    );
    await _load();
    _refreshGuidance('medication_deleted_from_health_records');
  }

  Future<void> _deleteProcedure(EndoscopyRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete procedure?'),
        content: Text(
          'Remove ${_procedureLabel(record.procedureType)} from ${record.procedureDate}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || record.id == null) {
      return;
    }

    await AppServices.wearableSampleRepository.deleteEndoscopyRecord(
      record.id!,
    );
    await AppServices.analyticsRefreshService.refreshForProcedure(
      procedureDate: record.procedureDate,
    );
    await _load();
    _refreshGuidance('procedure_deleted_from_health_records');
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await AppServices.guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Health-record edits stay saved even if guidance refresh retries later.
    }
  }

  String _dateOnly(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _procedureLabel(String type) {
    switch (type) {
      case 'colonoscopy':
        return 'Colonoscopy';
      case 'sigmoidoscopy':
        return 'Sigmoidoscopy';
      case 'upper_endoscopy':
        return 'Upper endoscopy';
      case 'capsule':
        return 'Capsule';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final compactLayout = MediaQuery.of(context).size.height < 700;

    if (_loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    return DefaultTabController(
      length: 6,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, compactLayout ? 10 : 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('My Health Records', style: tt.headlineMedium),
                  if (!compactLayout) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Lab results, procedures, and recent flare evidence stay on this phone only.',
                      style: tt.bodySmall?.copyWith(color: cs.outline),
                    ),
                    const SizedBox(height: 16),
                  ] else
                    const SizedBox(height: 8),
                  _HealthOverviewCard(
                    recentLabels: _recentLabels,
                    symptomCount: _symptoms.length,
                    checkInCount: _checkIns.length,
                    labCount: _labs.length,
                    procedureCount: _procedures.length,
                    medicationCount: _medicationEvents.length,
                    compactLayout: compactLayout,
                    onAddLab: _openLabEntry,
                    onAddProcedure: _openProcedureEntry,
                    onAddMedication: _openMedicationLog,
                    onDoctorSummary: _openDoctorSummary,
                  ),
                ],
              ),
            ),
            TabBar(
              isScrollable: true,
              tabs: const [
                Tab(text: 'Symptoms'),
                Tab(text: 'Check-ins'),
                Tab(text: 'Labs'),
                Tab(text: 'Procedures'),
                Tab(text: 'Medication'),
                Tab(text: 'Trend'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _SymptomsTab(symptoms: _symptoms),
                  _CheckInsTab(checkIns: _checkIns),
                  _LabResultsTab(
                    labs: _labs,
                    onAddLab: _openLabEntry,
                    onImportLabReport: _openLabReportImport,
                    onEditLab: _editLab,
                    onDeleteLab: _deleteLab,
                  ),
                  _ProcedureTab(
                    procedures: _procedures,
                    onAddProcedure: _openProcedureEntry,
                    onDeleteProcedure: _deleteProcedure,
                  ),
                  _MedicationTab(
                    events: _medicationEvents,
                    onAddMedication: _openMedicationLog,
                    onDeleteMedication: _deleteMedicationEvent,
                  ),
                  _TrendTab(labs: _labs, onAddLab: _openLabEntry),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthOverviewCard extends StatelessWidget {
  const _HealthOverviewCard({
    required this.recentLabels,
    required this.symptomCount,
    required this.checkInCount,
    required this.labCount,
    required this.procedureCount,
    required this.medicationCount,
    required this.compactLayout,
    required this.onAddLab,
    required this.onAddProcedure,
    required this.onAddMedication,
    required this.onDoctorSummary,
  });

  final List<FlareLabelRecord> recentLabels;
  final int symptomCount;
  final int checkInCount;
  final int labCount;
  final int procedureCount;
  final int medicationCount;
  final bool compactLayout;
  final VoidCallback onAddLab;
  final VoidCallback onAddProcedure;
  final VoidCallback onAddMedication;
  final VoidCallback onDoctorSummary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final recentClinical =
        recentLabels.where((item) => item.clinicalFlare).length;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compactLayout ? 12 : 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Health records', style: tt.titleMedium)),
              Icon(Icons.folder_shared_outlined, color: cs.primary, size: 20),
            ],
          ),
          SizedBox(height: compactLayout ? 6 : 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CountChip(label: 'Symptoms', value: '$symptomCount'),
              _CountChip(label: 'Check-ins', value: '$checkInCount'),
              _CountChip(label: 'Labs', value: '$labCount'),
              _CountChip(label: 'Procedures', value: '$procedureCount'),
              _CountChip(label: 'Medication', value: '$medicationCount'),
              if (recentClinical > 0)
                _CountChip(label: 'Clinical days', value: '$recentClinical'),
            ],
          ),
          SizedBox(height: compactLayout ? 8 : 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAddLab,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Add lab result'),
                ),
              ),
              SizedBox(width: compactLayout ? 8 : 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onAddMedication,
                  icon: const Icon(Icons.medication_outlined),
                  label: const Text('Log medication'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onAddProcedure,
              icon: const Icon(Icons.medical_services_outlined),
              label: const Text('Add procedure'),
            ),
          ),
          if (!compactLayout) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: onDoctorSummary,
              icon: const Icon(Icons.summarize_outlined),
              label: const Text('Prepare GI summary'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: tt.labelLarge?.copyWith(color: cs.onPrimaryContainer),
      ),
    );
  }
}

class _SymptomsTab extends StatelessWidget {
  const _SymptomsTab({required this.symptoms});

  final List<SymptomRecord> symptoms;

  @override
  Widget build(BuildContext context) {
    if (symptoms.isEmpty) {
      return const _EmptyState(
        icon: Icons.list_alt_rounded,
        title: 'No symptoms saved yet',
        message:
            'Symptoms you confirm from Chat or Voice Log will appear here and in Timeline.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: symptoms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final symptom = symptoms[index];
        final severity = symptom.severity == null
            ? 'Severity not recorded'
            : 'Severity ${symptom.severity}/10';
        final source = symptom.extractionMethod
            .replaceAll('_', ' ')
            .replaceAll('gemma4 e2b structured', 'Gemma 4');
        return Card(
          elevation: 0,
          child: ListTile(
            leading: const Icon(Icons.edit_note_rounded),
            title: Text(symptom.symptomType.replaceAll('_', ' ')),
            subtitle: Text(
              [
                _formatDateTime(symptom.loggedAt),
                severity,
                if (symptom.mealRelation != null)
                  symptom.mealRelation!.replaceAll('_', ' '),
                if ((symptom.notes ?? '').trim().isNotEmpty)
                  'Notes: ${symptom.notes!.trim()}',
                source,
              ].join(' · '),
            ),
          ),
        );
      },
    );
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _CheckInsTab extends StatelessWidget {
  const _CheckInsTab({required this.checkIns});

  final List<Pro2SurveyRecord> checkIns;

  @override
  Widget build(BuildContext context) {
    if (checkIns.isEmpty) {
      return const _EmptyState(
        icon: Icons.fact_check_outlined,
        title: 'No check-ins yet',
        message:
            'Daily check-ins will appear here and are used in your score, confidence, Gemma brief, and doctor summary.',
      );
    }
    final summary = IbdCheckInService.sevenDaySummary(checkIns);
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: checkIns.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Card(
            elevation: 0,
            color: cs.primaryContainer.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('7-day check-in trend', style: tt.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    [
                      '${summary['completed_days']} completed day(s)',
                      '${summary['days_with_bleeding']} day(s) with bleeding',
                      '${summary['days_with_urgency']} day(s) with urgency',
                      '${summary['days_with_fatigue']} day(s) with fatigue',
                    ].join(' · '),
                    style: tt.bodySmall?.copyWith(color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Used in score and Gemma brief. This is not a diagnosis.',
                    style: tt.labelSmall?.copyWith(color: cs.outline),
                  ),
                ],
              ),
            ),
          );
        }
        final checkIn = checkIns[index - 1];
        final evidence = IbdCheckInService.evidenceForSurvey(checkIn);
        final redFlags = (evidence['red_flags'] as List?) ?? const [];
        return Card(
          elevation: 0,
          child: ListTile(
            leading: Icon(
              redFlags.isEmpty
                  ? Icons.fact_check_outlined
                  : Icons.warning_amber_rounded,
              color: redFlags.isEmpty ? cs.primary : cs.error,
            ),
            title: Text(
              '${checkIn.diseaseType} check-in · ${checkIn.surveyDate}',
            ),
            subtitle: Text(
              [
                evidence['summary'] as String,
                'Score ${checkIn.pro2Score.toStringAsFixed(0)}',
                if (redFlags.isNotEmpty)
                  'Flagged: ${redFlags.join(', ').replaceAll('_', ' ')}',
              ].join('\n'),
            ),
          ),
        );
      },
    );
  }
}

class _LabResultsTab extends StatelessWidget {
  const _LabResultsTab({
    required this.labs,
    required this.onAddLab,
    required this.onImportLabReport,
    required this.onEditLab,
    required this.onDeleteLab,
  });

  final List<LabValueRecord> labs;
  final VoidCallback onAddLab;
  final VoidCallback onImportLabReport;
  final Future<void> Function(LabValueRecord record) onEditLab;
  final Future<void> Function(LabValueRecord record) onDeleteLab;

  @override
  Widget build(BuildContext context) {
    if (labs.isEmpty) {
      return _EmptyState(
        icon: Icons.science_outlined,
        title: 'No lab results yet',
        message:
            'Add results from a doctor visit to help ground inflammation changes.',
        buttonLabel: 'Add lab result',
        onPressed: onAddLab,
        secondaryButtonLabel: 'Scan lab report',
        onSecondaryPressed: onImportLabReport,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onImportLabReport,
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Scan or paste lab report'),
          ),
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < labs.length; index++) ...[
          Builder(
            builder: (context) {
              final record = labs[index];
              final elevated = record.valueNumeric >
                  (record.referenceHigh ?? double.infinity);
              final color = elevated
                  ? Theme.of(context).colorScheme.error
                  : Colors.green.shade700;
              return Dismissible(
                key: ValueKey(
                  'lab_${record.id}_${record.drawnDate}_${record.labType}',
                ),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  await onDeleteLab(record);
                  return false;
                },
                background: Semantics(
                  label: 'Delete lab result',
                  child: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                child: Card(
                  elevation: 0,
                  child: ListTile(
                    onTap: () => onEditLab(record),
                    title: Text(
                      '${_labDisplayName(record.labType)} · ${record.valueNumeric.toStringAsFixed(record.valueNumeric < 10 ? 1 : 0)} ${record.unit}',
                    ),
                    subtitle: Text(
                      [
                        record.drawnDate,
                        elevated ? 'Above normal' : 'In range',
                        if (record.referenceHigh != null)
                          'Ref ≤ ${record.referenceHigh!.toStringAsFixed(record.referenceHigh! < 10 ? 1 : 0)} ${record.unit}',
                        record.labName,
                      ]
                          .whereType<String>()
                          .where((item) => item.isNotEmpty)
                          .join(' · '),
                    ),
                    trailing: Icon(
                      elevated
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline_rounded,
                      color: color,
                    ),
                  ),
                ),
              );
            },
          ),
          if (index != labs.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ProcedureTab extends StatelessWidget {
  const _ProcedureTab({
    required this.procedures,
    required this.onAddProcedure,
    required this.onDeleteProcedure,
  });

  final List<EndoscopyRecord> procedures;
  final VoidCallback onAddProcedure;
  final Future<void> Function(EndoscopyRecord record) onDeleteProcedure;

  @override
  Widget build(BuildContext context) {
    if (procedures.isEmpty) {
      return _EmptyState(
        icon: Icons.medical_services_outlined,
        title: 'No procedure results yet',
        message:
            'Add colonoscopy or endoscopy results to ground clinical disease activity.',
        buttonLabel: 'Add procedure',
        onPressed: onAddProcedure,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: procedures.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final record = procedures[index];
        final severity = record.mayoEndoscopicScore != null
            ? 'Mayo ${record.mayoEndoscopicScore}'
            : record.sesCdScore != null
                ? 'SES-CD ${record.sesCdScore}'
                : record.biopsyResult == 'active_inflammation'
                    ? 'Biopsy active inflammation'
                    : 'No severity recorded';
        return Dismissible(
          key: ValueKey('procedure_${record.id}_${record.procedureDate}'),
          direction: DismissDirection.endToStart,
          confirmDismiss: (_) async {
            await onDeleteProcedure(record);
            return false;
          },
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          child: Card(
            elevation: 0,
            child: ListTile(
              title: Text(record.procedureType.replaceAll('_', ' ')),
              subtitle: Text('${record.procedureDate} · $severity'),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ),
        );
      },
    );
  }
}

class _MedicationTab extends StatelessWidget {
  const _MedicationTab({
    required this.events,
    required this.onAddMedication,
    required this.onDeleteMedication,
  });

  final List<IntakeEventRecord> events;
  final VoidCallback onAddMedication;
  final Future<void> Function(IntakeEventRecord event) onDeleteMedication;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return _EmptyState(
        icon: Icons.medication_outlined,
        title: 'No medication logs yet',
        message:
            'Track taken or skipped medication with review-before-save logging.',
        buttonLabel: 'Log medication',
        onPressed: onAddMedication,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final event = events[index];
        final metadata = event.metadataJson;
        final name = (metadata['medication_name'] as String?)?.trim();
        final dose = (metadata['dose'] as String?)?.trim();
        final schedule = (metadata['schedule'] as String?)?.trim();
        final taken = event.eventType == 'medication_taken';
        return Dismissible(
          key: ValueKey('medication_${event.id}_${event.loggedAt}'),
          direction: DismissDirection.endToStart,
          confirmDismiss: (_) async {
            await onDeleteMedication(event);
            return false;
          },
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          child: Card(
            elevation: 0,
            child: ListTile(
              leading: Icon(
                taken
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_rounded,
                color: taken ? Colors.green.shade700 : Colors.orange.shade800,
              ),
              title: Text(
                name == null || name.isEmpty
                    ? (taken ? 'Medication taken' : 'Medication skipped')
                    : name,
              ),
              subtitle: Text(
                [
                  _SymptomsTab._formatDateTime(event.loggedAt),
                  if (dose != null && dose.isNotEmpty) dose,
                  if (schedule != null && schedule.isNotEmpty) schedule,
                  if ((event.notes ?? '').trim().isNotEmpty)
                    event.notes!.trim(),
                ].join(' · '),
              ),
              trailing: Text(
                taken ? 'Taken' : 'Skipped',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrendTab extends StatelessWidget {
  const _TrendTab({required this.labs, required this.onAddLab});

  final List<LabValueRecord> labs;
  final VoidCallback onAddLab;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<LabValueRecord>>{};
    for (final lab in labs) {
      grouped.putIfAbsent(lab.labType, () => []).add(lab);
    }
    if (grouped.isEmpty) {
      return _EmptyState(
        icon: Icons.show_chart_rounded,
        title: 'No trend data yet',
        message: 'Lab trends will appear after you add at least one result.',
        buttonLabel: 'Add lab result',
        onPressed: onAddLab,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: grouped.entries.map((entry) {
        final values = entry.value.reversed.toList(growable: false);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key.toUpperCase(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 100,
                    child: Semantics(
                      label: '${entry.key} lab trend chart',
                      image: true,
                      child: CustomPaint(
                        painter: _LabTrendPainter(values: values),
                        child: Container(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${values.length} result${values.length == 1 ? '' : 's'} tracked',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _LabTrendPainter extends CustomPainter {
  const _LabTrendPainter({required this.values});

  final List<LabValueRecord> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      final paint = Paint()
        ..color = Colors.grey.shade400
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }

    final minValue =
        values.map((item) => item.valueNumeric).reduce((a, b) => a < b ? a : b);
    final maxValue =
        values.map((item) => item.valueNumeric).reduce((a, b) => a > b ? a : b);
    final spread =
        (maxValue - minValue).abs() < 0.001 ? 1.0 : (maxValue - minValue);
    final path = Path();

    for (var index = 0; index < values.length; index++) {
      final x =
          values.length == 1 ? 0.0 : (index / (values.length - 1)) * size.width;
      final normalized = (values[index].valueNumeric - minValue) / spread;
      final y = size.height - (normalized * size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = const Color(0xFF0F766E)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LabTrendPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.buttonLabel,
    this.onPressed,
    this.secondaryButtonLabel,
    this.onSecondaryPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? buttonLabel;
  final VoidCallback? onPressed;
  final String? secondaryButtonLabel;
  final VoidCallback? onSecondaryPressed;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 240;
        return SingleChildScrollView(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: compact ? 30 : 40, color: cs.primary),
                  SizedBox(height: compact ? 8 : 12),
                  Text(
                    title,
                    style: tt.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: tt.bodyMedium?.copyWith(color: cs.outline),
                    textAlign: TextAlign.center,
                  ),
                  if (buttonLabel != null && onPressed != null) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: onPressed,
                      child: Text(buttonLabel!),
                    ),
                  ],
                  if (secondaryButtonLabel != null &&
                      onSecondaryPressed != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: onSecondaryPressed,
                      child: Text(secondaryButtonLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _labDisplayName(String labType) {
  switch (labType) {
    case 'crp':
      return 'C-Reactive Protein (CRP)';
    case 'esr':
      return 'Sedimentation Rate (ESR)';
    case 'fc':
      return 'Fecal Calprotectin';
    case 'lactoferrin':
      return 'Lactoferrin';
    case 'hemoglobin':
      return 'Hemoglobin';
    case 'wbc':
      return 'White Blood Cells';
    case 'albumin':
      return 'Albumin';
    case 'vitamin_d':
      return 'Vitamin D';
    case 'ferritin':
      return 'Ferritin';
    case 'b12':
      return 'Vitamin B12';
    default:
      return labType.toUpperCase();
  }
}
