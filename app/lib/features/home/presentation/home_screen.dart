// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Home — the primary screen's job is **start a run** (§43).
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
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
            const _Greeting(),
            const SizedBox(height: AppSpacing.lg),
            _StartRunButton(onPressed: () {
      HapticFeedback.mediumImpact();
      context.go('/record');
    }),
            const SizedBox(height: AppSpacing.xl),
            if (activities.isEmpty)
              const _EmptyHint(
                icon: Icons.directions_run,
                message: 'No runs yet. Your finished runs land here.',
              )
            else ...[
              for (final activity in activities) ...[
                _ActivityTile(activity: activity),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
            const SizedBox(height: AppSpacing.lg),
            const _SectionHeader(title: 'Routes'),
            const SizedBox(height: AppSpacing.sm),
            if (routes.isEmpty)
              const _EmptyHint(
                icon: Icons.route,
                message: 'No routes yet. Finish a run to record one.',
              )
            else
              for (final route in routes) ...[
                _RouteCard(
                  route: route,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    context.push('/route/${route.id}');
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Run against yesterday', style: textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          'Every route is a race with your PB.',
          style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _StartRunButton extends StatelessWidget {
  const _StartRunButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 64,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded, size: 28),
        label: Text('Start a run',
            style: Theme.of(context).textTheme.titleMedium),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.you,
          foregroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(color: AppColors.textSecondary),
    );
  }
}

/// M14: a calm inline message where a section has nothing to show yet.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 28, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route, required this.onTap});

  final Route route;
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
              Icon(Icons.route, color: AppColors.pb, size: 34),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(route.name, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${route.distance.format()} · '
                      '${route.attemptCount} attempts',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (route.personalBest case final pb?)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('PB', style: textTheme.labelSmall),
                    Text(
                      pb.format(),
                      style: textTheme.titleSmall?.copyWith(color: AppColors.pb),
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