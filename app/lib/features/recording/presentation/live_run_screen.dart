// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Live run screen — running and paused phases (§12, §13).
///
/// The **gap is the hero metric**: a big ahead/behind readout at full size
/// (the only number that answers "am I winning?"), with distance beside it as
/// the supporting read, then pace, moving time and fix count, then the
/// pause/finish controls. FINISH confirms before it ends the run, so a stray
/// tap mid-stride cannot seal the session.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../widgets/performance_gap.dart';
import '../../map/map_surface.dart';
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
    final mapSurface = ref.watch(mapSurfaceProvider);
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
              // A failed foreground-service start is said out loud: recording
              // may continue with the screen on, but the UI never claims it is
              // protected with the screen off.
              if (state.backgroundProtection ==
                  BackgroundProtection.unavailable) ...[
                const _ProtectionBanner(),
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
              // §2: the gap leads — it is the one number that answers "am I
              // winning?" — so it gets the hero type at its natural size
              // instead of being squeezed into a fixed 168 px box beside a
              // larger distance. Distance stays on screen as the supporting
              // read, muted so the ahead/behind colour owns the row.
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (state.ghostGap case final gap?) ...[
                    _DistanceReadout(state.distance, units, secondary: true),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      // §2: the gap owns the rest of the row at its natural
                      // size; scaleDown only steps in on the narrowest phones,
                      // so an hour-long gap can never wrap mid-digit.
                      child: FittedBox(
                        alignment: Alignment.centerRight,
                        fit: BoxFit.scaleDown,
                        child: PerformanceGap(
                          key: const ValueKey('live-gap'),
                          difference: gap.timeDifference,
                          distance: gap.distance,
                          state: gapState,
                        ),
                      ),
                    ),
                  ] else
                    // No ghost to race: distance *is* the hero readout.
                    Expanded(
                      child: _DistanceReadout(state.distance, units),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    mapSurface.build(
                      context,
                      MapScene(
                        geometry: state.route?.geometry ?? const [],
                        you: state.currentPosition ??
                            state.route?.geometry.first ??
                            const GeoPoint(latitude: 51.96, longitude: 7.63),
                        youProgress: state.routeProgress,
                        ghost: state.ghostPosition,
                        name: state.route?.name,
                      ),
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
                  children: [
                    Expanded(
                      child: _Metric(
                        label: 'PACE',
                        value: state.pace.formatPaceWith(units),
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'TIME',
                        value: state.elapsed.format(),
                        prominent: true,
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        key: const ValueKey('live-fixes'),
                        label: 'FIXES',
                        value: '${state.rawFixCount}',
                      ),
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
                      onPressed: () => _confirmFinish(context, ref),
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

/// §12: FINISH seals the session — the clock stops, the run is saved, and the
/// live screen is gone — so it asks first. A runner glancing at the phone
/// mid-stride should not end the run with a stray tap.
Future<void> _confirmFinish(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(recordingControllerProvider.notifier);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Finish this run?'),
      content: const Text(
        'The clock stops and the run is saved. You can still view the result.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep running'),
        ),
        FilledButton(
          key: const ValueKey('confirm-finish'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Finish'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return;
  }
  // M14 haptics: firm confirm when the run ends.
  AppHaptics.heavy(ref);
  controller.finishRun();
}

/// Screen-off protection failed to start. The run may keep recording with the
/// screen on, but Android will not deliver GPS while the screen is off — say
/// it out loud instead of pretending the recording is protected.
class _ProtectionBanner extends StatelessWidget {
  const _ProtectionBanner();

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
            const Icon(Icons.phonelink_lock, color: AppColors.gpsWarning),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SCREEN-OFF RECORDING NOT PROTECTED',
                    style: textTheme.titleSmall?.copyWith(
                      color: AppColors.gpsWarning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'The run is still recording while the screen is on.',
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

/// The live distance read (§2): the hero number of a free run, and the
/// supporting readout beside a race's hero gap — smaller and muted so the
/// ahead/behind colours stay the first thing the eye finds.
class _DistanceReadout extends StatelessWidget {
  const _DistanceReadout(
    this.distance,
    this.units, {
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
      key: const ValueKey('live-distance'),
      style: (secondary ? textTheme.headlineSmall : textTheme.displayMedium)
          ?.copyWith(
        fontWeight: FontWeight.w700,
        color: secondary ? AppColors.textSecondary : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
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