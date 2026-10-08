// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Gap-to-PB curve over the route (§23, M26).
///
/// Samples the run's persisted track at a fixed distance step and records
/// how far ahead of (or behind) the personal best the runner was at each
/// sample. Like [computeSplits], the PB side uses the constant-speed model
/// — no engine call needed. The result feeds the performance graph on the
/// result screen.
library;

import 'package:against_yesterday/engine/models.dart';

import 'splits.dart';

/// Distance between two curve samples, in meters.
const double gapSampleStepMeters = 100;

/// Covered distance below which the chart is not worth drawing (roughly
/// two samples plus the origin).
const double gapChartMinimumMeters = 250;

/// One sample of the gap curve.
class GapPoint {
  const GapPoint({
    required this.distanceMeters,
    required this.aheadSeconds,
  });

  /// Distance from the start, in meters.
  final double distanceMeters;

  /// Seconds ahead of the PB at this distance (negative = behind).
  final double aheadSeconds;
}

/// Builds the gap curve for [activity] relative to [route]'s PB.
///
/// [trackMeters] is the total along-track distance the controller recorded
/// (it may be less than the full route length); the curve spans
/// 0 … [trackMeters] and starts at the origin (0 s at the start line).
///
/// Returns an empty list when there is no PB, no track, or too little
/// distance to draw (see [gapChartMinimumMeters]).
List<GapPoint> computeGapCurve({
  required Activity activity,
  required Route route,
  required double trackMeters,
}) {
  final track = activity.track;
  final pb = route.personalBest;
  if (track == null || track.length < 2 || pb == null || pb.seconds <= 0) {
    return const <GapPoint>[];
  }
  final routeMeters = route.distance.meters;
  if (routeMeters <= 0 || trackMeters < gapChartMinimumMeters) {
    return const <GapPoint>[];
  }

  final startTime = track.first.timestamp;
  final pbSpeed = routeMeters / pb.seconds; // m/s constant-pace PB

  double gapAt(double d) => d / pbSpeed - elapsedAtDistance(track, startTime, d);

  final points = <GapPoint>[
    const GapPoint(distanceMeters: 0, aheadSeconds: 0),
  ];
  for (var d = gapSampleStepMeters;
      d < trackMeters;
      d += gapSampleStepMeters) {
    points.add(GapPoint(distanceMeters: d, aheadSeconds: gapAt(d)));
  }
  points.add(
    GapPoint(distanceMeters: trackMeters, aheadSeconds: gapAt(trackMeters)),
  );
  return points;
}
