// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// History tab (§24).
///
/// M16: the shell gains the tab with a straight list of finished activities;
/// month grouping, PBs badges and filters arrive with the results milestone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activityRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: activities.isEmpty
          ? const EmptyState(
              icon: Icons.history,
              message: 'No races yet. Choose a route and start racing.',
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                for (final activity in activities) ...[
                  _ActivityRow(activity: activity),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
    );
  }
}

class _ActivityRow extends ConsumerWidget {
  const _ActivityRow({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final started = activity.startedAt.toLocal();
    final date = '${started.day}/${started.month}';
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
                    const SizedBox(height: 2),
                    Text(
                      '${activity.distance?.formatWith(units) ?? '—'} '
                      '· started $date',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}