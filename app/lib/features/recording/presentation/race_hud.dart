// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared race/replay HUD widgets — the "real recording" presentation used by
/// both the live run screen and activity replay.
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../widgets/performance_gap.dart';

class GpsPill extends StatelessWidget {
  const GpsPill({super.key, required this.quality});

  final String quality;

  @override
  Widget build(BuildContext context) {
    final good = quality == 'good';
    final color = good ? AppColors.ahead : AppColors.gpsWarning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            good ? Icons.gps_fixed : Icons.gps_off,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            good ? 'GPS' : 'GPS ${quality.toUpperCase()}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class WeakGpsBanner extends StatelessWidget {
  const WeakGpsBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.gpsWarning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gpsWarning),
        ),
        child: Row(
          children: [
            const Icon(Icons.gps_off, color: AppColors.gpsWarning),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GPS SIGNAL WEAK',
                    style: textTheme.titleSmall?.copyWith(
                      color: AppColors.gpsWarning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your position may be temporarily inaccurate.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OffRouteBanner extends StatelessWidget {
  const OffRouteBanner({super.key, required this.distance});

  final Distance distance;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.gpsWarning),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'OFF ROUTE',
                style: textTheme.titleLarge?.copyWith(
                  color: AppColors.gpsWarning,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Return to the route\nto continue your race.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${distance.format()} away',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DistanceReadout extends StatelessWidget {
  const DistanceReadout(
    this.distance,
    this.units, {
    super.key,
    this.secondary = false,
  });

  final Distance distance;
  final Units units;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Text(
      distance.formatWith(units),
      key: key ?? const ValueKey('live-distance'),
      style: (secondary ? textTheme.headlineSmall : textTheme.displayMedium)
          ?.copyWith(
        fontWeight: FontWeight.w700,
        color: secondary ? AppColors.textSecondary : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class HudMetric extends StatelessWidget {
  const HudMetric({
    super.key,
    required this.label,
    required this.value,
    this.prominent = false,
  });

  final String label;
  final String value;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(label, style: textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: (prominent ? textTheme.titleLarge : textTheme.titleMedium)
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// The hero row: gap (ahead/behind) dominates when a ghost exists, with
/// distance as the supporting read; otherwise distance is the hero.
class RaceHeroRow extends StatelessWidget {
  const RaceHeroRow({
    super.key,
    required this.distance,
    required this.units,
    this.ghostGap,
    this.routeProgress = 0,
  });

  final Distance distance;
  final Units units;
  final GhostState? ghostGap;
  final double routeProgress;

  @override
  Widget build(BuildContext context) {
    if (ghostGap case final gap?) {
      final gapState = AheadBehind.fromGap(gap);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          DistanceReadout(distance, units, secondary: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 1,
            child: LinearProgressIndicator(
              value: routeProgress.clamp(0.0, 1.0),
              minHeight: 4,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 2,
            child: FittedBox(
              alignment: Alignment.centerRight,
              fit: BoxFit.scaleDown,
              child: PerformanceGap(
                key: const ValueKey('live-gap'),
                difference: gap.timeDifference,
                distance: gap.distance,
                state: gapState,
                progress: routeProgress,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: DistanceReadout(distance, units)),
      ],
    );
  }
}
