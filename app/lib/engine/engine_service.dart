// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The engine facade — the only thing Flutter features may talk to (§6).
///
/// The rest of the app depends on this abstract interface and never on raw
/// FFI calls or on the concrete implementation. Two implementations exist:
///
/// - [`FakeEngineService`] (see `fake_engine.dart`) — deterministic, used for
///   UI development before the Rust bridge is wired up (M4).
/// - `RustEngineService` (planned M9) — calls the Rust engine through FFI.
library;

import '../core/units.dart';
import 'models.dart';

abstract class EngineService {
  /// Human-readable engine identity for the developer diagnostics screen
  /// (M15 Phase 10): e.g. `fake` or `rust v0.1.0`.
  String get engineDescription;

  /// Cleans a recording into a processed track summary.
  Future<ProcessedTrack> processTrack({
    required String id,
    required List<TrackPoint> points,
  });

  /// Whether two recordings are the same route, with diagnostics.
  Future<RouteMatchResult> matchRoutes({
    required List<TrackPoint> a,
    required List<TrackPoint> b,
  });

  /// Reduces a recording onto the route distance axis.
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
    bool movingTime = false,
  });

  /// Raw geodesic length and duration of a point sequence, with no filtering.
  Future<({double lengthMeters, double durationSeconds})> routeInfo({
    required List<TrackPoint> points,
  });

  /// Derived track analytics for [points], computed by the engine.
  Future<TrackAnalytics> analyzeTrack({
    required List<TrackPoint> points,
  });

  /// Creates a stateful live recorder owned by the engine.
  ///
  /// Pass [route] to follow a recognised course (coverage/progress/off-route
  /// are computed against it) or `null` for a free run. [ghostSamples], when
  /// present, are the reference PB attempt's `(distance, elapsed)` samples.
  Future<LiveRunHandle> createLiveRun({
    List<GeoPoint>? route,
    List<AttemptSample>? ghostSamples,
  });

  /// Creates a replay session over recorded raw fixes. [routeGeometry], when
  /// present, enables route-aware progress/matching through the engine.
  /// [ghostSamples], when present, drive the ahead/behind comparison.
  Future<ReplayHandle> createReplay({
    required List<GpsFix> fixes,
    List<GeoPoint>? routeGeometry,
    List<AttemptSample>? ghostSamples,
  });

  /// Live ghost state at a given distance along the route.
  GhostState ghostStateAt({
    required Ghost ghost,
    required Attempt current,
    required Distance distance,
  });

  /// Live-run gap estimate for an in-progress run.
  GhostState liveGhostGap({
    required Ghost ghost,
    required double distanceM,
    required double movingSeconds,
    required double loopLengthM,
  });

  /// Compares attempts section-by-section along a canonical route.
  Future<List<RouteSegmentComparison>> compareRouteSegments({
    required List<Attempt> attempts,
    required double segmentDistanceMeters,
    required double routeDistanceMeters,
  });

  ///
  /// The ghost is built from a PB attempt walked at constant speed, so the
  /// engine can produce that timeline purely from geometry (no device GPS).
  /// M4's fake engine and M9's Rust engine both implement it; the app never
  /// reads raw GPS here.
  List<TrackPoint> generateRecording({
    double noiseMeters = 2.0,
    double speedMetersPerSecond = 2.5,
    double sampleEverySeconds = 1.0,
  });
}
