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
  });

  /// Live ghost state at a given distance along the route.
  GhostState ghostStateAt({
    required Ghost ghost,
    required Attempt current,
    required Distance distance,
  });

  /// Deterministically synthesizes a recording of the shared demo loop.
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