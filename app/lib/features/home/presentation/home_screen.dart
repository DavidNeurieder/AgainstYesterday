// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Home — the primary screen's job is to answer "What should I race today?"
/// (§4): a featured route hero that leads into a race, the recent activity
/// list, and a first-launch empty state that points at recording a route.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/ui/app_sections.dart';
import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeRepositoryProvider);
    final activities = ref.watch(activityRepositoryProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.xl,
          ),
          children: [
            const SizedBox(height: AppSpacing.md),
            const _Header(),
            const SizedBox(height: AppSpacing.xl),
            if (routes.isEmpty)
              EmptyHomeState(onRecord: () {
                HapticFeedback.mediumImpact();
                context.go('/record-route');
              })
            else ...[
              const SectionHeader(title: 'READY TO RACE'),
              const SizedBox(height: AppSpacing.sm),
              FeaturedRouteCard(
                route: routes.first,
                onRace: () {
                  HapticFeedback.mediumImpact();
                  context.go('/race/${routes.first.id}');
                },
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            const SectionHeader(title: 'Recent'),
            const SizedBox(height: AppSpacing.sm),
            if (activities.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.directions_run,
                message: 'No races yet. Choose a route and start racing.',
              )
            else ...[
              for (final activity in activities.take(_recentLimit)) ...[
                _ActivityTile(activity: activity),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Keep Home's "Recent" list to the freshest handful; History is the full view.
const int _recentLimit = 5;

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Run against yesterday', style: textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Every route is a race with your PB.',
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: () => context.push('/settings'),
          icon: const Icon(Icons.settings_outlined),
          color: AppColors.textSecondary,
        ),
      ],
    );
  }
}

/// The hero "race today" card (§4): the featured route's distance and PB with
/// a big [PrimaryButton] leading into the pre-run.
class FeaturedRouteCard extends StatelessWidget {
  const FeaturedRouteCard({
    super.key,
    required this.route,
    required this.onRace,
  });

  final Route route;
  final VoidCallback onRace;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pb = route.personalBest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              route.name,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${route.distance.format()} · '
              '${route.attemptCount} attempts',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            if (pb != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('PB', textAlign: TextAlign.center, style: textTheme.labelSmall),
              Text(
                pb.format(),
                textAlign: TextAlign.center,
                style: textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.pb,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'RACE YOUR BEST',
              height: 64,
              icon: Icons.play_arrow_rounded,
              onPressed: onRace,
            ),
            if (pb == null)
              Text(
                'Your first attempt will become your baseline.',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// First-launch Home (§5): no stale tables or zeroed stats, just the promise
/// and one obvious next step.
class EmptyHomeState extends StatelessWidget {
  const EmptyHomeState({super.key, required this.onRecord});

  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final onDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.directions_run,
            size: 64,
            color: onDark ? AppColors.ghost : AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Your first race awaits.',
            textAlign: TextAlign.center,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Record a route and start competing against yourself.',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(
            label: 'RECORD ROUTE',
            height: 64,
            icon: Icons.add_road,
            onPressed: onRecord,
          ),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final started = activity.startedAt.toLocal();
    final date = '${started.day}/${started.month}';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          HapticFeedback.lightImpact();
          context.push('/activity/${activity.id}');
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(Icons.directions_run, color: AppColors.ghost, size: 28),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activity.duration?.format() ?? '—',
                      style: textTheme.titleMedium,
                    ),
                    Text(
                      '${activity.distance?.format() ?? '—'} '
                      '· started $date',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (activity.performance case final performance?)
                Text(
                  performance,
                  style: textTheme.labelMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}