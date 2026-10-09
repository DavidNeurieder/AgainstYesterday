// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Recording phase (§8 Step 2) — deliberately simpler than the race screen:
/// there is no ghost yet, so the loop is just distance + a wall-clock
/// stopwatch and the pause/finish controls. No gap, no map, no split stats.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';

class RouteRecordRecorderScreen extends ConsumerWidget {
  const RouteRecordRecorderScreen({super.key, required this.state});

  final LiveRunState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = state.status == RunStatus.paused;
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final controller = ref.read(recordingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record Route'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: AppSpacing.md),
            child: _GpsPill(),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                    : const SizedBox(key: ValueKey('recording')),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                state.distance.formatWith(units),
                key: const ValueKey('record-distance'),
                textAlign: TextAlign.center,
                style: textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Metric(
                    label: 'DISTANCE',
                    value: state.distance.formatWith(units),
                  ),
                  const SizedBox(width: AppSpacing.xl),
                  _Metric(
                    label: 'TIME',
                    value: state.clockElapsed.format(),
                    prominent: true,
                    valueKey: const ValueKey('record-time'),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: paused ? 'RESUME' : 'PAUSE',
                      icon: paused ? Icons.play_arrow : Icons.pause,
                      onPressed: () {
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

/// Static label for a recording: GPS stays good for the whole capture or the
/// receiver is off — there is no per-fix quality to read here.
class _GpsPill extends StatelessWidget {
  const _GpsPill();

  @override
  Widget build(BuildContext context) {
    final color = AppColors.ahead;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.gps_fixed, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            'GPS',
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
    this.valueKey,
  });

  final String label;
  final String value;
  final bool prominent;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(label, style: textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          key: valueKey,
          style: (prominent ? textTheme.titleLarge : textTheme.titleMedium)
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