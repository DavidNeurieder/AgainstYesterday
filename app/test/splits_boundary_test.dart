// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Split boundary & pacing edge cases (test plan Phase 7).
///
/// Complements `splits_test.dart` with the *boundaries* the plan calls out:
/// the sub-km threshold, exact-km rounding, and a run whose internal pacing is
/// uneven (each split must reflect the cumulative clock, not a flat average).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/result/application/splits.dart';

Route _route({double distanceM = 5000, double? pbSeconds = 1500}) => Route(
      id: FakeEngineService.riverLoopId,
      name: 'River Loop',
      distance: Distance.meters(distanceM),
      geometry: FakeEngineService.riverLoop,
      attemptCount: 3,
      personalBest: pbSeconds == null ? null : Elapsed.seconds(pbSeconds),
    );

/// A flat track: 25 m-spaced points covering `meters`, timed so the last
/// point is at `totalSeconds`.
List<TrackPoint> _track(double meters, double totalSeconds) {
  final start = DateTime.utc(2026, 1, 1);
  final points = <TrackPoint>[];
  for (var d = 0.0; d <= meters; d += 25.0) {
    final fraction = meters <= 0 ? 0.0 : d / meters;
    points.add(TrackPoint(
      position: GeoPoint(
        latitude: 52.5 + fraction,
        longitude: 13.36,
      ),
      timestamp: start.add(Duration(
        milliseconds: (totalSeconds * 1000 * fraction).round(),
      )),
    ));
  }
  return points;
}

/// A 2 km track that runs the first km fast (400 s) and the second km slow.
///
/// Cumulative clock: km 1 at 400 s, km 2 at 400 + 1200 = 1600 s.
List<TrackPoint> _pacedTrack() {
  final start = DateTime.utc(2026, 1, 1);
  final points = <TrackPoint>[];
  for (var d = 0.0; d <= 2000.0; d += 25.0) {
    final seconds = d <= 1000.0
        ? d / 25.0 * 10.0 // 25 m per 10 s → 400 s for the first km.
        : 400.0 + (d - 1000.0) / 25.0 * 30.0; // then 30 s per 25 m.
    points.add(TrackPoint(
      position: GeoPoint(
        latitude: 52.5 + d / 2000.0,
        longitude: 13.36,
      ),
      timestamp: start.add(Duration(milliseconds: (seconds * 1000).round())),
    ));
  }
  return points;
}

void main() {
  Activity activityOf(
    double meters,
    double seconds, {
    required List<TrackPoint> track,
  }) =>
      Activity(
        id: 'a',
        routeId: FakeEngineService.riverLoopId,
        startedAt: DateTime.utc(2026, 1, 1),
        duration: Elapsed.seconds(seconds),
        distance: Distance.meters(meters),
        track: track,
      );

  group('the km boundary', () {
    test('just under 1 km produces no splits', () {
      final splits = computeSplits(
        activity: activityOf(999, 300, track: _track(999, 300)),
        route: _route(pbSeconds: 300),
        trackMeters: 999,
      );
      expect(splits, isEmpty);
    });

    test('exactly 1.000 km produces exactly one split', () {
      // 1 km in 60 s matches the route's PB pace (5000 m in 300 s).
      final splits = computeSplits(
        activity: activityOf(1000, 60, track: _track(1000, 60)),
        route: _route(pbSeconds: 300),
        trackMeters: 1000,
      );
      expect(splits, hasLength(1));
      expect(splits.single.kilometer, 1);
      expect(splits.single.deltaSeconds.abs(), lessThan(1e-6));
    });

    test('just over 1.000 km still reports only the completed km', () {
      final splits = computeSplits(
        activity: activityOf(1001, 60.06, track: _track(1001, 60.06)),
        route: _route(pbSeconds: 300),
        trackMeters: 1001,
      );
      expect(splits, hasLength(1));
    });

    test('a 0.999 km run even at record pace earns no split', () {
      final splits = computeSplits(
        activity: activityOf(999, 60, track: _track(999, 60)),
        route: _route(pbSeconds: 1500),
        trackMeters: 999,
      );
      expect(splits, isEmpty);
    });
  });

  group('marginal personal bests', () {
    test('beating the PB by three seconds flips every delta negative', () {
      // 1497 s vs a 1500 s PB: 0.6 s/km margin — real but tiny. (Deliberately
      // larger than a millisecond so ms-precision tracks stay faithful.)
      final splits = computeSplits(
        activity: activityOf(5000, 1497, track: _track(5000, 1497)),
        route: _route(pbSeconds: 1500),
        trackMeters: 5000,
      );
      expect(splits, hasLength(5));
      for (final split in splits) {
        expect(split.deltaSeconds, lessThan(0),
            reason: 'km ${split.kilometer} should edge the PB');
      }
    });
  });

  group('internal pacing', () {
    test('each split honors the cumulative clock of the paced run', () {
      final splits = computeSplits(
        activity: activityOf(2000, 1600, track: _pacedTrack()),
        route: _route(pbSeconds: 1500),
        trackMeters: 2000,
      );
      expect(splits, hasLength(2));
      // Fast first km: at 400 s vs a 300 s PB km → +100 s.
      expect(splits[0].kilometer, 1);
      expect(splits[0].elapsedSeconds, closeTo(400, 0.01));
      expect(splits[0].deltaSeconds, closeTo(100, 0.01));
      // Slow second km: cumulative 1600 s vs 600 s PB → +1000 s.
      expect(splits[1].kilometer, 2);
      expect(splits[1].elapsedSeconds, closeTo(1600, 0.01));
      expect(splits[1].deltaSeconds, closeTo(1000, 0.01));
    });
  });
}