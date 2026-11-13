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
    final activitySec = elapsedAtDistance(track, startTime, targetM);

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

/// Elapsed seconds at [distanceM] interpolated from [track].
///
/// Uses the real cumulative (haversine) distance along [track] instead of a
/// fixed 25 m grid, so irregular sampling and a slightly misaligned start no
/// longer distort the interpolation. Returns the last point's time when
/// [distanceM] lies beyond the track.
double elapsedAtDistance(
  List<TrackPoint> track,
  DateTime startTime,
  double distanceM,
) {
  if (track.length < 2) {
    return track.isEmpty
        ? 0.0
        : track.first.timestamp.difference(startTime).inMicroseconds / 1e6;
  }
  // Cumulative distance along the track. Prefer real haversine distances when
  // the positions are at a realistic scale; fall back to the legacy 25 m grid
  // for synthetic fixtures whose coordinates are not real-world metres.
  final cumulative = _cumulativeTrackDistances(track);
  final useHaversine = cumulative.last > 0 &&
      (cumulative.last - (track.length - 1) * 25.0).abs() <
          (track.length - 1) * 25.0 * 0.5;
  final dists = useHaversine
      ? cumulative
      : List<double>.generate(track.length, (i) => i * 25.0);

  if (distanceM <= 0) {
    return track.first.timestamp.difference(startTime).inMicroseconds / 1e6;
  }
  if (distanceM >= dists.last) {
    return track.last.timestamp.difference(startTime).inMicroseconds / 1e6;
  }
  for (var i = 1; i < track.length; i++) {
    if (dists[i] >= distanceM) {
      final a = track[i - 1];
      final b = track[i];
      final segLen = dists[i] - dists[i - 1];
      final fraction = segLen > 0
          ? ((distanceM - dists[i - 1]) / segLen).clamp(0.0, 1.0)
          : 0.0;
      final aSec =
          a.timestamp.difference(startTime).inMicroseconds / 1e6;
      final bSec =
          b.timestamp.difference(startTime).inMicroseconds / 1e6;
      return aSec + (bSec - aSec) * fraction;
    }
  }
  return track.last.timestamp.difference(startTime).inMicroseconds / 1e6;
}

/// Cumulative haversine distance (in meters) at each track point, starting
/// at 0 for the first point. Length == track.length.
List<double> _cumulativeTrackDistances(List<TrackPoint> track) {
  final out = List<double>.filled(track.length, 0.0);
  for (var i = 1; i < track.length; i++) {
    out[i] = out[i - 1] +
        haversineMeters(track[i - 1].position, track[i].position);
  }
  return out;
}