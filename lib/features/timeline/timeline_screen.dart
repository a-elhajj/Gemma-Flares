import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/services/dashboard_snapshot_service.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late Future<List<TimelineGroup>> _future;
  final Set<String> _selectedCategories = <String>{};

  static const Map<String, String> _categoryLabels = {
    'risk': 'Risk',
    'summary': 'Summary',
    'baseline': 'Baseline',
    'symptom': 'Symptoms',
    'checkin': 'Check-ins',
    'lab': 'Labs',
    'procedure': 'Procedures',
    'medication': 'Medication',
    'clinical': 'Clinical',
    'sync': 'Sync',
  };

  @override
  void initState() {
    super.initState();
    _future = AppServices.dashboardSnapshotService.loadTimelineGroups();
  }

  Future<void> _refresh() async {
    final next = AppServices.dashboardSnapshotService.loadTimelineGroups();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<TimelineGroup>>(
        future: _future,
        builder: (context, snap) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _body(context, snap),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, AsyncSnapshot<List<TimelineGroup>> snap) {
    final groups = snap.data ?? const <TimelineGroup>[];
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final filteredGroups = _applyCategoryFilter(groups);
    final availableCategories = groups
        .expand((group) => group.items.map((item) => item.category))
        .toSet()
      ..removeWhere((category) => category.trim().isEmpty);

    if (snap.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }

    if (snap.hasError || groups.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 64),
          Icon(Icons.timeline_rounded, size: 56, color: cs.outline),
          const SizedBox(height: 16),
          Text(
            groups.isEmpty ? 'No events yet' : 'Timeline unavailable',
            textAlign: TextAlign.center,
            style: tt.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Run a Health sync from Settings > App settings to populate your timeline with summaries, scores, and symptom notes.',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.outline),
          ),
        ],
      );
    }

    if (_selectedCategories.isNotEmpty && filteredGroups.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('Timeline', style: tt.headlineMedium),
          ),
          _FilterRow(
            selectedCategories: _selectedCategories,
            availableCategories: availableCategories,
            labels: _categoryLabels,
            onToggle: _toggleCategory,
            onClear: _selectedCategories.isEmpty ? null : _clearCategories,
          ),
          const SizedBox(height: 36),
          Icon(Icons.filter_alt_off, size: 54, color: cs.outline),
          const SizedBox(height: 12),
          Text(
            'No events match these filters',
            textAlign: TextAlign.center,
            style: tt.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Clear one or more filters to see all timeline events.',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.outline),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: filteredGroups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Timeline', style: tt.headlineMedium),
              ),
              _FilterRow(
                selectedCategories: _selectedCategories,
                availableCategories: availableCategories,
                labels: _categoryLabels,
                onToggle: _toggleCategory,
                onClear: _selectedCategories.isEmpty ? null : _clearCategories,
              ),
              const SizedBox(height: 10),
            ],
          );
        }
        final group = filteredGroups[index - 1];
        return _DayGroup(group: group);
      },
    );
  }

  void _toggleCategory(String category) {
    setState(() {
      if (_selectedCategories.contains(category)) {
        _selectedCategories.remove(category);
      } else {
        _selectedCategories.add(category);
      }
    });
  }

  void _clearCategories() {
    setState(() => _selectedCategories.clear());
  }

  List<TimelineGroup> _applyCategoryFilter(List<TimelineGroup> groups) {
    if (_selectedCategories.isEmpty) {
      return groups;
    }
    final filtered = <TimelineGroup>[];
    for (final group in groups) {
      final items = group.items
          .where((item) => _selectedCategories.contains(item.category))
          .toList(growable: false);
      if (items.isNotEmpty) {
        filtered.add(TimelineGroup(dateLocal: group.dateLocal, items: items));
      }
    }
    return filtered;
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selectedCategories,
    required this.availableCategories,
    required this.labels,
    required this.onToggle,
    required this.onClear,
  });

  final Set<String> selectedCategories;
  final Set<String> availableCategories;
  final Map<String, String> labels;
  final ValueChanged<String> onToggle;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final sortedCategories = availableCategories.toList(growable: false)
      ..sort(
        (left, right) => (labels[left] ?? left).toLowerCase().compareTo(
              (labels[right] ?? right).toLowerCase(),
            ),
      );

    if (sortedCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final category in sortedCategories)
          FilterChip(
            label: Text(labels[category] ?? category),
            selected: selectedCategories.contains(category),
            onSelected: (_) => onToggle(category),
          ),
        if (onClear != null)
          ActionChip(label: const Text('Reset'), onPressed: onClear),
      ],
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.group});

  final TimelineGroup group;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              group.dateLocal,
              style: tt.titleMedium?.copyWith(color: cs.outline),
            ),
          ),
          ...group.items.map((item) => _EventTile(item: item)),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.item});

  final TimelineItem item;

  static const _toneColors = {
    'critical': Color(0xFFDC2626),
    'high': Color(0xFFEA580C),
    'moderate': Color(0xFFCA8A04),
    'low': Color(0xFF16A34A),
    'baseline': Color(0xFF2563EB),
    'symptom': Color(0xFF7C3AED),
    'sync_degraded': Color(0xFF9A3412),
    'sync_ok': Color(0xFF16A34A),
    'summary': Color(0xFF0F766E),
  };

  static const _toneLabels = {
    'critical': 'critical',
    'high': 'high',
    'moderate': 'watch',
    'low': 'low',
    'baseline': 'baseline',
    'symptom': 'symptom',
    'sync_degraded': 'sync',
    'sync_ok': 'synced',
    'summary': 'data',
  };

  @override
  Widget build(BuildContext context) {
    final color = _toneColors[item.tone] ?? const Color(0xFF0F766E);
    final label = _toneLabels[item.tone] ?? 'local';
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(item.title, style: tt.titleMedium),
                        ),
                        _TonePill(label: label, color: color),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(item.detail, style: tt.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TonePill extends StatelessWidget {
  const _TonePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
