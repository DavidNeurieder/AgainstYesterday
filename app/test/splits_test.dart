// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/core/units.dart';
import 'package:gps_app/engine/fake_engine.dart';
import 'package:gps_app/engine/models.dart';
import 'package:gps_app/features/result/application/splits.dart';

Route _route({double? pbSeconds = 1500}) => Route(
      id: FakeEngineService.riverLoopId,
      name: 'River Loop',
      distance: const Distance.meters(5000),
      geometry: FakeEngineService.riverLoop,
      attemptCount: 3,
      personalBest: pbSeconds == null ? null : Elapsed.seconds(pbSeconds),
    );

/// A flat 5 km track: 25 m-spaced points covering `meters`,
/// timed so the last point is at `totalSeconds`.
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

void main() {
  Activity activityOf(
    double meters,
    double seconds, {
    List<TrackPoint>? track,
  }) =>
      Activity(
        id: 'a',
        routeId: FakeEngineService.riverLoopId,
        startedAt: DateTime.utc(2026, 1, 1),
        duration: Elapsed.seconds(seconds),
        distance: Distance.meters(meters),
        track: track,
      );

  test('no splits without PB', () {
    final route = _route(pbSeconds: null);
    expect(
      computeSplits(
        activity: activityOf(5000, 1500, track: _track(5000, 1500)),
        route: route,
        trackMeters: 5000,
      ),
      isEmpty,
    );
  });

  test('no splits without a track', () {
    final route = _route();
    expect(
      computeSplits(
        activity: activityOf(5000, 1500),
        route: route,
        trackMeters: 5000,
      ),
      isEmpty,
    );
  });

  test('a PB-matched run yields zero deltas at every km', () {
    // 5 km in 1500 s is exactly the PB pace.
    final splits = computeSplits(
      activity: activityOf(5000, 1500, track: _track(5000, 1500)),
      route: _route(pbSeconds: 1500),
      trackMeters: 5000,
    );
    expect(splits, hasLength(5));
    for (var i = 0; i < splits.length; i++) {
      expect(splits[i].kilometer, i + 1);
      expect(splits[i].deltaSeconds.abs(), lessThan(1e-6),
          reason: 'km ${i + 1} should tie the PB');
    }
  });

  test('a slower-than-PB run is behind on every split (cumulative)', () {
    // 5 km in 1700 s vs a 1500 s PB: 40 s/km of cumulative gap.
    final splits = computeSplits(
      activity: activityOf(5000, 1700, track: _track(5000, 1700)),
      route: _route(pbSeconds: 1500),
      trackMeters: 5000,
    );
    expect(splits, hasLength(5));
    for (final split in splits) {
      expect(split.deltaSeconds, greaterThan(0),
          reason: 'km ${split.kilometer}');
      expect(split.deltaSeconds, closeTo(40 * split.kilometer, 5));
    }
  });

  test('a faster-than-PB run is ahead on every split', () {
    final splits = computeSplits(
      activity: activityOf(5000, 1300, track: _track(5000, 1300)),
      route: _route(pbSeconds: 1500),
      trackMeters: 5000,
    );
    expect(splits, hasLength(5));
    for (final split in splits) {
      expect(split.deltaSeconds, lessThan(0));
    }
  });

  test('a partial run only reports completed kilometers', () {
    // 2.4 km covered in 800 s.
    final splits = computeSplits(
      activity: activityOf(2400, 800, track: _track(2400, 800)),
      route: _route(pbSeconds: 1500),
      trackMeters: 2400,
    );
    expect(splits, hasLength(2)); // km 1 and km 2 only.
    expect(splits.last.kilometer, 2);
  });
}