// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Per-km split deltas against the personal best (M11, §20).
///
/// Splits are derived from the activity's persisted track and the route's PB
/// time under the constant-speed model — no engine call needed.
library;

import 'package:against_yesterday/engine/models.dart';

/// One per-kilometer delta versus the PB.
class SplitDelta {
  const SplitDelta({
    required this.kilometer,
    required this.elapsedSeconds,
    required this.deltaSeconds,
  });

  /// 1-based kilometer marker.
  final int kilometer;

  /// Running elapsed (seconds) when this km was reached.
  final double elapsedSeconds;

  /// Positive = behind PB, negative = ahead.
  final double deltaSeconds;
}

/// Computes per-km split deltas for [activity] relative to [route]'s PB.
///
/// [trackMeters] is the total along-track distance of the activity in meters
/// (the distance the controller recorded, which may be less than the full
/// route length). The geometry is expected to match the route's axis.
///
/// Returns an empty list when there is no PB or no track data.
List<SplitDelta> computeSplits({
  required Activity activity,
  required Route route,
  required double trackMeters,
}) {
  final track = activity.track;
  final pb = route.personalBest;
  if (track == null || track.length < 2 || pb == null || pb.seconds <= 0) {
    return [];
  }

  final routeMeters = route.distance.meters;
  if (routeMeters <= 0) {
    return [];
  }

  final totalKm = (trackMeters / 1000).floor();
  if (totalKm <= 0) {
    return [];
  }

  // Start time anchors the activity's clock.
  final startTime = track.first.timestamp;
  final pbSpeed = routeMeters / pb.seconds; // m/s constant-pace PB

  final splits = <SplitDelta>[];
  for (var km = 1; km <= totalKm; km++) {
    final targetM = km * 1000.0;

    // Activity time at this km: linear interpolation on the track.
    final activitySec = _elapsedAtDistance(track, startTime, targetM);

    // PB time at this km: constant speed.
    final pbSec = targetM / pbSpeed;

    splits.add(SplitDelta(
      kilometer: km,
      elapsedSeconds: activitySec,
      deltaSeconds: activitySec - pbSec,
    ));
  }
  return splits;
}

/// Elapsed seconds at [distanceM] interpolated from [track] (25 m-spaced).
double _elapsedAtDistance(
  List<TrackPoint> track,
  DateTime startTime,
  double distanceM,
) {
  for (var i = 1; i < track.length; i++) {
    // Cumulative distance at track[i] ≈ index × 25 m.
    final cumulativeM = i * 25.0;
    if (cumulativeM >= distanceM) {
      final a = track[i - 1];
      final b = track[i];
      final fraction =
          ((distanceM - (i - 1) * 25.0) / 25.0).clamp(0.0, 1.0);
      final aSec =
          a.timestamp.difference(startTime).inMicroseconds / 1e6;
      final bSec =
          b.timestamp.difference(startTime).inMicroseconds / 1e6;
      return aSec + (bSec - aSec) * fraction;
    }
  }
  // Beyond the track; use the last point.
  return track.last.timestamp.difference(startTime).inMicroseconds / 1e6;
}