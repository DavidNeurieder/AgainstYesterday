// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The online engine-filter mirror (`TrackFilter`).
///
/// These pin the rule the live free-run distance follows: a teleport between
/// clusters survives (the engine's `distance_after` keeps the chord) while an
/// isolated spike and sensor junk do not. Expected lengths are computed here
/// from the meridional formula, never from the production geometry helper.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/engine/track_filter.dart';

/// Metres per degree of latitude used by the fixtures (1° ≈ 111.195 km).
const _metersPerDegree = 111195.0;

GpsFix _fix(double lat, double lon, {required int atSecond, double? accuracy}) =>
    GpsFix(
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, atSecond),
      latitude: lat,
      longitude: lon,
      accuracyMeters: accuracy,
    );

void main() {
  test('a teleport between clusters is bridged, not stalled', () {
    // The Hausrunde shape: short clusters of jitter joined by big jumps that
    // the receiver only reported on arrival. The old live guard read the first
    // jump as a spike, kept its anchor, and then stalled every later fix — a
    // 2.8 km track collapsed to a few metres.
    const base = 52.50000;
    final fixes = [
      _fix(base, 13.40000, atSecond: 1), // cluster A
      _fix(base + 0.00002, 13.40000, atSecond: 2),
      _fix(base + 0.00200, 13.40000, atSecond: 3), // teleport to cluster B
      _fix(base + 0.00202, 13.40000, atSecond: 4),
      _fix(base + 0.01000, 13.40000, atSecond: 9), // teleport to cluster C
      _fix(base + 0.01002, 13.40000, atSecond: 10),
    ];
    final filter = TrackFilter();
    for (final fix in fixes) {
      filter.add(fix);
    }

    // Every point survives (no isolated spike), so the filtered length equals
    // the full polyline: the net meridional span, 2.2 + 220.2 + 2.2 + 887.3 +
    // 2.2 m.
    const expected = 0.01002 * _metersPerDegree;
    expect(filter.distanceMeters, closeTo(expected, 1.0));
  });

  test('an isolated spike is dropped and the anchor holds', () {
    final filter = TrackFilter();
    filter.add(_fix(52.50000, 13.40000, atSecond: 1));
    filter.add(_fix(52.50100, 13.40000, atSecond: 11)); // real stride
    filter.add(_fix(52.50100, 13.41000, atSecond: 21)); // ~680 m spike
    filter.add(_fix(52.50200, 13.40000, atSecond: 31)); // back on the line

    // Two real 111 m strides: the spike's both-side jumps drop it and the last
    // fix is measured from the last trusted position.
    expect(filter.distanceMeters, closeTo(2 * 0.001 * _metersPerDegree, 1.0));
  });

  test('a fix the sensor rejects neither bridges nor breaks the chain', () {
    for (final bad in [
      _fix(52.50010, 13.40000, atSecond: 2, accuracy: 80), // > 50 m accuracy
      GpsFix(
        timestamp: DateTime.utc(2026, 1, 1, 10, 0, 2),
        latitude: 52.50010,
        longitude: 13.40000,
        speedMetersPerSecond: 40, // > 25 m/s reported
      ),
    ]) {
      final filter = TrackFilter();
      filter.add(_fix(52.50000, 13.40000, atSecond: 1));
      filter.add(bad);
      filter.add(_fix(52.50002, 13.40000, atSecond: 3));
      // The junk fix is invisible: the two good fixes connect directly.
      expect(filter.distanceMeters, closeTo(0.00002 * _metersPerDegree, 1.0));
    }
  });

  test('sub-floor jitter earns no distance', () {
    final filter = TrackFilter();
    // ~0.2 m/s drift: below the 0.5 m/s motion floor.
    filter.add(_fix(52.50000, 13.40000, atSecond: 1));
    filter.add(_fix(52.50000, 13.400003, atSecond: 2));
    filter.add(_fix(52.50000, 13.400006, atSecond: 3));
    expect(filter.distanceMeters, 0);
  });

  test('a speed spike is withheld until the next fix refutes it', () {
    final filter = TrackFilter();
    filter.add(_fix(52.50000, 13.40000, atSecond: 1));
    filter.add(_fix(52.50100, 13.40000, atSecond: 11));
    // The ~680 m spike (68 m/s) is withheld, so the axis does not overshoot.
    filter.add(_fix(52.50100, 13.41000, atSecond: 21));
    expect(filter.distanceMeters, closeTo(0.001 * _metersPerDegree, 1.0));
    // Back on the line: the spike is retracted and the real stride lands.
    filter.add(_fix(52.50200, 13.40000, atSecond: 31));
    expect(filter.distanceMeters, closeTo(2 * 0.001 * _metersPerDegree, 1.0));
  });

  test('flush keeps the final point even when its step looked like a spike', () {
    final filter = TrackFilter();
    filter.add(_fix(52.50000, 13.40000, atSecond: 1));
    filter.add(_fix(52.50200, 13.40000, atSecond: 3)); // a lone 111 m/s jump
    expect(filter.distanceMeters, 0); // withheld for want of an outgoing step
    filter.flush();
    expect(filter.distanceMeters, closeTo(0.002 * _metersPerDegree, 1.0));
  });
}
