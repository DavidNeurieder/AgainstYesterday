// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Finish experience (§19, M11).
///
/// Brief summary: RUN COMPLETE, distance, clock, PB gap, and VIEW RESULT.
/// When a PB happens the heading becomes NEW PERSONAL BEST (§21).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/ui/app_motion.dart';
import '../../../core/ui/gap_line.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';

final _kScaleIn = Tween<double>(begin: 0.9, end: 1.0);

class RunCompleteScreen extends ConsumerWidget {
  const RunCompleteScreen({super.key, required this.state});

  final LiveRunState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    final routeName = state.route?.name ?? 'New route';
    final gap = state.ghostGap;
    final isNewPb =
        gap != null && gap.ahead && gap.timeDifference.seconds < 0;
    // §20: the celebration frames the gain against the standing best.
    final gainSeconds = gap?.timeDifference.seconds.abs() ?? 0.0;
    final previousPb = state.route?.personalBest;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              // M14: the headline settles into place with a springy scale-in.
              TweenAnimationBuilder<double>(
                tween: _kScaleIn,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutBack,
                child: Text(
                  isNewPb ? 'NEW PERSONAL BEST' : 'RUN COMPLETE',
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isNewPb ? AppColors.ahead : null,
                  ),
                ),
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                routeName,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              // M23 §20: the PB moment — trophy pops, then the gain and the
              // previous best arrive in sequence.
              if (isNewPb) ...[
                const SizedBox(height: AppSpacing.md),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutBack,
                  builder: (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: const Icon(
                    Icons.emoji_events,
                    size: 56,
                    color: AppColors.pb,
                    semanticLabel: 'Personal best',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                StaggeredIn(
                  delay: const Duration(milliseconds: 350),
                  child: Text(
                    '${Elapsed.seconds(gainSeconds).format()} FASTER',
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(
                      color: AppColors.pb,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (previousPb != null) ...[
                  const SizedBox(height: 2),
                  StaggeredIn(
                    delay: const Duration(milliseconds: 500),
                    child: Text(
                      'Previous PB ${previousPb.format()}',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: AppSpacing.xl),
              Text(
                state.distance.formatWith(units),
                textAlign: TextAlign.center,
                style: textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                state.elapsed.formatClock(),
                textAlign: TextAlign.center,
                style: textTheme.headlineMedium?.copyWith(
                  color: AppColors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              GapLine(gap: gap),
              const Spacer(),
              PrimaryButton(
                label: 'VIEW RESULT',
                onPressed: () {
                  AppHaptics.selection(ref);
                  context.push('/record/result');
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () {
                  AppHaptics.light(ref);
                  controller.dismissRun();
                  context.go('/');
                },
                child: const Text('DONE'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}