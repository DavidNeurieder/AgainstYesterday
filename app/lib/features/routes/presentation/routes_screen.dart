// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route library screen (§22, M12).
///
/// The Routes tab is a collection of course cards — name, distance, number of
/// runs, PB — each with a tiny silhouette. Tapping a card opens the route
/// detail screen (§23).
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../widgets/route_silhouette.dart';
import '../application/route_stats.dart';

class RoutesScreen extends ConsumerWidget {
  const RoutesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeRepositoryProvider);
    final activities = ref.watch(activityRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (routes.isEmpty) ...[
            const SizedBox(height: AppSpacing.xxl),
            const Icon(Icons.route, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'No routes yet. Finish a run to record one.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ),
          ],
          for (final route in routes) ...[
            _RouteCourseCard(
              route: route,
              stats: computeRouteStats(
                route: route,
                attempts: _attemptsFor(route, activities),
              ),
              onTap: () {
                HapticFeedback.lightImpact();
                context.push('/route/${route.id}');
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  List<Activity> _attemptsFor(Route route, List<Activity> activities) =>
      [for (final a in activities) if (a.routeId == route.id) a];
}

class _RouteCourseCard extends StatelessWidget {
  const _RouteCourseCard({
    required this.route,
    required this.stats,
    required this.onTap,
  });

  final Route route;
  final RouteStats stats;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 44,
                child: Center(
                  child: RouteSilhouette(geometry: route.geometry),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(route.name, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${route.distance.format()} · '
                      '${stats.runs} ${stats.runs == 1 ? 'run' : 'runs'}',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (stats.pb case final pb?)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('PB', style: textTheme.labelSmall),
                    Text(
                      pb.format(),
                      style:
                          textTheme.titleSmall?.copyWith(color: AppColors.pb),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}