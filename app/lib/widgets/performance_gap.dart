// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The most important component: the YOU vs GHOST gap (§45).
///
/// This widget is the visual identity of the app. It takes the live gap and
/// renders one of four states — ahead, behind, tied, unknown — using the
/// semantic colors from the design system (M2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../core/units.dart';
import '../engine/models.dart';
import '../features/settings/application/settings_controller.dart';

/// Stable, human-facing label for each state.
const Map<AheadBehind, String> _states = <AheadBehind, String>{
  AheadBehind.ahead: 'AHEAD',
  AheadBehind.behind: 'BEHIND',
  AheadBehind.tied: 'TIED',
  AheadBehind.unknown: '—',
};

class PerformanceGap extends ConsumerWidget {
  const PerformanceGap({
    super.key,
    required this.difference,
    required this.distance,
    required this.state,
  });

  /// Signed difference (`current - reference`); positive is behind.
  final Elapsed difference;

  /// Distance at which the gap is measured.
  final Distance distance;

  final AheadBehind state;

  Color get _color => switch (state) {
        AheadBehind.ahead => AppColors.ahead,
        AheadBehind.behind => AppColors.behind,
        AheadBehind.tied => AppColors.you,
        AheadBehind.unknown => AppColors.textMuted,
      };

  /// Signed label, e.g. `0:12` (ahead) or `+0:12` (behind).
  String get _label => switch (state) {
        AheadBehind.ahead || AheadBehind.tied => difference.format(),
        AheadBehind.behind => '+${difference.format()}',
        AheadBehind.unknown => '—',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final label = switch (state) {
      AheadBehind.ahead =>
        'Ahead of PB by ${difference.format()} at ${distance.formatWith(units)}',
      AheadBehind.behind =>
        'Behind PB by ${difference.format()} at ${distance.formatWith(units)}',
      AheadBehind.tied => 'Tied with PB at ${distance.formatWith(units)}',
      AheadBehind.unknown => 'Gap to PB not available',
    };
    // A curated spoken description replaces the raw digits so screen readers
    // don't double-read the visual text.
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // M14: color flips (ahead/behind) crossfade instead of snapping.
            // Value-equality keeps it still when only the text changes.
            TweenAnimationBuilder<Color?>(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              tween: ColorTween(end: _color),
              builder: (context, color, _) => Text(
                _label,
                style: textTheme.displayMedium?.copyWith(
                  color: color ?? _color,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_states[state]} · at ${distance.formatWith(units)}',
              style: textTheme.labelMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const _ProgressTrack(color: AppColors.ahead),
          ],
        ),
      ),
    );
  }
}

/// Decorative YOU vs GHOST progress track.
class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: SizedBox(
        width: double.infinity,
        height: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: 0.12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}