// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Named, deterministic GPS fixtures for the device-mode tests (test plan
/// Phase 1).
///
/// A fixture is a scripted receiver timeline plus its independently-known
/// expectations, so a test reads as the scenario it models instead of a pile
/// of `stream.add` calls. Expected distances are derived here from the
/// spherical-earth formulas (meridian/zonal), *not* from the production
/// `haversineMeters`, so a regression in the geometry helper cannot move the
/// goalposts with it.
///
/// Drive a fixture either wholesale with [ScriptedGpsSource.replay] or sample
/// by sample with [ScriptedGpsSource.emit] when the test needs to observe the
/// gap between fixes (an outage, a duplicate timestamp).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';

import 'package:against_yesterday/engine/device_gps_source.dart';
import 'package:against_yesterday/engine/models.dart';

const double _earthRadiusM = 6371000.0;

/// Great-circle north–south distance for [deltaLatDegrees] of latitude.
double _meridianMeters(double deltaLatDegrees) =>
    _earthRadiusM * (deltaLatDegrees.abs() * math.pi / 180.0);

/// Great-circle east–west distance for [deltaLonDegrees] of longitude at
/// [latDegrees] (small-angle approximation the real receiver sees).
double _zonalMeters(double latDegrees, double deltaLonDegrees) =>
    _earthRadiusM *
    math.cos(latDegrees * math.pi / 180.0) *
    (deltaLonDegrees.abs() * math.pi / 180.0);

/// One scripted receiver observation.
class GpsSample {
  const GpsSample({
    required this.after,
    required this.position,
    this.speedMetersPerSecond,
    this.accuracyMeters = 3.0,
    this.altitudeMeters = 55.0,
    this.bearingDegrees,
    this.clockOffset,
  });

  /// Wall-clock delay from the previous sample (the first is measured from
  /// START), applied before this fix lands.
  final Duration after;

  final GeoPoint position;

  /// The receiver's reported speed; `null` exercises the ground-distance path.
  final double? speedMetersPerSecond;

  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? bearingDegrees;

  /// Shifts the emitted timestamp relative to the current clock. A negative
  /// value models a stale cached fix or a duplicate timestamp.
  final Duration? clockOffset;

  GpsFix toFix(DateTime now) => GpsFix(
        timestamp: now.add(clockOffset ?? Duration.zero).toUtc(),
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: accuracyMeters,
        altitudeMeters: altitudeMeters,
        speedMetersPerSecond: speedMetersPerSecond,
        bearingDegrees: bearingDegrees,
      );
}

/// A named receiver timeline and its expectations.
class GpsScenario {
  const GpsScenario({
    required this.name,
    required this.samples,
    this.expectedDistanceMeters,
    this.expectedAcceptedFixes,
  });

  final String name;
  final List<GpsSample> samples;

  /// Ground length the run must accumulate, in meters, when known.
  final double? expectedDistanceMeters;

  /// How many fixes (beyond the first anchor) must clear the motion floor.
  final int? expectedAcceptedFixes;
}

/// A parked phone: one repeated fix carrying a stale cruising speed. The
/// receiver insists it is moving; the ground says otherwise.
const GpsScenario stationary = GpsScenario(
  name: 'stationary',
  expectedDistanceMeters: 0,
  expectedAcceptedFixes: 0,
  samples: [
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      speedMetersPerSecond: 3.5,
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      speedMetersPerSecond: 3.5,
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      speedMetersPerSecond: 3.5,
    ),
  ],
);

/// Sub-meter jitter around a fixed point with no reported speed: each step is
/// far below the 0.5 m/s motion floor, so none of it may accumulate.
const GpsScenario noisyStationary = GpsScenario(
  name: 'noisy_stationary',
  expectedDistanceMeters: 0,
  expectedAcceptedFixes: 0,
  samples: [
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.500000, longitude: 13.400000),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.500002, longitude: 13.400001),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.499999, longitude: 13.400000),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.500001, longitude: 13.399998),
    ),
  ],
);

/// The same coordinate repeated: a duplicate fix must not add distance.
const GpsScenario duplicateFixes = GpsScenario(
  name: 'duplicate_fixes',
  expectedDistanceMeters: 0,
  expectedAcceptedFixes: 0,
  samples: [
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
  ],
);

/// A second fix carrying the *same* timestamp as the first: a zero delta can
/// never prove motion, so the coordinate change adds nothing.
final GpsScenario duplicateTimestamps = GpsScenario(
  name: 'duplicate_timestamps',
  expectedDistanceMeters: 0,
  expectedAcceptedFixes: 0,
  samples: const [
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
      clockOffset: Duration(seconds: -1),
    ),
  ],
);

/// A straight northward walk, 0.004° of latitude (≈ 444.8 m) in five fixes.
final GpsScenario straightWalk = GpsScenario(
  name: 'straight_walk',
  expectedDistanceMeters: _meridianMeters(0.004),
  expectedAcceptedFixes: 4,
  samples: const [
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5020, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5030, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5040, longitude: 13.4000),
    ),
  ],
);

/// An L-shaped walk: one meridional leg then one zonal leg, so the accumulated
/// distance must sum both independently-known legs.
final GpsScenario multiSegment = GpsScenario(
  name: 'multi_segment_route',
  expectedDistanceMeters:
      _meridianMeters(0.001) + _zonalMeters(52.5010, 0.001),
  expectedAcceptedFixes: 2,
  samples: const [
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4010),
    ),
  ],
);

/// A real walk reported with 50 m accuracy: the movement still counts, but the
/// readout must flag the fix as poor (§17).
final GpsScenario poorAccuracy = GpsScenario(
  name: 'poor_accuracy',
  expectedDistanceMeters: _meridianMeters(0.002),
  expectedAcceptedFixes: 2,
  samples: const [
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      accuracyMeters: 50,
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
      accuracyMeters: 50,
    ),
    GpsSample(
      after: Duration(seconds: 10),
      position: GeoPoint(latitude: 52.5020, longitude: 13.4000),
      accuracyMeters: 50,
    ),
  ],
);

/// Two fixes, a 30 s hole with no fix at all, then two fixes again.
const GpsScenario gpsOutage = GpsScenario(
  name: 'gps_outage',
  samples: [
    GpsSample(
      after: Duration(seconds: 5),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 5),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
    ),
    // The receiver drops out: the next fix is 30 s later.
    GpsSample(
      after: Duration(seconds: 30),
      position: GeoPoint(latitude: 52.5020, longitude: 13.4000),
    ),
    GpsSample(
      after: Duration(seconds: 5),
      position: GeoPoint(latitude: 52.5030, longitude: 13.4000),
    ),
  ],
);

/// A cached initial fix timestamped 30 s in the past, then fresh fixes: the
/// stale sample must not be read as movement back at the start line.
final GpsScenario staleInitialFix = GpsScenario(
  name: 'stale_initial_fix',
  samples: const [
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      speedMetersPerSecond: 3.0,
      clockOffset: Duration(seconds: -30),
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
      speedMetersPerSecond: 3.0,
    ),
    GpsSample(
      after: Duration(seconds: 1),
      position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
      speedMetersPerSecond: 3.0,
    ),
  ],
);

/// A long but straight session: the accumulated distance must stay the exact
/// sum of its steps with no progressive drift.
GpsScenario longSession({int fixes = 200, double stepMeters = 5}) {
  const baseLat = 52.5000;
  const lon = 13.4000;
  return GpsScenario(
    name: 'long_session',
    expectedDistanceMeters: (fixes - 1) * stepMeters,
    expectedAcceptedFixes: fixes - 1,
    samples: [
      for (var i = 0; i < fixes; i++)
        GpsSample(
          after: const Duration(seconds: 2),
          position: GeoPoint(
            latitude: baseLat + i * stepMeters / 111195.0,
            longitude: lon,
          ),
        ),
    ],
  );
}

/// A deterministic [GpsSource] playing a [GpsScenario] into the recording.
class ScriptedGpsSource implements GpsSource {
  ScriptedGpsSource({
    this.acquisition,
    this.description = 'scripted test GPS',
  });

  /// `null` accepts acquisition; anything else is the refusal reason.
  final String? acquisition;

  @override
  final String description;

  final StreamController<GpsFix> _controller =
      StreamController<GpsFix>.broadcast();

  int settingsOpened = 0;

  @override
  Future<String?> ensureAvailable() async => acquisition;

  @override
  Stream<GpsFix> fixes() => _controller.stream;

  @override
  Future<void> openSettings() async {
    settingsOpened++;
  }

  /// Emits one already-built fix.
  void emit(GpsFix fix) => _controller.add(fix);

  /// Replays [scenario] on the fake clock: each sample elapses its own delay,
  /// then lands as a fix timestamped with the then-current clock.
  void replay(FakeAsync async, GpsScenario scenario) {
    for (final sample in scenario.samples) {
      async.elapse(sample.after);
      emit(sample.toFix(clock.now()));
      async.flushMicrotasks();
    }
  }

  Future<void> close() => _controller.close();
}
