// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Save step (§8 Step 3): the completed recording becomes a real route. The
/// runner names it; SAVE persists the route (geometry + this attempt as the
/// first PB) and tags the just-finished activity with it. Needs actual
/// position data — a recording that never moved has nothing to turn into a
/// course, so SAVE stays disabled until there is a track and a name.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/recording_controller.dart';

class RouteRecordSaveScreen extends ConsumerStatefulWidget {
  const RouteRecordSaveScreen({
    super.key,
    required this.state,
    required this.onSaved,
  });

  final LiveRunState state;

  /// Invoked once the route has been persisted (session already dismissed).
  final ValueChanged<Route> onSaved;

  @override
  ConsumerState<RouteRecordSaveScreen> createState() =>
      _RouteRecordSaveScreenState();
}

class _RouteRecordSaveScreenState extends ConsumerState<RouteRecordSaveScreen> {
  final TextEditingController _name = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final track = _capturedTrack;
    final hasGeometry = track.length >= 2;
    final canSave = !_saving && _name.text.trim().isNotEmpty && hasGeometry;

    return Scaffold(
      appBar: AppBar(title: const Text('Record Route')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.md),
              Text(
                'Route complete',
                textAlign: TextAlign.center,
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                widget.state.distance.formatWith(units),
                textAlign: TextAlign.center,
                style: textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.state.elapsed.format(),
                textAlign: TextAlign.center,
                style: textTheme.titleLarge?.copyWith(
                  color: AppColors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                controller: _name,
                enabled: !_saving,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Route name',
                  hintText: 'e.g. Riverside Loop',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (!hasGeometry)
                Text(
                  'The recording captured no position data — finish a run '
                  'with a GPS fix to save a route.',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.error),
                ),
              const Spacer(),
              FilledButton(
                onPressed: canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.you,
                  foregroundColor: AppColors.background,
                  minimumSize: const Size.fromHeight(64),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: Text('SAVE ROUTE', style: textTheme.titleMedium),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The recording's synthesized track, captured before the session is torn
  /// down by the save (which dismisses the controller).
  List<TrackPoint> get _capturedTrack =>
      ref.read(recordingControllerProvider.notifier).currentTrack() ??
      const <TrackPoint>[];

  /// Persists the route and tags the finished activity with it. The route's
  /// first attempt becomes its baseline PB; saving is deliberately a hard turn
  /// — failures surface rather than silently dropping the route.
  Future<void> _save() async {
    final state = widget.state;
    final controller = ref.read(recordingControllerProvider.notifier);
    final track = _capturedTrack;
    final startedAt = state.startedAt ?? DateTime.now().toUtc();
    final route = Route(
      id: 'route-${startedAt.millisecondsSinceEpoch}',
      name: _name.text.trim(),
      distance: state.distance,
      geometry: [for (final point in track) point.position],
      attemptCount: 1,
      personalBest: state.elapsed,
    );
    final activity = Activity(
      id: 'act-${startedAt.millisecondsSinceEpoch}',
      routeId: route.id,
      startedAt: startedAt,
      duration: state.elapsed,
      distance: state.distance,
      performance: state.elapsed.format(),
      track: track,
      rawFixes: controller.currentFixes(),
    );
    setState(() => _saving = true);
    AppHaptics.medium(ref);
    try {
      await ref.read(routeRepositoryProvider.notifier).saveRoute(route);
      // The controller already saved the raw run; upserting the same id with
      // the route tag links the attempt to the new course.
      await ref.read(activityRepositoryProvider.notifier).saveActivity(activity);
      controller.dismissRun();
      if (mounted) {
        widget.onSaved(route);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the route. Try again.')),
        );
      }
    }
  }
}