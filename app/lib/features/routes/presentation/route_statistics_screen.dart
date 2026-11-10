// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Statistics for one route (§23).
///
/// The numeric breakdown and performance chart for the route you are looking
/// at — never another course. Reached from that route's detail app bar so the
/// run list stays front and centre.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../widgets/route_silhouette.dart';
import '../../settings/application/settings_controller.dart';
import '../application/route_stats.dart';
import 'route_stats_view.dart';

class RouteStatisticsScreen extends ConsumerWidget {
  const RouteStatisticsScreen({super.key, required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref
        .watch(routeRepositoryProvider)
        .where((r) => r.id == routeId)
        .firstOrNull;
    if (route == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Statistics')),
        body: const EmptyState(
          icon: Icons.route,
          message: 'Route not found.',
        ),
      );
    }

    final attempts = <Activity>[
      for (final a in ref.watch(activityRepositoryProvider))
        if (a.routeId == route.id && a.duration != null) a,
    ];
    final stats = computeRouteStats(route: route, attempts: attempts);
    final units = ref.watch(displayUnitProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              SizedBox(
                width: 56,
                height: 44,
                child: Center(child: RouteSilhouette(geometry: route.geometry)),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(route.name, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${route.distance.formatWith(units)} · '
                      '${stats.runs} ${stats.runs == 1 ? 'run' : 'runs'}',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          RouteStatsView(
            stats: stats,
            attempts: attempts,
            showChart: true,
          ),
          if (attempts.isEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'No timed runs on this route yet, so there is nothing to '
              'compare.',
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
