import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/doctor_summary_pdf_service.dart';
import '../../core/services/gemma_task_service.dart';
import '../../core/widgets/model_use_badge.dart';

class DoctorSummaryScreen extends StatefulWidget {
  const DoctorSummaryScreen({super.key});

  @override
  State<DoctorSummaryScreen> createState() => _DoctorSummaryScreenState();
}

class _DoctorSummaryScreenState extends State<DoctorSummaryScreen> {
  DoctorSummaryResult? _latestResult;
  List<DoctorSummaryRecord> _saved = const [];
  String? _status;
  int _days = 30;
  bool _loading = true;
  bool _generating = false;
  bool _exportingPdf = false;
  String? _latestPdfPath;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await AppServices.wearableSampleRepository.getDoctorSummaries(
      limit: 5,
    );
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loading = false;
    });
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _status = 'Gemma 4 is preparing a grounded visit summary...';
    });
    try {
      final result = await AppServices.gemmaTaskService.createDoctorSummary(
        days: _days,
      );
      final saved = await AppServices.wearableSampleRepository
          .getDoctorSummaries(limit: 5);
      if (!mounted) return;
      setState(() {
        _latestResult = result;
        _saved = saved;
        _status = result.usedModelOutput
            ? 'Generated with Gemma 4 from local evidence.'
            : 'Generated with deterministic fallback from local evidence.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status =
            'Could not prepare the summary right now. Your records stay saved locally.';
      });
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('GI summary copied.')));
  }

  Future<void> _createPdfForLatest() async {
    final latest = _latestResult;
    if (latest == null) {
      return;
    }

    setState(() {
      _exportingPdf = true;
      _status = 'Rendering PDF from local summary...';
    });

    try {
      final summaryContext = latest.contextSummaryJson;
      final dataGaps =
          ((summaryContext['data_limits'] as Map?)?['known_gaps'] as List?) ??
              const [];
      final file = await AppServices.doctorSummaryPdfService.writePdfToTemp(
        input: DoctorSummaryPdfRenderInput(
          summaryText: latest.summaryText,
          groundedContext: {
            'symptom_count': (summaryContext['symptoms'] as List?)?.length ?? 0,
            'lab_count': (summaryContext['labs'] as List?)?.length ?? 0,
            'source_count':
                (summaryContext['source_evidence'] as List?)?.length ?? 0,
            'data_gaps': dataGaps,
          },
          generatedAt: DateTime.now().toUtc(),
          timeRangeLabel:
              '${summaryContext['range_start'] ?? 'n/a'} to ${summaryContext['range_end'] ?? 'n/a'}',
        ),
      );
      if (!mounted) return;
      setState(() {
        _latestPdfPath = file.path;
        _status = 'PDF is ready to share.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Doctor summary PDF created.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = 'Could not create PDF right now. Try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _exportingPdf = false);
      }
    }
  }

  Future<void> _sharePdf() async {
    final path = _latestPdfPath;
    if (path == null || path.trim().isEmpty) {
      return;
    }
    await Share.shareXFiles([
      XFile(path),
    ], subject: 'Gemma Flares GI Summary PDF');
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final latest = _latestResult;

    return Scaffold(
      appBar: AppBar(title: const Text('GI Visit Summary')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator.adaptive())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  Text('Doctor-Ready Summary', style: tt.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    'Gemma 4 turns local symptoms, labs, risk trend, and data limits into plain notes for a visit.',
                    style: tt.bodyMedium?.copyWith(color: cs.outline),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('7 days'),
                        selected: _days == 7,
                        onSelected: _generating
                            ? null
                            : (_) => setState(() => _days = 7),
                      ),
                      ChoiceChip(
                        label: const Text('30 days'),
                        selected: _days == 30,
                        onSelected: _generating
                            ? null
                            : (_) => setState(() => _days = 30),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _generating ? null : _generate,
                    icon: _generating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined),
                    label: Text(
                      _generating ? 'Preparing...' : 'Prepare GI summary',
                    ),
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _status!,
                      style: tt.bodySmall?.copyWith(color: cs.outline),
                    ),
                  ],
                  if (latest != null) ...[
                    const SizedBox(height: 20),
                    _SummaryPanel(
                      title: 'Latest summary',
                      summaryText: latest.summaryText,
                      subtitle:
                          '${latest.contextSummaryJson['range_start']} to ${latest.contextSummaryJson['range_end']}',
                      usedModelOutput: latest.usedModelOutput,
                      onCopy: () => _copy(latest.summaryText),
                      onCreatePdf: _createPdfForLatest,
                      onSharePdf: _latestPdfPath == null ? null : _sharePdf,
                      exportingPdf: _exportingPdf,
                    ),
                    const SizedBox(height: 12),
                    _EvidencePanel(contextJson: latest.contextSummaryJson),
                  ],
                  if (_saved.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text('Saved summaries', style: tt.titleMedium),
                    const SizedBox(height: 8),
                    for (final item in _saved)
                      _SavedSummaryTile(
                        record: item,
                        onCopy: () => _copy(item.summaryText),
                      ),
                  ],
                  const SizedBox(height: 18),
                  Text(
                    'This summary is not a diagnosis and does not recommend medication changes.',
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.outline),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.title,
    required this.summaryText,
    required this.subtitle,
    required this.usedModelOutput,
    required this.onCopy,
    required this.onCreatePdf,
    required this.onSharePdf,
    required this.exportingPdf,
  });

  final String title;
  final String summaryText;
  final String subtitle;
  final bool usedModelOutput;
  final VoidCallback onCopy;
  final VoidCallback onCreatePdf;
  final VoidCallback? onSharePdf;
  final bool exportingPdf;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: tt.titleMedium)),
                ModelUseBadge(usedModelOutput: usedModelOutput),
              ],
            ),
            Text(subtitle, style: tt.bodySmall?.copyWith(color: cs.outline)),
            const Divider(height: 20),
            MarkdownBody(
              data: summaryText,
              selectable: true,
              styleSheet:
                  MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                h2: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                h3: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy for doctor'),
                ),
                FilledButton.icon(
                  onPressed: exportingPdf ? null : onCreatePdf,
                  icon: exportingPdf
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(exportingPdf ? 'Rendering PDF...' : 'Create PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: onSharePdf,
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('Share PDF'),
                ),
              ],
            ),
            EvidenceReceipt(
              usedModelOutput: usedModelOutput,
              evidenceHash: null,
              generatedAt: null,
              status: usedModelOutput ? 'model' : 'fallback',
            ),
          ],
        ),
      ),
    );
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({required this.contextJson});

  final Map<String, Object?> contextJson;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final symptoms = (contextJson['symptoms'] as List?)?.length ?? 0;
    final labs = (contextJson['labs'] as List?)?.length ?? 0;
    final scores = (contextJson['score_trend'] as List?)?.length ?? 0;
    final limits =
        contextJson['data_limits'] as Map<String, Object?>? ?? const {};

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Local evidence used', style: tt.titleSmall),
          const SizedBox(height: 8),
          _EvidenceRow(label: 'Symptoms', value: '$symptoms'),
          _EvidenceRow(label: 'Labs', value: '$labs'),
          _EvidenceRow(label: 'Risk scores', value: '$scores'),
          _EvidenceRow(
            label: 'Missing days',
            value: '${limits['missing_days'] ?? 0}',
          ),
        ],
      ),
    );
  }
}

class _SavedSummaryTile extends StatelessWidget {
  const _SavedSummaryTile({required this.record, required this.onCopy});

  final DoctorSummaryRecord record;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text('${record.summaryRangeDays}-day summary'),
        subtitle: Text(record.createdAt.toLocal().toString()),
        trailing: IconButton(
          onPressed: onCopy,
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'Copy summary',
        ),
      ),
    );
  }
}

class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: tt.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
          Expanded(child: Text(value, style: tt.bodyMedium)),
        ],
      ),
    );
  }
}
