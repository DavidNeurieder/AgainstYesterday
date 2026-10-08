// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Activity detail screen (§24, M11).
///
/// Reached by tapping an activity in Home's recent list. Shows the same
/// layout as [ResultScreen] but reads persisted data from the repositories.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/split_row.dart';
import '../../../persistence/persistence.dart';
import '../../result/application/splits.dart';
import '../../settings/application/settings_controller.dart';

class ActivityDetailScreen extends ConsumerWidget {
  const ActivityDetailScreen({super.key, required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activityRepositoryProvider);
    final matches = activities.where((a) => a.id == activityId);
    if (matches.isEmpty) {
      return _NotFoundScreen(activityId: activityId);
    }
    final activity = matches.first;

    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final routeId = activity.routeId;
    final routes = ref.watch(routeRepositoryProvider);
    final route = routeId != null
        ? routes.where((r) => r.id == routeId).firstOrNull
        : null;
    final routeName = route?.name ?? 'New route';

    final distance = activity.distance;
    final duration = activity.duration;
    final trackMeters = distance?.meters ?? 0;

    final splits = (route != null && trackMeters > 0)
        ? computeSplits(
            activity: activity,
            route: route,
            trackMeters: trackMeters,
          )
        : [];

    return Scaffold(
      appBar: AppBar(
        title: Text(routeName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        children: [
          Text(
            routeName,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            duration?.formatClock() ?? '—',
            textAlign: TextAlign.center,
            style: textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            distance?.formatWith(units) ?? '—',
            textAlign: TextAlign.center,
            style: textTheme.headlineSmall?.copyWith(
              color: AppColors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (activity.performance case final perf?)
            Text(
              perf,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          if (splits.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Splits',
              style: textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final split in splits)
              SplitRow(split: split),
          ],
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Run on ${_formatDate(activity.startedAt)}',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day}/${d.month}/${d.year}';
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'Activity not found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              activityId,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Back to Home'),
            ),
          ],
        ),
      ),
    );
  }
}