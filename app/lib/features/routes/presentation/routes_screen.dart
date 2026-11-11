// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route library screen (§22, M12).
///
/// The Routes tab is a collection of course cards — name, distance, number of
/// runs, PB — each with a tiny silhouette. Tapping a card opens the route
/// detail screen (§23). While the library is still empty the screen opens with
/// a welcome card instead of a bare empty state: it explains what a route, a
/// ghost and the live gap are before the first run exists.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../widgets/route_silhouette.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
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
          // Record-a-route entry (§6): a brand-new course can be captured
          // whenever, catalog or not.
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: FilledButton.icon(
              onPressed: () {
                AppHaptics.selection(ref);
                // Pushed, not replaced: the record-a-route flow is a
                // full-screen route over the shell, so its AppBar back button
                // (and the system back gesture) returns to the tab instead of
                // exiting the app.
                context.push('/record-route');
              },
              icon: const Icon(Icons.add_road),
              label: const Text('RECORD ROUTE'),
              style: FilledButton.styleFrom(
                foregroundColor: AppColors.background,
                backgroundColor: AppColors.you,
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          if (routes.isEmpty)
            const _WelcomeCard(),
          for (final route in routes) ...[
            _RouteCourseCard(
              route: route,
              stats: computeRouteStats(
                route: route,
                attempts: _attemptsFor(route, activities),
              ),
              onTap: () {
                AppHaptics.light(ref);
                context.push('/route/${route.id}');
              },
              onRace: () {
                AppHaptics.medium(ref);
                // Pushed over the shell so back returns to the courses tab.
                context.push('/race/${route.id}');
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

/// The first-run read of the library: what a route is, what the ghost is and
/// what the live gap means — shown only while no route has been recorded yet,
/// so a fresh install is never just an empty list under a button.
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard();

  static const List<(IconData, String)> _lines = [
    (Icons.route, 'Record a route once — the run saves the course.'),
    (Icons.timer_outlined, 'Your fastest run on it becomes the ghost you race.'),
    (Icons.compare_arrows, 'The live gap shows ahead in green, behind in amber.'),
  ];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('routes-welcome'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Welcome to Against Yesterday', style: textTheme.titleMedium),
            for (final (icon, line) in _lines)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: AppColors.textSecondary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        line,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No routes yet. Record your first route.',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteCourseCard extends ConsumerWidget {
  const _RouteCourseCard({
    required this.route,
    required this.stats,
    required this.onTap,
    required this.onRace,
  });

  final Route route;
  final RouteStats stats;
  final VoidCallback onTap;
  final VoidCallback onRace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
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
                          '${route.distance.formatWith(units)} · '
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
                          style: textTheme.titleSmall
                              ?.copyWith(color: AppColors.pb),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              // M19: every course card races straight into its own pre-race.
              FilledButton.icon(
                onPressed: onRace,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('RACE'),
                style: FilledButton.styleFrom(
                  foregroundColor: AppColors.background,
                  backgroundColor: AppColors.you,
                  minimumSize: const Size.fromHeight(40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
