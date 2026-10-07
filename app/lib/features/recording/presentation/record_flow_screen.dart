// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The record tab — a state-machine driven flow (§8, §9).
///
/// One route, rendered as the right phase: pre-run, live, or complete. The UI
/// never mutates the machine; it only maps [`RunStatus`] to screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../application/recording_controller.dart';
import 'live_run_screen.dart';
import 'pre_run_screen.dart';
import 'run_complete_screen.dart';

class RecordFlowScreen extends ConsumerStatefulWidget {
  const RecordFlowScreen({super.key});

  @override
  ConsumerState<RecordFlowScreen> createState() => _RecordFlowScreenState();
}

class _RecordFlowScreenState extends ConsumerState<RecordFlowScreen> {
  @override
  void initState() {
    super.initState();
    // Keep a fresh session ready whenever the flow has none (including after
    // a dismissed run), so visiting the tab always shows the pre-run screen.
    ref.listenManual(recordingControllerProvider, (_, next) {
      if (next == null) {
        _ensure();
      }
    });
    _ensure();
  }

  void _ensure() {
    final controller = ref.read(recordingControllerProvider.notifier);
    if (ref.read(recordingControllerProvider) == null) {
      final snapshot = ref.read(runSnapshotProvider);
      if (snapshot != null) {
        // M13 §28: an interrupted run was left behind — resume it instead of
        // starting a fresh session.
        controller.resumeFromSnapshot(snapshot);
      } else {
        controller.ensureSession(ref.read(routeRepositoryProvider));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final status = state?.status ?? RunStatus.idle;
    final controller = ref.read(recordingControllerProvider.notifier);
    // Phase key, not raw status: acquiring/ready stay on the same screen and
    // only rebuild (they must not re-trigger a transition every tick).
    final phase = switch (status) {
      RunStatus.running || RunStatus.paused => 'live',
      RunStatus.finishing || RunStatus.completed => 'complete',
      RunStatus.error => 'error',
      _ => 'pre',
    };
    final screen = switch (status) {
      RunStatus.running || RunStatus.paused => LiveRunScreen(state: state!),
      RunStatus.finishing || RunStatus.completed =>
        RunCompleteScreen(state: state!),
      RunStatus.error => _RunErrorScreen(
        error: state?.error,
        onRetry: controller.retry,
        onOpenSettings: state?.error?.gpsSettingsAction == true
            ? controller.openSettings
            : null,
      ),
      _ => PreRunScreen(state: state),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(phase), child: screen),
    );
  }
}

/// Destination for an unrecoverable acquisition error (M14): the reason (when
/// known), an optional jump to the matching system settings, and retry.
class _RunErrorScreen extends StatelessWidget {
  const _RunErrorScreen({
    required this.error,
    required this.onRetry,
    this.onOpenSettings,
  });

  final RunError? error;
  final VoidCallback onRetry;
  final VoidCallback? onOpenSettings;

  static const String _fallback = 'The engine failed to prepare the ghost. '
      'Try again.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New run')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.error),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Could not start a run',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                error?.message ?? _fallback,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              if (onOpenSettings != null) ...[
                const SizedBox(height: AppSpacing.lg),
                OutlinedButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Open location settings'),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}