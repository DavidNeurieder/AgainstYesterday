// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// History tab (§24, §25): activities grouped by calendar month with PB
/// trophies and a `+delta vs PB` trailing note, plus the light filters the
/// plan asks for — route chips and PBs-only.
///
/// The list answers "What have I done?" (plan §24): route, time, distance
/// and when it happened — taps open the activity detail.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/date_labels.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_sections.dart';
import '../../../core/ui/app_states.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/history_grouping.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  /// `null` = all routes; otherwise the selected route id (§25).
  String? _routeFilter;

  /// Show only the runs that set a new PB (§25 "PBs only").
  bool _pbOnly = false;

  @override
  Widget build(BuildContext context) {
    final activities = ref.watch(activityRepositoryProvider);
    final routes = ref.watch(routeRepositoryProvider);
    final pb = computeHistoryPb(activities, routes);

    final filtered = <Activity>[
      for (final activity in activities)
        if ((_routeFilter == null || activity.routeId == _routeFilter) &&
            (!_pbOnly || pb.pbSetters.contains(activity.id)))
          activity,
    ];
    final groups = groupByMonth(filtered);

    // Route chips only for routes that actually have history; unknown-route
    // runs stay reachable through "All".
    final routeNames = <String, String>{
      for (final route in routes) route.id: route.name,
    };
    final chipRouteIds = <String>{
      for (final activity in activities)
        if (activity.routeId case final id?)
          if (routeNames.containsKey(id)) id,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activities.isNotEmpty)
            _FilterBar(
              routeIds: chipRouteIds.toList(),
              routeNames: routeNames,
              selectedRouteId: _routeFilter,
              pbOnly: _pbOnly,
              onRouteSelected: (id) =>
                  setState(() => _routeFilter = id),
              onPbOnly: (value) => setState(() => _pbOnly = value),
            ),
          Expanded(
            child: activities.isEmpty
                ? const EmptyState(
                    icon: Icons.history,
                    message: 'No races yet. Choose a route and start racing.',
                  )
                : filtered.isEmpty
                    ? const EmptyState(
                        compact: true,
                        icon: Icons.filter_alt_off,
                        message: 'No runs match this filter.',
                      )
                    : ListView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        children: [
                          for (final group in groups) ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.md,
                                bottom: AppSpacing.sm,
                              ),
                              child: SectionHeader(title: group.label),
                            ),
                            for (final activity in group.activities) ...[
                              _ActivityRow(activity: activity, pb: pb),
                              const SizedBox(height: AppSpacing.sm),
                            ],
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal chip row: All / per-route / PBs only (§25).
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.routeIds,
    required this.routeNames,
    required this.selectedRouteId,
    required this.pbOnly,
    required this.onRouteSelected,
    required this.onPbOnly,
  });

  final List<String> routeIds;
  final Map<String, String> routeNames;
  final String? selectedRouteId;
  final bool pbOnly;
  final ValueChanged<String?> onRouteSelected;
  final ValueChanged<bool> onPbOnly;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          FilterChip(
            key: const ValueKey('filter-all'),
            label: const Text('All'),
            selected: selectedRouteId == null,
            onSelected: (_) => onRouteSelected(null),
          ),
          const SizedBox(width: AppSpacing.sm),
          for (final id in routeIds) ...[
            FilterChip(
              key: ValueKey('filter-route-$id'),
              label: Text(routeNames[id] ?? id),
              selected: selectedRouteId == id,
              onSelected: (_) => onRouteSelected(id),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          FilterChip(
            key: const ValueKey('filter-pb-only'),
            label: const Text('PBs only'),
            selected: pbOnly,
            onSelected: onPbOnly,
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends ConsumerWidget {
  const _ActivityRow({required this.activity, required this.pb});

  final Activity activity;
  final HistoryPb pb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final routes = ref.watch(routeRepositoryProvider);
    final routeName = routes
        .where((r) => r.id == activity.routeId)
        .map((r) => r.name)
        .firstOrNull;

    final duration = activity.duration;
    final bestSeconds = activity.routeId == null
        ? null
        : pb.bestSeconds[activity.routeId];
    final delta = (duration != null && bestSeconds != null)
        ? duration.seconds - bestSeconds
        : null;
    // A setter keeps its trophy; a run that exactly matches the standing
    // best (e.g. ties the seed) shows it too.
    final isPb = pb.pbSetters.contains(activity.id) || delta == 0;

    final started = activity.startedAt.toLocal();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          AppHaptics.light(ref);
          context.push('/activity/${activity.id}');
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                isPb ? Icons.emoji_events : Icons.directions_run,
                color: isPb ? AppColors.pb : AppColors.ghost,
                size: 28,
                semanticLabel: isPb ? 'Personal best' : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      routeName ?? 'New route',
                      style: textTheme.titleMedium,
                    ),
                    Text(
                      duration?.format() ?? '—',
                      style: textTheme.titleMedium?.copyWith(
                        color: AppColors.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${activity.distance?.formatWith(units) ?? '—'} '
                      '· ${dateLabelFor(started)}',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (delta != null && delta > 0)
                Text(
                  '+${Elapsed.seconds(delta).format()}',
                  style: textTheme.labelMedium?.copyWith(
                    color: AppColors.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
