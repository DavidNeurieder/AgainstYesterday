// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Live run screen — running and paused phases (§12, §13).
///
/// The **gap is the hero metric**: a big ahead/behind readout, then distance,
/// pace and moving time, then the pause/finish controls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../widgets/performance_gap.dart';
import '../../../widgets/route_map.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';

class LiveRunScreen extends ConsumerWidget {
  const LiveRunScreen({super.key, required this.state});

  final LiveRunState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = state.status == RunStatus.paused;
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final controller = ref.read(recordingControllerProvider.notifier);

    final gapState = switch (state.ghostGap) {
      final GhostState gap when gap.ahead => AheadBehind.ahead,
      final GhostState _ => AheadBehind.behind,
      null => AheadBehind.unknown,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(state.route?.name ?? 'New route'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: _GpsPill(quality: state.gpsQuality),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // §17: a transient banner for temporary GPS problems — it sits
              // above the race readout and vanishes once quality recovers.
              if (state.gpsQuality != 'good') ...[
                const _WeakGpsBanner(),
                const SizedBox(height: AppSpacing.md),
              ],
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: paused
                    ? Center(
                        key: const ValueKey('paused'),
                        child: Text(
                          'PAUSED',
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.gpsWarning,
                          ),
                        ),
                      )
                    : const SizedBox(key: ValueKey('resumed')),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      state.distance.formatWith(units),
                      key: const ValueKey('live-distance'),
                      style: textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (state.ghostGap case final gap?)
                    SizedBox(
                      width: 168,
                      child: FittedBox(
                        alignment: Alignment.centerRight,
                        fit: BoxFit.scaleDown,
                        child: PerformanceGap(
                          difference: gap.timeDifference,
                          distance: gap.distance,
                          state: gapState,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RouteMap(
                      geometry: state.route?.geometry ?? const [],
                      you: state.currentPosition ??
                          state.route?.geometry.first ??
                          const GeoPoint(latitude: 51.96, longitude: 7.63),
                      youProgress: state.routeProgress,
                      ghost: state.ghostPosition,
                      name: state.route?.name,
                    ),
                    // §18: the race screen stays underneath; the overlay
                    // clears itself as soon as the runner is back on line.
                    if (state.offRoute case final Distance offRoute)
                      _OffRouteBanner(distance: offRoute),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _Metric(label: 'PACE', value: state.pace.formatPaceWith(units)),
                    _Metric(
                      label: 'TIME',
                      value: state.elapsed.format(),
                      prominent: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: paused ? 'RESUME' : 'PAUSE',
                      icon: paused ? Icons.play_arrow : Icons.pause,
                      onPressed: () {
                        // M14 haptics: light tick for pause/resume.
                        AppHaptics.selection(ref);
                        paused ? controller.resume() : controller.pause();
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _ActionButton(
                      label: 'FINISH',
                      icon: Icons.stop,
                      onPressed: () {
                        // M14 haptics: firm confirm when the run ends.
                        AppHaptics.heavy(ref);
                        controller.finishRun();
                      },
                      foreground: AppColors.background,
                      background: AppColors.you,
                    ),
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

/// §17: transient banner for a temporary GPS problem. Rendered only while
/// quality is off 'good'; recovers on its own with the state.
class _WeakGpsBanner extends StatelessWidget {
  const _WeakGpsBanner();

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

/// §18: off-route overlay — floats over the map so the race screen stays
/// visible underneath. Shows the distance back to the nearest route point.
class _OffRouteBanner extends StatelessWidget {
  const _OffRouteBanner({required this.distance});

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

/// The gap shown to the hero (distance/time only — I/O, no logic).
class _GpsPill extends StatelessWidget {
  const _GpsPill({required this.quality});

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

class _Metric extends StatelessWidget {
  const _Metric({
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
          style: (prominent
                  ? textTheme.titleLarge
                  : textTheme.titleMedium)
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.foreground = AppColors.you,
    this.background = AppColors.surfaceHigh,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }
}