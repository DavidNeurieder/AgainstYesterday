// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Fixed-outcome race fixtures (test plan Phase 2).
///
/// Racing a ghost is otherwise at the mercy of the engine's demo noise: the
/// fake engine jitters its generated recording by a metre, so "ahead" and
/// "behind" land within a second of each other and a test can only accept
/// either outcome. [LinearGhostEngine] replaces that with a ghost whose
/// reference time is exactly `distance / speed`, so a scripted fix timeline
/// pins the gap sign *and* its magnitude.
library;

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';

import 'gps_fixtures.dart';

/// A ghost walked at a perfectly constant [ghostSpeedMps]: one sample per
/// second, so the reference time at distance `d` interpolates to `d / speed`.
class LinearGhostEngine extends FakeEngineService {
  LinearGhostEngine({required this.ghostSpeedMps});

  final double ghostSpeedMps;

  @override
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
  }) async {
    final length = polylineMeters(routeGeometry);
    final samples = <AttemptSample>[
      const AttemptSample(
        distance: Distance.meters(0),
        elapsed: Elapsed.zero(),
      ),
    ];
    var t = 1.0;
    while (t * ghostSpeedMps < length) {
      samples.add(
        AttemptSample(
          distance: Distance.meters(t * ghostSpeedMps),
          elapsed: Elapsed.seconds(t),
        ),
      );
      t += 1;
    }
    samples.add(
      AttemptSample(
        distance: Distance.meters(length),
        elapsed: Elapsed.seconds(length / ghostSpeedMps),
      ),
    );
    return Attempt(
      activityId: activityId,
      routeId: routeId,
      elapsed: Elapsed.seconds(length / ghostSpeedMps),
      samples: samples,
    );
  }
}

/// The constant speed every fixture ghost walks at.
const double raceGhostSpeedMps = 5.0;

/// A straight two-point route the fixtures race along.
const List<GeoPoint> raceLine = [
  GeoPoint(latitude: 52.5000, longitude: 13.4000),
  GeoPoint(latitude: 52.5100, longitude: 13.4000),
];

/// The geometry length, in meters, of [raceLine].
final double raceLineLengthMeters = polylineMeters(raceLine);

/// A route carrying a PB run at exactly [raceGhostSpeedMps].
final Route raceRoute = Route(
  id: 'race-line',
  name: 'Race Line',
  distance: Distance.meters(raceLineLengthMeters),
  geometry: raceLine,
  attemptCount: 3,
  personalBest: Elapsed.seconds(raceLineLengthMeters / raceGhostSpeedMps),
);

/// A two-fix timeline that reaches [fraction] of [raceLine] after exactly
/// [movingSeconds] of moving time. The first fix is the anchor (no motion), so
/// the second's delay *is* the run's moving time.
GpsScenario raceScenario({
  required double fraction,
  required double movingSeconds,
}) {
  final lat = raceLine.first.latitude +
      (raceLine.last.latitude - raceLine.first.latitude) * fraction;
  return GpsScenario(
    name: 'race_${fraction}_$movingSeconds',
    samples: [
      GpsSample(after: const Duration(seconds: 1), position: raceLine.first),
      GpsSample(
        after: Duration(milliseconds: (movingSeconds * 1000).round()),
        position: GeoPoint(
          latitude: lat,
          longitude: raceLine.first.longitude,
        ),
      ),
    ],
  );
}

/// The reference (ghost) time, in seconds, at [fraction] of [raceLine].
double raceReferenceSeconds(double fraction) =>
    fraction * raceLineLengthMeters / raceGhostSpeedMps;
