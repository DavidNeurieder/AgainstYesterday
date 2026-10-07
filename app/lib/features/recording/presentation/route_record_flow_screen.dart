// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Record-a-route flow (§8) — a pushed full-screen route over the shell (M18).
///
/// Mirrors the race flow's boundary: the UI never mutates the machine, it
/// maps [`RunStatus`] to screens. A recording is always a *fresh new line*
/// (never a resumed race): prep → recording → name-and-save → saved.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../application/recording_controller.dart';
import 'route_record_prep_screen.dart';
import 'route_record_recorder_screen.dart';
import 'route_record_save_screen.dart';
import 'route_record_saved_screen.dart';

class RouteRecordFlowScreen extends ConsumerStatefulWidget {
  const RouteRecordFlowScreen({super.key});

  @override
  ConsumerState<RouteRecordFlowScreen> createState() =>
      _RouteRecordFlowScreenState();
}

class _RouteRecordFlowScreenState extends ConsumerState<RouteRecordFlowScreen> {
  /// The route as saved — the terminal phase that outlives the dismissed
  /// recording session.
  Route? _saved;

  @override
  void initState() {
    super.initState();
    _startFresh();
  }

  /// A route recording always begins a brand-new session.
  ///
  /// A stale completed session from a previous flow is torn down first so
  /// opening the flow never shadows an old result; an interrupted race is
  /// left alone (its resume belongs to the race flow, not this one).
  void _startFresh() {
    final notifier = ref.read(recordingControllerProvider.notifier);
    final current = ref.read(recordingControllerProvider);
    if (current?.status == RunStatus.completed) {
      notifier.dismissRun();
    }
    if (ref.read(recordingControllerProvider) == null) {
      notifier.ensureSession(const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_saved case final route?) {
      return RouteRecordSavedScreen(route: route);
    }
    final state = ref.watch(recordingControllerProvider);
    final status = state?.status ?? RunStatus.idle;
    final controller = ref.read(recordingControllerProvider.notifier);
    final phase = switch (status) {
      RunStatus.running || RunStatus.paused => 'recorder',
      RunStatus.finishing || RunStatus.completed => 'save',
      RunStatus.error => 'error',
      _ => 'prep',
    };
    final screen = switch (status) {
      RunStatus.running || RunStatus.paused =>
        RouteRecordRecorderScreen(state: state!),
      RunStatus.finishing || RunStatus.completed =>
        RouteRecordSaveScreen(state: state!, onSaved: _onSaved),
      RunStatus.error => _RecordRouteErrorScreen(
        error: state?.error,
        onRetry: controller.retry,
        onOpenSettings: state?.error?.gpsSettingsAction == true
            ? controller.openSettings
            : null,
      ),
      _ => RouteRecordPrepScreen(state: state),
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

  void _onSaved(Route route) {
    setState(() => _saved = route);
  }
}

/// Destination for an unrecoverable acquisition error (same copy as the race
/// flow, M14): the reason (when known), an optional jump to the matching
/// system settings, and retry.
class _RecordRouteErrorScreen extends StatelessWidget {
  const _RecordRouteErrorScreen({
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
      appBar: AppBar(title: const Text('Record Route')),
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