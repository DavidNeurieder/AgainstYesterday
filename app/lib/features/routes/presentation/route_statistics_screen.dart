// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Statistics for every route (§23).
///
/// One page instead of per-route number rows: each course contributes its
/// numeric breakdown and performance chart, and tapping a card opens that
/// route's run list. Reached from the Routes tab's statistics button.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/route_stats.dart';
import 'route_stats_view.dart';

class RouteStatisticsScreen extends ConsumerWidget {
  const RouteStatisticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeRepositoryProvider);
    final activities = ref.watch(activityRepositoryProvider);
    final units = ref.watch(displayUnitProvider);

    final attemptsByRoute = <String, List<Activity>>{
      for (final route in routes) route.id: _attemptsFor(route, activities),
    };
    final totalRuns = routes.fold<int>(
      0,
      (sum, route) =>
          sum +
          computeRouteStats(
            route: route,
            attempts: attemptsByRoute[route.id]!,
          ).runs,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: routes.isEmpty
          ? const EmptyState(
              icon: Icons.insights_outlined,
              message:
                  'No routes yet. Record a route to start tracking '
                  'statistics.',
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                Text(
                  '${routes.length} '
                  '${routes.length == 1 ? 'route' : 'routes'} · '
                  '$totalRuns ${totalRuns == 1 ? 'run' : 'runs'}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                for (final route in routes) ...[
                  _RouteStatsCard(
                    route: route,
                    attempts: attemptsByRoute[route.id]!,
                    units: units,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
    );
  }

  List<Activity> _attemptsFor(Route route, List<Activity> activities) => [
    for (final a in activities)
      if (a.routeId == route.id && a.duration != null) a,
  ];
}

class _RouteStatsCard extends ConsumerWidget {
  const _RouteStatsCard({
    required this.route,
    required this.attempts,
    required this.units,
  });

  final Route route;
  final List<Activity> attempts;
  final Units units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final stats = computeRouteStats(route: route, attempts: attempts);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          AppHaptics.light(ref);
          context.push('/route/${route.id}');
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(route.name, style: textTheme.titleMedium),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    route.distance.formatWith(units),
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${stats.runs} ${stats.runs == 1 ? 'run' : 'runs'}',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              RouteStatsView(stats: stats, attempts: attempts, showChart: true),
            ],
          ),
        ),
      ),
    );
  }
}
