// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Builds the reference ghost (PB) attempt samples for racing/replay.
///
/// Uses the fastest saved activity's track on a moving-time axis when
/// available, falling back to a constant-pace analytic ghost. The fallback
/// always calls [EngineService.createAttempt] so injected test failures remain
/// observable — the same behavior live recording relies on.
library;

import '../../../core/units.dart';
import '../../../engine/engine_service.dart';
import '../../../engine/models.dart';

const double kGhostBaseSpeedMps = 1000.0 / 297.0;

/// Builds ghost samples for [route]'s [pb]. [fastestActivity], when it has a
/// usable track, produces a real PB profile; otherwise an analytic constant-
/// pace ghost is generated.
Future<List<AttemptSample>> buildGhostSamples({
  required EngineService engine,
  required Route route,
  required Elapsed pb,
  required Activity? fastestActivity,
  double baseSpeedMps = kGhostBaseSpeedMps,
}) async {
  final track = fastestActivity?.track;
  if (track != null && track.length >= 2) {
    try {
      final attempt = await engine.createAttempt(
        activityId: 'ghost-${route.id}',
        routeId: route.id,
        points: track,
        routeGeometry: route.geometry,
        movingTime: true,
      );
      if (attempt.samples.isNotEmpty) return attempt.samples;
    } catch (_) {
      // Fall through to the analytic profile, which still exercises
      // createAttempt so injected failures remain observable.
    }
  }

  final length = polylineMeters(route.geometry);
  final speed = pb.seconds > 0 ? length / pb.seconds : baseSpeedMps;
  final recording = engine.generateRecording(
    noiseMeters: 1.0,
    speedMetersPerSecond: speed,
    sampleEverySeconds: 1.0,
  );
  final attempt = await engine.createAttempt(
    activityId: 'ghost-${route.id}',
    routeId: route.id,
    points: recording,
    routeGeometry: route.geometry,
    movingTime: false,
  );
  return attempt.samples;
}

/// The fastest (shortest moving-time) activity recorded on [routeId], or null.
Activity? fastestActivityForRoute(List<Activity> activities, String routeId) {
  Activity? best;
  for (final a in activities) {
    if (a.routeId != routeId) continue;
    if (a.duration == null) continue;
    if (best == null || a.duration!.seconds < best.duration!.seconds) {
      best = a;
    }
  }
  return best;
}
