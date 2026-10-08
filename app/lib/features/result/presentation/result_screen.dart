// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Detailed result screen (§20, M11).
///
/// Shows performance bar, per-km splits, and ranking after a completed run.
/// Pushed from [RunCompleteScreen] via `/record/result`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/ui/app_motion.dart';
import '../../../core/ui/gap_line.dart';
import '../../../core/ui/split_row.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../recording/application/recording_controller.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/splits.dart';

/// Base stagger step between the result stats' entrance (§30).
const int _kStep = 70;

class ResultScreen extends ConsumerWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final live = ref.read(recordingControllerProvider);
    if (live == null) {
      return const _EmptyResult();
    }

    final route = live.route;
    final routeName = route?.name ?? 'New route';
    final gap = live.ghostGap;
    final trackMeters = live.distance.meters;

    // The most recently saved activity is the one we just completed.
    final activities = ref.watch(activityRepositoryProvider);
    final activity = activities.isNotEmpty ? activities.first : null;

    // Splits for runs on a known route with PB and track data.
    final splits = (activity != null && route != null)
        ? computeSplits(
            activity: activity,
            route: route,
            trackMeters: trackMeters,
          )
        : [];

    // Ranking: how many saved runs on this route are faster.
    final rank = _rank(route?.id, live.elapsed, activities);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.lg,
          ),
          children: [
          StaggeredIn(
            child: Text(
              routeName,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          StaggeredIn(
            delay: Duration(milliseconds: _kStep),
            child: Text(
              live.elapsed.formatClock(),
              textAlign: TextAlign.center,
              style: textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          StaggeredIn(
            delay: Duration(milliseconds: _kStep),
            child: Text(
              live.distance.formatWith(units),
              textAlign: TextAlign.center,
              style: textTheme.headlineSmall?.copyWith(
                color: AppColors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          StaggeredIn(
            delay: const Duration(milliseconds: 150),
            child: GapLine(gap: gap),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (route != null && gap != null)
            StaggeredIn(
              delay: const Duration(milliseconds: 230),
              child: _PerformanceBar(
                pbTime: route.personalBest,
                youTime: live.elapsed,
                totalDistance: route.distance,
                yourDistance: live.distance,
                units: units,
              ),
            ),
          if (splits.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            StaggeredIn(
              delay: const Duration(milliseconds: 310),
              child: Text(
                'Splits',
                style: textTheme.titleMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final entry in splits.asMap().entries)
              StaggeredIn(
                delay: Duration(milliseconds: 340 + 30 * entry.key),
                child: SplitRow(split: entry.value),
              ),
          ],
          if (rank != null) ...[
            const SizedBox(height: AppSpacing.xl),
            StaggeredIn(
              delay: const Duration(milliseconds: 460),
              child: Text(
                rank,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          // M20 §29: after a route race, RACE AGAIN drops back into that
          // route's pre-race (fresh session + the 3-2-1-GO countdown); DONE
          // leaves the loop.
          if (route != null) ...[
            StaggeredIn(
              delay: const Duration(milliseconds: 540),
              child: PrimaryButton(
                label: 'RACE AGAIN',
                icon: Icons.replay,
                onPressed: () {
                  AppHaptics.medium(ref);
                  ref.read(recordingControllerProvider.notifier).dismissRun();
                  context.go('/race/${route.id}');
                },
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            StaggeredIn(
              delay: const Duration(milliseconds: 540),
              child: TextButton(
                onPressed: () {
                  AppHaptics.light(ref);
                  ref.read(recordingControllerProvider.notifier).dismissRun();
                  context.go('/');
                },
                child: const Text('DONE'),
              ),
            ),
          ] else
            StaggeredIn(
              delay: const Duration(milliseconds: 540),
              child: PrimaryButton(
                label: 'DONE',
                onPressed: () {
                  ref.read(recordingControllerProvider.notifier).dismissRun();
                  context.go('/');
                },
              ),
            ),
        ],
        ),
      ),
    );
  }
}

String? _rank(String? routeId, Elapsed elapsed, List<Activity> history) {
  if (routeId == null) {
    return null;
  }
  final onRoute = history
      .where((a) => a.routeId == routeId && a.duration != null)
      .toList()
    ..sort((a, b) => a.duration!.seconds.compareTo(b.duration!.seconds));
  final index = onRoute.indexWhere(
    (a) => a.id == history.first.id,
  );
  if (index < 0) {
    return null;
  }
  final n = index + 1;
  final suffix = n == 1
      ? 'st'
      : n == 2
          ? 'nd'
          : n == 3
              ? 'rd'
              : 'th';
  return 'Your $n$suffix fastest run on this route';
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => context.go('/'),
          child: const Text('Back to Home'),
        ),
      ),
    );
  }
}

class _PerformanceBar extends StatelessWidget {
  const _PerformanceBar({
    required this.pbTime,
    required this.youTime,
    required this.totalDistance,
    required this.yourDistance,
    required this.units,
  });

  final Elapsed? pbTime;
  final Elapsed youTime;
  final Distance totalDistance;
  final Distance yourDistance;
  final Units units;

  @override
  Widget build(BuildContext context) {
    if (pbTime == null || pbTime!.seconds <= 0) {
      return const SizedBox.shrink();
    }

    final pbFrac = 1.0; // PB completed the route.
    final youFrac =
        (yourDistance.meters / totalDistance.meters).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'PERFORMANCE',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          totalDistance.formatWith(units),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 48,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  // Track
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 16,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textMuted.withAlpha(50),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // PB dot
                  Positioned(
                    left: (w - 8) * pbFrac,
                    bottom: 10,
                    child: Column(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.pb,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'PB',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AppColors.pb,
                              ),
                        ),
                      ],
                    ),
                  ),
                  // YOU dot
                  Positioned(
                    left: (w - 8) * youFrac,
                    bottom: 10,
                    child: Column(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.you,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'YOU',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AppColors.you,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}