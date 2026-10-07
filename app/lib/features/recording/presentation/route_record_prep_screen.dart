// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Record-route preparation (§8 Step 1): GPS must be READY before the big
/// [START RECORDING] press. Recording itself only begins on the explicit tap —
/// the same gate the race flow uses, verbatim copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../application/recording_controller.dart';

class RouteRecordPrepScreen extends ConsumerWidget {
  const RouteRecordPrepScreen({super.key, required this.state});

  /// May be null only while the session is booting.
  final LiveRunState? state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = state?.status ?? RunStatus.preparing;
    final ready = status == RunStatus.ready;
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(recordingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Record Route')),
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
                        _GpsBadge(ready: ready),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          ready ? 'Ready to record' : 'Waiting for GPS…',
                          textAlign: TextAlign.center,
                          style: textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: ready ? AppColors.you : AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          ready
                              ? 'Move to your starting point.'
                              : 'Move somewhere with a clearer view of the sky.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'You are recording a new route — '
                          'your first attempt becomes its baseline.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.textMuted,
                          ),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: ready
                              ? () {
                                  HapticFeedback.mediumImpact();
                                  controller.beginRun();
                                }
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.you,
                            foregroundColor: AppColors.background,
                            minimumSize: const Size.fromHeight(64),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: Text('START RECORDING',
                              style: textTheme.titleMedium),
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

class _GpsBadge extends StatelessWidget {
  const _GpsBadge({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final color = ready ? AppColors.ahead : AppColors.gpsWarning;
    return Center(
      child: Chip(
        avatar: Icon(
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