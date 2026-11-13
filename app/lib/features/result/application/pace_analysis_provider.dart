// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Engine-backed pace analysis for one attempt.
///
/// Splits and the gap-to-PB curve are computed by the engine; these providers
/// only resolve the activity/route inputs and cache the result for the
/// result and activity screens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../recording/application/recording_controller.dart';

/// Splits + gap curve for the saved activity [activityId].
final activityPaceAnalysisProvider = FutureProvider.autoDispose
    .family<PaceAnalysis, String>((ref, activityId) async {
      final activity = ref
          .watch(activityRepositoryProvider)
          .where((a) => a.id == activityId)
          .firstOrNull;
      if (activity == null || activity.track == null) {
        return PaceAnalysis.empty;
      }
      final route = ref
          .watch(routeRepositoryProvider)
          .where((r) => r.id == activity.routeId)
          .firstOrNull;
      if (route == null) {
        return PaceAnalysis.empty;
      }
      return ref
          .read(engineServiceProvider)
          .computePaceAnalysis(
            activity: activity,
            route: route,
            trackMeters: activity.distance?.meters ?? 0,
          );
    });

/// Splits + gap curve for the run that just finished and is being shown on
/// the result screen.
final resultPaceAnalysisProvider = FutureProvider.autoDispose<PaceAnalysis>((
  ref,
) async {
  final live = ref.watch(recordingControllerProvider);
  final activity = ref.watch(activityRepositoryProvider).firstOrNull;
  final route = live?.route;
  if (live == null || activity == null || route == null) {
    return PaceAnalysis.empty;
  }
  if (activity.track == null) {
    return PaceAnalysis.empty;
  }
  // The saved activity owns the distance this run covered; the live state
  // resets once the run is finished and saved.
  return ref
      .read(engineServiceProvider)
      .computePaceAnalysis(
        activity: activity,
        route: route,
        trackMeters: activity.distance?.meters ?? live.distance.meters,
      );
});
