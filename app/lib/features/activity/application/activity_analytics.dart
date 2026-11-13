// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Cached, engine-backed track analytics for one activity (M30/M37).
///
/// Keyed by activity id so repeated views of the same run reuse one result
/// instead of re-running the Rust analysis, and so the activity-detail and
/// replay surfaces agree on the same numbers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';

final trackAnalyticsProvider =
    FutureProvider.family<TrackAnalytics?, String>((ref, activityId) async {
  final activities = ref.watch(activityRepositoryProvider);
  Activity? activity;
  for (final a in activities) {
    if (a.id == activityId) {
      activity = a;
      break;
    }
  }
  final track = activity?.track;
  if (track == null || track.isEmpty) return null;
  return ref.read(engineServiceProvider).analyzeTrack(points: track);
});