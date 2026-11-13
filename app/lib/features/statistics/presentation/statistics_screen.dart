// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App-wide statistics (M34): aggregates across routes and runs.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../routes/application/route_stats.dart';
import '../../settings/application/settings_controller.dart';

class StatisticsScreen extends ConsumerWidget {
  const StatisticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeRepositoryProvider);
    final activities = ref.watch(activityRepositoryProvider);
    final units = ref.watch(displayUnitProvider);
    final textTheme = Theme.of(context).textTheme;

    double totalDistanceM = 0;
    int totalSeconds = 0;
    int timedRuns = 0;
    int pbCount = 0;
    for (final a in activities) {
      if (a.distance != null) totalDistanceM += a.distance!.meters;
      if (a.duration != null) {
        totalSeconds += a.duration!.seconds.round();
        timedRuns++;
      }
    }
    for (final r in routes) {
      final attempts = [
        for (final a in activities) if (a.routeId == r.id && a.duration != null) a,
      ];
      final stats = computeRouteStats(route: r, attempts: attempts);
      if (stats.pb != null) pbCount++;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (routes.isEmpty)
            const EmptyStatePlaceholder()
          else ...[
            _SummaryGrid(
              totalDistance: Distance.meters(totalDistanceM),
              totalSeconds: totalSeconds,
              runs: timedRuns,
              pbCount: pbCount,
              units: units,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Routes', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final r in routes) ...[
              _RouteStatCard(route: r, activities: activities, units: units),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class EmptyStatePlaceholder extends StatelessWidget {
  const EmptyStatePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text('No routes yet. Record a run to see statistics.'),
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.totalDistance,
    required this.totalSeconds,
    required this.runs,
    required this.pbCount,
    required this.units,
  });

  final Distance totalDistance;
  final int totalSeconds;
  final int runs;
  final int pbCount;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    Widget card(String label, String value) => Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(value, style: textTheme.titleLarge),
              ],
            ),
          ),
        );
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        SizedBox(width: 160, child: card('Total distance', totalDistance.formatWith(units))),
        SizedBox(width: 160, child: card('Total time', Elapsed.seconds(totalSeconds.toDouble()).formatClock())),
        SizedBox(width: 160, child: card('Timed runs', '$runs')),
        SizedBox(width: 160, child: card('Personal bests', '$pbCount')),
      ],
    );
  }
}

class _RouteStatCard extends StatelessWidget {
  const _RouteStatCard({
    required this.route,
    required this.activities,
    required this.units,
  });

  final Route route;
  final List<Activity> activities;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final attempts = [
      for (final a in activities) if (a.routeId == route.id && a.duration != null) a,
    ];
    final stats = computeRouteStats(route: route, attempts: attempts);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(route.name, style: textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              '${route.distance.formatWith(units)} · ${stats.runs} runs',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _kv(context, 'PB', stats.pb?.format() ?? '—')),
                Expanded(child: _kv(context, 'Average', stats.average?.format() ?? '—')),
                Expanded(child: _kv(context, 'Last', stats.last?.format() ?? '—')),
              ],
            ),
            if (stats.verdict != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Trend: ${stats.verdict}',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
        Text(v, style: textTheme.titleSmall),
      ],
    );
  }
}