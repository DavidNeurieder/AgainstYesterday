// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Deterministic [`EngineService`] used before the Rust bridge (M4).
///
/// Generates tracks from a fixed, seeded pseudo-random generator so every run
/// of the app (and every test) sees identical data. The fake exists purely to
/// let the UI be built independently — it must never become a second
/// implementation of the real matching logic.
library;

import 'dart:math' as math;

import '../core/units.dart';
import 'engine_service.dart';
import 'models.dart';

/// A deterministic fake of the Rust GPS engine (M4).
///
/// All generated recordings follow one shared "river loop" route so matching
/// results stay sensible and repeatable. Numerically this is a demo
/// approximation, never a replacement for the real engine.
class FakeEngineService implements EngineService {
  FakeEngineService({int seed = 42}) : _random = _SeededRandom(seed);

  final _SeededRandom _random;

  @override
  String get engineDescription => 'fake (deterministic demo)';

  /// The canonical ~4.8 km river loop every fake recording follows.
  static const List<GeoPoint> riverLoop = <GeoPoint>[
    GeoPoint(latitude: 52.5050, longitude: 13.3600),
    GeoPoint(latitude: 52.5095, longitude: 13.3660),
    GeoPoint(latitude: 52.5105, longitude: 13.3760),
    GeoPoint(latitude: 52.5065, longitude: 13.3840),
    GeoPoint(latitude: 52.5000, longitude: 13.3820),
    GeoPoint(latitude: 52.4980, longitude: 13.3720),
    GeoPoint(latitude: 52.5000, longitude: 13.3620),
    GeoPoint(latitude: 52.5050, longitude: 13.3600),
  ];

  static const String riverLoopId = 'river-loop';

  /// Generates a deterministic recording of the river loop.
  @override
  List<TrackPoint> generateRecording({
    double noiseMeters = 2.0,
    double speedMetersPerSecond = 2.5,
    double sampleEverySeconds = 1.0,
  }) {
    final step = speedMetersPerSecond * sampleEverySeconds;
    final route = _resample(riverLoop, step);
    final start = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final points = <TrackPoint>[];
    for (var i = 0; i < route.length; i++) {
      final position = _jitter(route[i], noiseMeters);
      final elapsedMs = (i * sampleEverySeconds * 1000).round();
      points.add(
        TrackPoint(
          position: position,
          timestamp: start.add(Duration(milliseconds: elapsedMs)),
        ),
      );
    }
    return points;
  }

  @override
  Future<ProcessedTrack> processTrack({
    required String id,
    required List<TrackPoint> points,
  }) async {
    final cleaned = _dedupe(points);
    final resampled = _resample(
      cleaned.map((p) => p.position).toList(growable: false),
      25.0,
    );
    final elapsed = Elapsed.seconds(
      points.isEmpty
          ? 0
          : points.last.timestamp.difference(points.first.timestamp).inSeconds
              .toDouble(),
    );
    return ProcessedTrack(
      id: id,
      inputPoints: points.length,
      outputPoints: resampled.length,
      originalDistance: Distance.meters(polylineMeters(
        points.map((p) => p.position).toList(growable: false),
      )),
      processedDistance: Distance.meters(polylineMeters(resampled)),
      duration: elapsed,
      movingTime: elapsed,
    );
  }

  @override
  Future<RouteMatchResult> matchRoutes({
    required List<TrackPoint> a,
    required List<TrackPoint> b,
  }) async {
    final geometryA = _resample(
      a.map((p) => p.position).toList(growable: false),
      25.0,
    );
    final geometryB = _resample(
      b.map((p) => p.position).toList(growable: false),
      25.0,
    );

    // Overlap: fraction of each geometry within 25 m of the other (min).
    final nearFraction = math.min(
      _nearFraction(geometryA, geometryB),
      _nearFraction(geometryB, geometryA),
    );
    final startM = a.isEmpty || b.isEmpty
        ? 0.0
        : haversineMeters(a.first.position, b.first.position);
    final endM = a.isEmpty || b.isEmpty
        ? 0.0
        : haversineMeters(a.last.position, b.last.position);

    final score = MatchScore(
      startDistance: Distance.meters(startM),
      endDistance: Distance.meters(endM),
      distanceRatio: polylineMeters(geometryA) /
          (polylineMeters(geometryB) <= 0 ? 1 : polylineMeters(geometryB)),
      spatialOverlap: nearFraction,
      directionSimilarity: nearFraction, // demo proxy
      overallScore: 0.4 * nearFraction +
          0.25 * nearFraction +
          0.20 * _clamp01(1 - startM / 150) +
          0.15 * _clamp01(1 - endM / 150),
    );
    return RouteMatchResult(
      score: score,
      sameRoute: score.spatialOverlap >= 0.6,
    );
  }

  @override
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
  }) async {
    final cleaned = _dedupe(points);
    final route = _resample(routeGeometry, 25.0);
    final samples = <AttemptSample>[];
    var previousIndex = 0;
    double lastElapsedSeconds = 0;

    for (var i = 1; i < route.length; i++) {
      final index = _nearestIndex(cleaned, route[i]);
      if (index == null || index < previousIndex) {
        continue; // skip backtracking artifacts
      }
      previousIndex = index;
      lastElapsedSeconds = cleaned[index]
              .timestamp
              .difference(cleaned.first.timestamp)
              .inMilliseconds /
          1000.0;
      samples.add(
        AttemptSample(
          distance: Distance.meters(polylineMeters(route.sublist(0, i))),
          elapsed: Elapsed.seconds(lastElapsedSeconds),
        ),
      );
    }

    return Attempt(
      activityId: activityId,
      routeId: routeId,
      elapsed: Elapsed.seconds(lastElapsedSeconds),
      samples: samples,
    );
  }

  @override
  Future<List<RouteSegmentComparison>> compareRouteSegments({
    required List<Attempt> attempts,
    required double segmentDistanceMeters,
    required double routeDistanceMeters,
  }) async {
    if (attempts.isEmpty) return const [];
    if (segmentDistanceMeters <= 0 || routeDistanceMeters <= 0) return const [];

    final perAttempt = <List<RouteSegment>>[];
    for (final a in attempts) {
      perAttempt.add(_routeSegments(a, segmentDistanceMeters, routeDistanceMeters));
    }
    final sectionCount = perAttempt.first.length;
    final result = <RouteSegmentComparison>[];
    for (var i = 0; i < sectionCount; i++) {
      final segs = <RouteSegment>[for (final v in perAttempt) v[i]];
      double minSpeed = 0, maxSpeed = 0, sum = 0;
      var count = 0;
      var first = true;
      for (final s in segs) {
        if (s.durationSeconds <= 0) continue;
        if (first) {
          minSpeed = s.averageSpeedMps;
          maxSpeed = s.averageSpeedMps;
          first = false;
        } else {
          if (s.averageSpeedMps < minSpeed) minSpeed = s.averageSpeedMps;
          if (s.averageSpeedMps > maxSpeed) maxSpeed = s.averageSpeedMps;
        }
        sum += s.averageSpeedMps;
        count++;
      }
      if (count == 0) {
        minSpeed = 0;
        maxSpeed = 0;
      }
      result.add(RouteSegmentComparison(
        index: i,
        startDistanceM: segs.first.startDistanceM,
        endDistanceM: segs.first.endDistanceM,
        segments: segs,
        minSpeedMps: minSpeed,
        maxSpeedMps: maxSpeed,
        meanSpeedMps: count > 0 ? sum / count : 0,
        speedSpreadMps: count > 0 ? (maxSpeed - minSpeed) : 0,
      ));
    }
    return result;
  }

  List<RouteSegment> _routeSegments(
    Attempt attempt,
    double segmentDistance,
    double routeDistance,
  ) {
    final n = (routeDistance / segmentDistance).ceil().clamp(1, 1 << 30);
    final out = <RouteSegment>[];
    for (var i = 0; i < n; i++) {
      final start = i * segmentDistance;
      final end = ((i + 1) * segmentDistance).clamp(0.0, routeDistance);
      if (start >= routeDistance) break;
      final coveredEnd = end.clamp(0.0, attempt.samples.isEmpty ? 0.0 : attempt.samples.last.distance.meters);
      final complete = (attempt.samples.isEmpty ? 0.0 : attempt.samples.last.distance.meters) >= end - 1e-9;
      double duration = 0;
      if (start < (attempt.samples.isEmpty ? 0.0 : attempt.samples.last.distance.meters)) {
        final tStart = _timeAt(attempt.samples, start) ?? 0;
        final tEnd = _timeAt(attempt.samples, coveredEnd) ?? tStart;
        duration = (tEnd - tStart).clamp(0, double.infinity);
      }
      final covered = (coveredEnd - start).clamp(0.0, double.infinity);
      final speed = duration > 0 ? covered / duration : 0.0;
      out.add(RouteSegment(
        index: i,
        startDistanceM: start,
        endDistanceM: end,
        durationSeconds: duration,
        averageSpeedMps: speed,
        complete: complete,
      ));
    }
    return out;
  }

  double? _timeAt(List<AttemptSample> samples, double distance) {
    if (samples.isEmpty) return null;
    if (distance <= 0) return 0;
    final last = samples.last;
    if (distance > last.distance.meters) return null;
    if (distance == last.distance.meters) return last.elapsed.seconds;
    // find j
    int j = -1;
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].distance.meters >= distance) {
        j = i;
        break;
      }
    }
    if (j < 0) return null;
    if (j == 0) {
      if (samples[0].distance.meters == distance) return samples[0].elapsed.seconds;
      return null;
    }
    if (samples[j].distance.meters == distance) return samples[j].elapsed.seconds;
    final a = samples[j - 1];
    final b = samples[j];
    final d0 = a.distance.meters;
    final d1 = b.distance.meters;
    if (d1 <= d0) return b.elapsed.seconds;
    final frac = (distance - d0) / (d1 - d0);
    return a.elapsed.seconds + frac * (b.elapsed.seconds - a.elapsed.seconds);
  }

  @override
  GhostState ghostStateAt({
    required Ghost ghost,
    required Attempt current,
    required Distance distance,
  }) {
    final reference = _sampleAt(ghost.samples, distance);
    final live = _sampleAt(current.samples, distance);
    if (reference == null || live == null) {
      return GhostState(
        distance: distance,
        timeDifference: Elapsed.zero(),
        ahead: false,
      );
    }
    final difference =
        Elapsed.seconds(live.elapsed.seconds - reference.elapsed.seconds);
    return GhostState(
      distance: distance,
      timeDifference: difference,
      ahead: difference.seconds <= 0,
    );
  }

  @override
  GhostState liveGhostGap({
    required Ghost ghost,
    required double distanceM,
    required double movingSeconds,
    required double loopLengthM,
  }) {
    final liveTime = movingSeconds;
    final reference = _referenceTimeAt(ghost.samples, distanceM);
    final difference = Elapsed.seconds(liveTime - reference);
    return GhostState(
      distance: Distance.meters(distanceM),
      timeDifference: difference,
      ahead: difference.seconds < 0,
    );
  }

  double _referenceTimeAt(List<AttemptSample> samples, double distanceM) {
    if (samples.isEmpty) return 0;
    if (distanceM <= samples.first.distance.meters) {
      return samples.first.elapsed.seconds;
    }
    for (var i = 1; i < samples.length; i++) {
      if (distanceM <= samples[i].distance.meters) {
        final a = samples[i - 1];
        final b = samples[i];
        final span = b.distance.meters - a.distance.meters;
        final fraction = span <= 0 ? 0.0 : (distanceM - a.distance.meters) / span;
        return a.elapsed.seconds + (b.elapsed.seconds - a.elapsed.seconds) * fraction;
      }
    }
    return samples.last.elapsed.seconds;
  }
  double _nearFraction(List<GeoPoint> geometry, List<GeoPoint> other) {
    if (geometry.isEmpty || other.length < 2) {
      return 0.0;
    }
    var near = 0;
    for (final p in geometry) {
      final d = _distanceToPolyline(p, other);
      if (d <= 25.0) {
        near++;
      }
    }
    return near / geometry.length;
  }

  double _distanceToPolyline(GeoPoint p, List<GeoPoint> polyline) {
    var best = double.infinity;
    for (var i = 1; i < polyline.length; i++) {
      final d = _distanceToSegment(p, polyline[i - 1], polyline[i]);
      if (d < best) {
        best = d;
      }
    }
    return best;
  }

  double _distanceToSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    final lenSq = dx * dx + dy * dy;
    final t = lenSq == 0
        ? 0.0
        : (((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) /
                lenSq)
            .clamp(0.0, 1.0);
    final projection = GeoPoint(
      latitude: a.latitude + t * dx,
      longitude: a.longitude + t * dy,
    );
    return haversineMeters(p, projection);
  }

  int? _nearestIndex(List<TrackPoint> points, GeoPoint target) {
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = haversineMeters(points[i].position, target);
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best < 0 ? null : best;
  }

  AttemptSample? _sampleAt(List<AttemptSample> samples, Distance distance) {
    if (samples.isEmpty) {
      return null;
    }
    if (distance.meters <= samples.first.distance.meters) {
      return samples.first;
    }
    for (var i = 1; i < samples.length; i++) {
      if (distance.meters <= samples[i].distance.meters) {
        return samples[i - 1];
      }
    }
    return samples.last;
  }

  /// Drops points closer than 0.5 m to the previous kept point.
  List<TrackPoint> _dedupe(List<TrackPoint> points) {
    final result = <TrackPoint>[];
    for (final p in points) {
      if (result.isEmpty ||
          haversineMeters(result.last.position, p.position) > 0.5) {
        result.add(p);
      }
    }
    return result;
  }

  /// Uniformly samples the geometry to points ~[stepM] apart, preserving the
  /// first and last points exactly.
  List<GeoPoint> _resample(List<GeoPoint> points, double stepM) {
    if (points.length < 2 || stepM <= 0) {
      return List.of(points);
    }
    final result = <GeoPoint>[points.first];
    var nextEmit = stepM; // distance from the polyline start to the next point
    var advance = 0.0; // distance walked along the polyline
    for (var i = 1; i < points.length; i++) {
      final segment = haversineMeters(points[i - 1], points[i]);
      while (nextEmit <= advance + segment) {
        final t = (nextEmit - advance) / segment;
        if (t.isFinite && t >= 0.0 && t <= 1.0) {
          result.add(
            GeoPoint(
              latitude: points[i - 1].latitude +
                  (points[i].latitude - points[i - 1].latitude) * t,
              longitude: points[i - 1].longitude +
                  (points[i].longitude - points[i - 1].longitude) * t,
            ),
          );
        }
        nextEmit += stepM;
      }
      advance += segment;
    }
    if (result.last != points.last) {
      result.add(points.last);
    }
    return result;
  }

  GeoPoint _jitter(GeoPoint p, double meters) {
    if (meters <= 0) {
      return p;
    }
    final angle = _random.nextDouble() * 6.283185307179586;
    final radius = meters * _random.nextDouble();
    final dLat = (radius * math.cos(angle)) / 111_320.0;
    final dLon = (radius * math.sin(angle)) /
        (111_320.0 * math.cos(p.latitude * 3.141592653589793 / 180.0));
    return GeoPoint(latitude: p.latitude + dLat, longitude: p.longitude + dLon);
  }

  double _clamp01(double v) => v.clamp(0.0, 1.0);
}

/// Minimal deterministic PRNG (LCG) so fake data is reproducible.
class _SeededRandom {
  _SeededRandom(int seed) : _state = seed & 0x7fffffff;

  int _state;

  double nextDouble() {
    // Numerical Recipes LCG.
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}