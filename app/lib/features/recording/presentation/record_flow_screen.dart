// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The record flow — a pushed full-screen route over the shell (M16), driven
/// by a state machine (§8, §9).
///
/// One route, rendered as the right phase: pre-run, live, or complete. The UI
/// never mutates the machine; it only maps [`RunStatus`] to screens.
///
/// With a [routeId] (a race against a specific route, `/race/:id`, M19) the
/// pre-run becomes that route's pre-race and START plays a 3-2-1-GO countdown
/// (§11) before the timer starts; a plain `/record` entry stays a free-form
/// new run that starts on the button press.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';
import 'live_run_screen.dart';
import 'pre_run_screen.dart';
import 'run_complete_screen.dart';
import 'run_error_screen.dart';

class RecordFlowScreen extends ConsumerStatefulWidget {
  const RecordFlowScreen({super.key, this.routeId});

  /// When set, the session races exactly this route (empty fallback if the
  /// catalog no longer has it); `/race/:id` supplies it, `/record` does not.
  final String? routeId;

  @override
  ConsumerState<RecordFlowScreen> createState() => _RecordFlowScreenState();
}

class _RecordFlowScreenState extends ConsumerState<RecordFlowScreen> {
  /// True while the 3-2-1-GO overlay (§11) is on screen.
  bool _counting = false;

  /// `3` → `2` → `1` → `0` ("GO!"); 0 hands off to `beginRun()`.
  int _count = 3;
  Timer? _countdownTimer;
  Timer? _goTimer;

  /// Set when a `/race/:id` session is set up but the route is no longer in
  /// the catalog (§33): the pre-run never appears, only the load error.
  bool _routeMissing = false;

  @override
  void initState() {
    super.initState();
    // Keep a fresh session ready whenever the flow has none (including after
    // a dismissed run), so opening the flow always shows the pre-run screen.
    ref.listenManual(recordingControllerProvider, (_, next) {
      if (next == null) {
        _ensure();
      }
    });
    _ensure();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _goTimer?.cancel();
    super.dispose();
  }

  void _ensure() {
    final controller = ref.read(recordingControllerProvider.notifier);
    if (ref.read(recordingControllerProvider) == null) {
      final snapshot = ref.read(runSnapshotProvider);
      if (snapshot != null) {
        // M13 §28: an interrupted run was left behind — resume it instead of
        // starting a fresh session.
        controller.resumeFromSnapshot(snapshot);
      } else if (widget.routeId case final id?) {
        // A race targets exactly one route; an empty match degrades to the
        // §33 load error instead of a ghostless run.
        final routes = ref.read(routeRepositoryProvider);
        final match = [
          for (final route in routes) if (route.id == id) route,
        ];
        _routeMissing = match.isEmpty;
        controller.ensureSession(match);
      } else {
        controller.ensureSession(ref.read(routeRepositoryProvider));
      }
    }
  }

  /// §33 RETRY: reload the route catalog (a route may have been re-imported)
  /// and rebuild the session from it.
  void _retryRouteLoad() {
    ref.invalidate(routeRepositoryProvider);
    ref.read(recordingControllerProvider.notifier).dismissRun();
    setState(() {
      _routeMissing = false;
      _ensure();
    });
  }

  /// Countdown disabled (Settings → Race), so START begins immediately, just
  /// like a free `/record` run.
  void _beginNow() {
    ref.read(recordingControllerProvider.notifier).beginRun();
  }

  void _startCountdown() {
    if (_counting) {
      return;
    }
    _counting = true;
    _count = 3;
    setState(() {});
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_count > 1) {
          // 3 → 2 → 1.
          _count -= 1;
        } else {
          // 1 → GO!, then hand off to the timer at GO.
          _count = 0;
          _countdownTimer?.cancel();
          _countdownTimer = null;
          _goTimer = Timer(const Duration(milliseconds: 400), () {
            if (!mounted) {
              return;
            }
            setState(() => _counting = false);
            ref.read(recordingControllerProvider.notifier).beginRun();
          });
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final status = state?.status ?? RunStatus.idle;
    final controller = ref.read(recordingControllerProvider.notifier);
    // Phase key, not raw status: acquiring/ready stay on the same screen and
    // only rebuild (they must not re-trigger a transition every tick).
    final phase = _counting
        ? 'count'
        : switch (status) {
            RunStatus.running || RunStatus.paused => 'live',
            RunStatus.finishing || RunStatus.completed => 'complete',
            RunStatus.error => 'error',
            _ => 'pre',
          };
    final screen = _routeMissing
        ? _RouteLoadErrorScreen(onRetry: _retryRouteLoad)
        : _counting
        ? _CountdownScreen(count: _count)
        : switch (status) {
            RunStatus.running || RunStatus.paused => LiveRunScreen(state: state!),
            RunStatus.finishing || RunStatus.completed =>
              RunCompleteScreen(state: state!),
            RunStatus.error => RunErrorScreen(
                error: state?.error,
                barTitle: 'New run',
                onRetry: controller.retry,
                onOpenSettings: state?.error?.gpsSettingsAction == true
                    ? controller.openSettings
                    : null,
              ),
            _ => PreRunScreen(
                state: state,
                title: widget.routeId == null
                    ? 'New run'
                    : (state?.route?.name ?? 'New run'),
                onStart: widget.routeId == null
                    ? null
                    : ref.watch(countdownEnabledProvider)
                        ? _startCountdown
                        : _beginNow,
              ),
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
      child: KeyedSubtree(
        key: ValueKey(_routeMissing ? 'routeError' : phase),
        child: screen,
      ),
    );
  }
}

/// The 3-2-1-GO phase (§11): a very large animated number, scale-fading in
/// each step, held full-screen so the awaiting pre-race never shows through.
class _CountdownScreen extends StatelessWidget {
  const _CountdownScreen({required this.count});

  /// `3`, `2`, `1`, then `0` renders "GO!".
  final int count;

  @override
  Widget build(BuildContext context) {
    final label = switch (count) { 3 => '3', 2 => '2', 1 => '1', _ => 'GO!' };
    final isGo = count == 0;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween<double>(begin: 1.3, end: 1.0).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                ),
              ),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Text(
              label,
              key: ValueKey<int>(count),
              style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontSize: 120,
                    fontWeight: FontWeight.w900,
                    color: isGo ? AppColors.ahead : AppColors.you,
                    height: 1,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// §33: the race's route vanished from the catalog before the session could
/// start — the pre-run never appears, only the recovery action.
class _RouteLoadErrorScreen extends StatelessWidget {
  const _RouteLoadErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ErrorScreen(
      barTitle: 'Race',
      title: 'COULDN\'T LOAD ROUTE',
      message: 'Try again.',
      actions: [
        FilledButton(onPressed: onRetry, child: const Text('RETRY')),
      ],
    );
  }
}