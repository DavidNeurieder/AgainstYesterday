// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pre-run experience (§10).
///
/// Primary job: get the runner READY TO RUN. Recording only starts on the
/// explicit [START] press; route selection stays optional (§11). When the flow
/// wants a countdown before the timer starts (M19 races), it injects an
/// [onStart] hook that plays 3-2-1-GO instead of calling `beginRun()` directly.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';

class PreRunScreen extends ConsumerWidget {
  const PreRunScreen({
    super.key,
    required this.state,
    this.title = 'New run',
    this.onStart,
  });

  /// May be null only while the session is booting.
  final LiveRunState? state;

  /// AppBar title — the route name for a race against a specific route.
  final String title;

  /// When set, the START press plays the countdown instead of recording the
  /// moment it is tapped (the flow drives `beginRun()` at GO).
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = state?.status ?? RunStatus.preparing;
    final route = state?.route;
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(recordingControllerProvider.notifier);
    final ready = status == RunStatus.ready;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(),
                        Text(
                          ready ? 'READY TO RUN' : 'GETTING GPS…',
                          textAlign: TextAlign.center,
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color:
                                ready ? AppColors.you : AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _GpsChip(ready: ready),
                        const SizedBox(height: AppSpacing.xl),
                        if (route != null)
                          _DetectedRoute(route: route)
                        else
                          const _NewRouteHint(),
                        const Spacer(),
                        FilledButton(
                          onPressed: ready
                              ? () {
                                  // M14: a tactile "go" on START.
                                  AppHaptics.medium(ref);
                                  if (onStart case final start?) {
                                    start();
                                  } else {
                                    controller.beginRun();
                                  }
                                }
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.you,
                            foregroundColor: AppColors.background,
                            minimumSize: const Size.fromHeight(56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: Text('START',
                              style: textTheme.titleMedium),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (route != null)
                          TextButton(
                            onPressed: controller.continueWithoutRoute,
                            child: const Text('Continue without route'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GpsChip extends StatelessWidget {
  const _GpsChip({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final color = ready ? AppColors.ahead : AppColors.gpsWarning;
    return Center(
      child: Chip(
        avatar: Icon(
          // M14 loading cue: an hourglass reads as "in progress" without a
          // perpetual spinner (which would keep the test clock animating).
          ready ? Icons.gps_fixed : Icons.hourglass_top,
          size: 18,
          color: color,
        ),
        label: Text(
          ready ? 'GPS READY' : 'ACQUIRING GPS',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
    );
  }
}

class _DetectedRoute extends ConsumerWidget {
  const _DetectedRoute({required this.route});

  final Route route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: AppColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.route, color: AppColors.pb, size: 28),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(route.name, style: textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              route.distance.formatWith(units),
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('RACE AGAINST', style: textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(
              'Personal Best · ${route.personalBest?.format() ?? '—'}',
              style: textTheme.titleMedium?.copyWith(color: AppColors.you),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewRouteHint extends StatelessWidget {
  const _NewRouteHint();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(Icons.explore_outlined,
                color: AppColors.textSecondary, size: 40),
            const SizedBox(height: AppSpacing.md),
            Text('New route', style: textTheme.titleLarge),
            const SizedBox(height: 2),
            Text('You pick the route — or start fresh.',
                style: textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}