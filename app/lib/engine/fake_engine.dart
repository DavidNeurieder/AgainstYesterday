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
          : points.last.timestamp
                .difference(points.first.timestamp)
                .inSeconds
                .toDouble(),
    );
    return ProcessedTrack(
      id: id,
      inputPoints: points.length,
      outputPoints: resampled.length,
      originalDistance: Distance.meters(
        polylineMeters(points.map((p) => p.position).toList(growable: false)),
      ),
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
      distanceRatio:
          polylineMeters(geometryA) /
          (polylineMeters(geometryB) <= 0 ? 1 : polylineMeters(geometryB)),
      spatialOverlap: nearFraction,
      directionSimilarity: nearFraction, // demo proxy
      overallScore:
          0.4 * nearFraction +
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
    bool movingTime = false,
  }) async {
    final cleaned = _dedupe(points);
    final route = _resample(routeGeometry, 25.0);
    final samples = <AttemptSample>[];
    var previousIndex = 0;
    double elapsedSeconds = 0;

    for (var i = 1; i < route.length; i++) {
      final index = _nearestIndex(cleaned, route[i]);
      if (index == null || index < previousIndex) {
        continue;
      }
      if (movingTime) {
        for (var j = math.max(1, previousIndex); j <= index; j++) {
          elapsedSeconds += _movingDt(cleaned[j - 1], cleaned[j]);
        }
      } else {
        elapsedSeconds =
            cleaned[index].timestamp
                .difference(cleaned.first.timestamp)
                .inMilliseconds /
            1000.0;
      }
      previousIndex = index;
      samples.add(
        AttemptSample(
          distance: Distance.meters(polylineMeters(route.sublist(0, i))),
          elapsed: Elapsed.seconds(elapsedSeconds),
        ),
      );
    }

    return Attempt(
      activityId: activityId,
      routeId: routeId,
      elapsed: Elapsed.seconds(elapsedSeconds),
      samples: samples,
    );
  }

  double _movingDt(TrackPoint a, TrackPoint b) {
    final dt = b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
    if (dt <= 0) return 0;
    if (dt < 5.0) return dt;
    final speed = haversineMeters(a.position, b.position) / dt;
    return speed >= 0.5 ? dt : 0;
  }

  @override
  Future<({double lengthMeters, double durationSeconds})> routeInfo({
    required List<TrackPoint> points,
  }) async {
    final coords = points.map((p) => p.position).toList(growable: false);
    final duration = points.length < 2
        ? 0.0
        : points.last.timestamp
                  .difference(points.first.timestamp)
                  .inMilliseconds /
              1000.0;
    return (lengthMeters: polylineMeters(coords), durationSeconds: duration);
  }

  @override
  Future<TrackAnalytics> analyzeTrack({
    required List<TrackPoint> points,
  }) async {
    final coords = points.map((p) => p.position).toList(growable: false);
    final distance = polylineMeters(coords);
    final elapsed = points.length < 2
        ? 0.0
        : points.last.timestamp
                .difference(points.first.timestamp)
                .inMilliseconds /
            1000.0;
    var moving = 0.0;
    for (var i = 1; i < points.length; i++) {
      final dt =
          points[i].timestamp.difference(points[i - 1].timestamp).inMilliseconds /
          1000.0;
      if (dt <= 0) continue;
      if (dt < 5.0) {
        moving += dt;
        continue;
      }
      final speed = haversineMeters(points[i - 1].position, points[i].position) / dt;
      if (speed >= 0.5) moving += dt;
    }
    final paused = (elapsed - moving).clamp(0.0, double.infinity);
    var gain = 0.0;
    var loss = 0.0;
    double? minAlt;
    double? maxAlt;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1].altitudeMeters;
      final b = points[i].altitudeMeters;
      if (a != null && b != null) {
        if (b > a) gain += b - a;
        if (a > b) loss += a - b;
      }
      final alt = points[i].altitudeMeters;
      if (alt != null) {
        minAlt = minAlt == null ? alt : (alt < minAlt ? alt : minAlt);
        maxAlt = maxAlt == null ? alt : (alt > maxAlt ? alt : maxAlt);
      }
    }
    final hasAlt = points.any((p) => p.altitudeMeters != null);
    return TrackAnalytics(
      distanceMeters: distance,
      elapsedTimeMs: (elapsed * 1000).round(),
      movingTimeMs: (moving * 1000).round(),
      pausedTimeMs: 0,
      stoppedTimeMs: (paused * 1000).round(),
      averagePaceMsPerKm: distance > 0 && moving > 0
          ? (moving / (distance / 1000) * 1000).round()
          : null,
      averageSpeedMps: elapsed > 0 ? distance / elapsed : null,
      movingSpeedMps: moving > 0 ? distance / moving : null,
      maxSpeedMps: points.length < 2
          ? null
          : [
              for (var i = 1; i < points.length; i++)
                haversineMeters(points[i - 1].position, points[i].position) /
                    (points[i].timestamp
                            .difference(points[i - 1].timestamp)
                            .inMilliseconds /
                        1000.0),
            ].where((v) => v.isFinite && v > 0).fold<double?>(null, (a, b) => a == null || b > a ? b : a),
      bestPaceMsPerKm: null,
      smoothedBestPaceMsPerKm: null,
      elevationGainMeters: hasAlt ? gain : null,
      elevationLossMeters: hasAlt ? loss : null,
      elevationMinMeters: minAlt,
      elevationMaxMeters: maxAlt,
      quality: TrackAnalyticsQuality(
        acceptedSamples: points.length,
        rejectedSamples: 0,
        coverageRatio: points.length > 1 ? 1.0 : 0.0,
        gpsGapCount: 0,
        hasSufficientDistance: distance >= 100,
        hasElevationData: hasAlt,
      ),
    );
  }

  @override
  Future<LiveRunHandle> createLiveRun({
    List<GeoPoint>? route,
    List<AttemptSample>? ghostSamples,
  }) async {
    return _FakeLiveRun(route: route, ghostSamples: ghostSamples);
  }

  @override
  Future<ReplayHandle> createReplay({
    required List<GpsFix> fixes,
    List<GeoPoint>? routeGeometry,
    List<AttemptSample>? ghostSamples,
  }) async {
    return _FakeReplayRun(
      fixes: fixes,
      routeGeometry: routeGeometry,
      ghostSamples: ghostSamples,
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
      perAttempt.add(
        _routeSegments(a, segmentDistanceMeters, routeDistanceMeters),
      );
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
      result.add(
        RouteSegmentComparison(
          index: i,
          startDistanceM: segs.first.startDistanceM,
          endDistanceM: segs.first.endDistanceM,
          segments: segs,
          minSpeedMps: minSpeed,
          maxSpeedMps: maxSpeed,
          meanSpeedMps: count > 0 ? sum / count : 0,
          speedSpreadMps: count > 0 ? (maxSpeed - minSpeed) : 0,
        ),
      );
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
      final coveredEnd = end.clamp(
        0.0,
        attempt.samples.isEmpty ? 0.0 : attempt.samples.last.distance.meters,
      );
      final complete =
          (attempt.samples.isEmpty
              ? 0.0
              : attempt.samples.last.distance.meters) >=
          end - 1e-9;
      double duration = 0;
      if (start <
          (attempt.samples.isEmpty
              ? 0.0
              : attempt.samples.last.distance.meters)) {
        final tStart = _timeAt(attempt.samples, start) ?? 0;
        final tEnd = _timeAt(attempt.samples, coveredEnd) ?? tStart;
        duration = (tEnd - tStart).clamp(0, double.infinity);
      }
      final covered = (coveredEnd - start).clamp(0.0, double.infinity);
      final speed = duration > 0 ? covered / duration : 0.0;
      out.add(
        RouteSegment(
          index: i,
          startDistanceM: start,
          endDistanceM: end,
          durationSeconds: duration,
          averageSpeedMps: speed,
          complete: complete,
        ),
      );
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
      if (samples[0].distance.meters == distance) {
        return samples[0].elapsed.seconds;
      }
      return null;
    }
    if (samples[j].distance.meters == distance) {
      return samples[j].elapsed.seconds;
    }
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
    final difference = Elapsed.seconds(
      live.elapsed.seconds - reference.elapsed.seconds,
    );
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
        final fraction = span <= 0
            ? 0.0
            : (distanceM - a.distance.meters) / span;
        return a.elapsed.seconds +
            (b.elapsed.seconds - a.elapsed.seconds) * fraction;
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
              latitude:
                  points[i - 1].latitude +
                  (points[i].latitude - points[i - 1].latitude) * t,
              longitude:
                  points[i - 1].longitude +
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
    final dLon =
        (radius * math.sin(angle)) /
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

class _FakeLiveRun implements LiveRunHandle {
  _FakeLiveRun({List<GeoPoint>? route, List<AttemptSample>? ghostSamples})
    : _route = route,
      _routeLength = route == null ? 0.0 : polylineMeters(route),
      _ghostSamples = ghostSamples;

  static const double _maxAccuracy = 50.0;
  static const double _maxSpeed = 500.0 / 3.6;
  static const double _maxJump = 200.0;
  static const double _maxTimeGap = 60.0;
  static const double _motionFloor = 0.5;
  static const double _offRouteThreshold = 30.0;

  final List<GeoPoint>? _route;
  final double _routeLength;
  List<AttemptSample>? _ghostSamples;

  // Free-run cursor (engine filter semantics).
  GpsFix? _anchor;
  GpsFix? _pending;
  bool _pendingIsJump = false;
  double _committedM = 0, _committedS = 0, _pendingM = 0, _pendingS = 0;
  double _lastSpeedMps = 0;

  // Route axis.
  double _routeCoverage = 0, _routeMoving = 0;
  GpsFix? _routePrev;
  double _routePace = 0;

  GpsFix? _lastFix;
  bool _paused = false;
  bool _disposed = false;

  bool _accepts(GpsFix fix) {
    if (fix.accuracyMeters != null && fix.accuracyMeters! > _maxAccuracy) {
      return false;
    }
    if (fix.speedMetersPerSecond != null &&
        fix.speedMetersPerSecond! > _maxSpeed) {
      return false;
    }
    return true;
  }

  bool _isJump(GpsFix a, GpsFix b) {
    final gap = _dist(a, b);
    if (gap > _maxJump) return true;
    final dt = _dt(a, b);
    if (dt <= 0) return false;
    if (dt > _maxTimeGap) return false;
    return gap / dt > _maxSpeed;
  }

  double _dt(GpsFix a, GpsFix b) =>
      b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;

  double _dist(GpsFix a, GpsFix b) => haversineMeters(
    GeoPoint(latitude: a.latitude, longitude: a.longitude),
    GeoPoint(latitude: b.latitude, longitude: b.longitude),
  );

  ({double m, double s}) _segment(GpsFix a, GpsFix b) {
    final dt = _dt(a, b);
    if (dt <= 0) return (m: 0.0, s: 0.0);
    final m = _dist(a, b);
    if (m / dt < _motionFloor) return (m: 0.0, s: 0.0);
    return (m: m, s: dt);
  }

  void _commit(GpsFix a, GpsFix b) {
    final seg = _segment(a, b);
    _committedM += seg.m;
    _committedS += seg.s;
    _lastSpeedMps = seg.s > 0 ? seg.m / seg.s : 0;
  }

  void _recomputePending() {
    final pending = _pending;
    if (pending == null || _pendingIsJump) {
      _pendingM = 0;
      _pendingS = 0;
      return;
    }
    final seg = _segment(_anchor!, pending);
    _pendingM = seg.m;
    _pendingS = seg.s;
    _lastSpeedMps = seg.s > 0 ? seg.m / seg.s : 0;
  }

  void _addCursor(GpsFix fix) {
    if (!_accepts(fix)) return;
    if (_anchor == null) {
      _anchor = fix;
      return;
    }
    final pending = _pending;
    if (pending != null && !(_pendingIsJump && _isJump(pending, fix))) {
      _commit(_anchor!, pending);
      _anchor = pending;
    }
    final anchor = _anchor!;
    _pending = fix;
    _pendingIsJump = _isJump(anchor, fix);
    _recomputePending();
  }

  void _clearChain() {
    _anchor = null;
    _pending = null;
    _pendingIsJump = false;
    _pendingM = 0;
    _pendingS = 0;
    _lastSpeedMps = 0;
  }

  void _resetChain() {
    _committedM += _pendingM;
    _committedS += _pendingS;
    _clearChain();
  }

  @override
  void push(GpsFix fix) {
    if (_disposed || _paused) return;
    if (!_accepts(fix)) return;
    if (_route != null && _routeLength > 0) {
      final pos = GeoPoint(latitude: fix.latitude, longitude: fix.longitude);
      final proj = projectOnPolyline(_route, pos);
      if (proj != null) {
        var covered = proj.distanceM.clamp(0.0, _routeLength);
        if (_routeLength - covered <= 1.0) covered = _routeLength;
        if (covered > _routeCoverage) _routeCoverage = covered;
      }
      if (_routeLength - _routeCoverage <= 1.0 && _routeCoverage > 0) {
        _routeCoverage = _routeLength;
      }
      final prev = _routePrev;
      if (prev != null) {
        final dt = _dt(prev, fix);
        final ground = _dist(prev, fix);
        if (dt > 0 && ground / dt >= _motionFloor) {
          _routeMoving += dt;
          _routePace = ground / dt;
        }
      }
      _routePrev = fix;
      _addCursor(fix);
    } else {
      _addCursor(fix);
    }
    _lastFix = fix;
  }

  @override
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _resetChain();
    _routePrev = null;
    _routePace = 0;
  }

  @override
  void resume() {
    _paused = false;
  }

  @override
  void finish() {
    if (_disposed) return;
    if (_anchor != null && _pending != null) {
      _commit(_anchor!, _pending!);
    }
    _pending = null;
    _pendingIsJump = false;
    _recomputePending();
  }

  @override
  void seed({required double distanceMeters, required double movingSeconds}) {
    final d = math.max(0.0, distanceMeters);
    final m = math.max(0.0, movingSeconds);
    _committedM = d;
    _committedS = m;
    _clearChain();
    _routeCoverage = d;
    _routeMoving = m;
    _routePrev = null;
    _routePace = 0;
    _lastFix = null;
    _paused = false;
  }

  @override
  void setGhost(List<AttemptSample>? samples) {
    _ghostSamples = samples;
  }

  double get _distance => _route != null
      ? _routeCoverage.clamp(0.0, _routeLength)
      : (_committedM + _pendingM);

  double get _moving =>
      _route != null ? _routeMoving : (_committedS + _pendingS);

  double get _paceMps => _route != null ? _routePace : _lastSpeedMps;

  @override
  LiveEngineSnapshot snapshot() {
    final dist = _distance;
    final moving = _moving;
    GeoPoint? pos;
    if (_lastFix != null) {
      pos = GeoPoint(
        latitude: _lastFix!.latitude,
        longitude: _lastFix!.longitude,
      );
    }
    double? offRoute;
    if (_route != null && pos != null) {
      final proj = projectOnPolyline(_route, pos);
      if (proj != null) {
        final lateral = haversineMeters(pos, proj.point);
        if (lateral >= _offRouteThreshold) offRoute = lateral;
      }
    }
    final progress = _route != null && _routeLength > 0
        ? (_routeCoverage / _routeLength).clamp(0.0, 1.0)
        : 0.0;

    LiveGhostSnapshot? ghost;
    final samples = _ghostSamples;
    if (samples != null && samples.isNotEmpty) {
      final refTime = _referenceTimeAt(samples, dist);
      final diff = moving - refTime;
      final ghostDist = _distanceAt(samples, moving);
      final spacing = _sampleSpacing(samples, dist);
      final conf = (1.0 - (spacing - 10.0) / 50.0).clamp(0.0, 1.0);
      ghost = LiveGhostSnapshot(
        distanceMeters: dist,
        timeDifferenceSeconds: diff,
        ahead: diff < 0,
        spatialGapMeters: ghostDist - dist,
        confidence: conf,
      );
    }

    var matchStatus = LiveMatchStatusCode.none;
    var matchConfidence = 0.0;
    if (_route != null) {
      if (_lastFix == null) {
        matchStatus = LiveMatchStatusCode.initializing;
        matchConfidence = 0.0;
      } else if (offRoute != null) {
        matchStatus = LiveMatchStatusCode.offRoute;
        matchConfidence = 0.3;
      } else {
        matchStatus = LiveMatchStatusCode.matched;
        matchConfidence = 1.0;
      }
    }

    return LiveEngineSnapshot(
      distanceMeters: dist,
      movingSeconds: moving,
      paceMps: _paceMps,
      routeProgress: progress,
      offRouteMeters: offRoute,
      accuracyMeters: _lastFix?.accuracyMeters,
      position: pos,
      ghost: ghost,
      matchStatus: matchStatus,
      matchConfidence: matchConfidence,
    );
  }

  double _referenceTimeAt(List<AttemptSample> samples, double distanceM) {
    if (distanceM <= 0) return 0;
    if (distanceM <= samples.first.distance.meters) {
      return samples.first.elapsed.seconds;
    }
    final last = samples.last;
    if (distanceM >= last.distance.meters) return last.elapsed.seconds;
    for (var i = 1; i < samples.length; i++) {
      final b = samples[i];
      if (distanceM <= b.distance.meters) {
        if ((b.distance.meters - distanceM).abs() < 1e-9) {
          return b.elapsed.seconds;
        }
        final a = samples[i - 1];
        final span = b.distance.meters - a.distance.meters;
        if (span <= 0) return b.elapsed.seconds;
        final frac = (distanceM - a.distance.meters) / span;
        return a.elapsed.seconds +
            (b.elapsed.seconds - a.elapsed.seconds) * frac;
      }
    }
    return last.elapsed.seconds;
  }

  double _distanceAt(List<AttemptSample> samples, double elapsed) {
    if (elapsed <= 0) return samples.first.distance.meters;
    final last = samples.last;
    if (elapsed >= last.elapsed.seconds) return last.distance.meters;
    var i = samples.lastIndexWhere((s) => s.elapsed.seconds <= elapsed);
    if (i < 0) return samples.first.distance.meters;
    if (i == samples.length - 1) return last.distance.meters;
    final a = samples[i];
    final b = samples[i + 1];
    final span = b.elapsed.seconds - a.elapsed.seconds;
    if (span <= 0) return a.distance.meters;
    final frac = (elapsed - a.elapsed.seconds) / span;
    return a.distance.meters + (b.distance.meters - a.distance.meters) * frac;
  }

  double _sampleSpacing(List<AttemptSample> samples, double distanceM) {
    if (samples.length < 2) {
      return samples.isEmpty ? 0 : samples.last.distance.meters;
    }
    if (distanceM <= 0) return samples.first.distance.meters;
    final last = samples.last;
    if (distanceM >= last.distance.meters) {
      return last.distance.meters - samples[samples.length - 2].distance.meters;
    }
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].distance.meters >= distanceM) {
        return i == 0
            ? samples[0].distance.meters
            : samples[i].distance.meters - samples[i - 1].distance.meters;
      }
    }
    return 0;
  }

  @override
  void dispose() {
    _disposed = true;
  }
}

class _FakeReplayRun implements ReplayHandle {
  _FakeReplayRun({
    required List<GpsFix> fixes,
    List<GeoPoint>? routeGeometry,
    List<AttemptSample>? ghostSamples,
  })  : _fixes = List<GpsFix>.from(fixes)
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp)),
        _route = routeGeometry,
        _ghostSamples = ghostSamples {
    _t0 = _fixes.isEmpty ? null : _fixes.first.timestamp;
    if (_fixes.length >= 2) {
      _total = _fixes.last.timestamp
              .difference(_fixes.first.timestamp)
              .inMilliseconds /
          1000.0;
    } else {
      _total = 0.0;
    }
  }

  final List<GpsFix> _fixes;
  final List<GeoPoint>? _route;
  final List<AttemptSample>? _ghostSamples;
  DateTime? _t0;
  double _total = 0;
  double _elapsed = 0;
  double _speed = 1.0;
  ReplayState _state = ReplayState.paused;
  int _cursor = 0;

  @override
  void play() {
    if (_fixes.isEmpty) {
      _state = ReplayState.finished;
      return;
    }
    if (_state == ReplayState.finished) {
      seek(0);
    }
    _state = ReplayState.playing;
  }

  @override
  void pause() {
    if (_state == ReplayState.playing) _state = ReplayState.paused;
  }

  @override
  void seek(double elapsedSeconds) {
    final t = elapsedSeconds.clamp(0.0, _total);
    _elapsed = t.isFinite ? t : 0.0;
    _cursor = 0;
    _applyUpTo(_elapsed);
    if (_elapsed >= _total - 1e-9 && _fixes.isNotEmpty) {
      _state = ReplayState.finished;
    } else if (_state == ReplayState.finished) {
      _state = ReplayState.paused;
    }
  }

  @override
  void setSpeed(double speed) {
    if (speed.isFinite && speed > 0) _speed = speed.clamp(0.1, 32.0);
  }

  void _applyUpTo(double elapsed) {
    final t0 = _t0;
    if (t0 == null) return;
    while (_cursor < _fixes.length) {
      final at =
          _fixes[_cursor].timestamp.difference(t0).inMilliseconds / 1000.0;
      if (at > elapsed + 1e-9) break;
      _cursor++;
    }
  }

  double _ghostElapsedAt(List<AttemptSample> samples, double distanceM) {
    if (samples.isEmpty) return 0;
    if (distanceM <= 0) return samples.first.elapsed.seconds;
    final last = samples.last;
    if (distanceM >= last.distance.meters) return last.elapsed.seconds;
    for (var i = 1; i < samples.length; i++) {
      if (samples[i].distance.meters >= distanceM) {
        final a = samples[i - 1];
        final b = samples[i];
        final span = b.distance.meters - a.distance.meters;
        if (span <= 0) return b.elapsed.seconds;
        final frac = (distanceM - a.distance.meters) / span;
        return a.elapsed.seconds +
            (b.elapsed.seconds - a.elapsed.seconds) * frac;
      }
    }
    return last.elapsed.seconds;
  }

  double _ghostDistanceAt(List<AttemptSample> samples, double elapsed) {
    if (samples.isEmpty) return 0;
    if (elapsed <= 0) return samples.first.distance.meters;
    final last = samples.last;
    if (elapsed >= last.elapsed.seconds) return last.distance.meters;
    var i = samples.lastIndexWhere((s) => s.elapsed.seconds <= elapsed);
    if (i < 0) return samples.first.distance.meters;
    if (i == samples.length - 1) return last.distance.meters;
    final a = samples[i];
    final b = samples[i + 1];
    final span = b.elapsed.seconds - a.elapsed.seconds;
    if (span <= 0) return a.distance.meters;
    final frac = (elapsed - a.elapsed.seconds) / span;
    return a.distance.meters + (b.distance.meters - a.distance.meters) * frac;
  }

  double _sampleSpacing(List<AttemptSample> samples, double distanceM) {
    if (samples.length < 2) {
      return samples.isEmpty ? 0 : samples.last.distance.meters;
    }
    if (distanceM <= 0) return samples.first.distance.meters;
    final last = samples.last;
    if (distanceM >= last.distance.meters) {
      return last.distance.meters - samples[samples.length - 2].distance.meters;
    }
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].distance.meters >= distanceM) {
        return i == 0
            ? samples[0].distance.meters
            : samples[i].distance.meters - samples[i - 1].distance.meters;
      }
    }
    return 0;
  }

  ReplaySnapshot _snapshot() {
    double dist = 0;
    double paceMps = 0;
    double moving = 0;
    GeoPoint? pos;
    double? accuracy;
    if (_cursor > 0) {
      final last = _fixes[_cursor - 1];
      pos = GeoPoint(latitude: last.latitude, longitude: last.longitude);
      accuracy = last.accuracyMeters;
      for (var i = 1; i < _cursor; i++) {
        final a = _fixes[i - 1];
        final b = _fixes[i];
        final d = haversineMeters(
          GeoPoint(latitude: a.latitude, longitude: a.longitude),
          GeoPoint(latitude: b.latitude, longitude: b.longitude),
        );
        final dt =
            b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
        if (dt > 0 && d / dt >= 0.1) {
          dist += d;
          moving += dt;
          paceMps = d / dt;
        }
      }
    }
    double routeProgress = 0;
    double? offRoute;
    final route = _route;
    var progressDistance = dist;
    if (route != null && route.length >= 2 && pos != null) {
      final proj = projectOnPolyline(route, pos);
      final total = polylineMeters(route);
      if (proj != null && total > 0) {
        routeProgress = (proj.distanceM / total).clamp(0.0, 1.0);
        progressDistance = proj.distanceM;
        final lateral = haversineMeters(pos, proj.point);
        if (lateral >= 30.0) offRoute = lateral;
      }
    }
    final onRoute = route != null && route.length >= 2;
    LiveGhostSnapshot? ghost;
    final samples = _ghostSamples;
    if (samples != null && samples.isNotEmpty && (onRoute || dist > 0)) {
      final refDistance = onRoute ? progressDistance : dist;
      final refMoving = moving;
      final ghostDist = _ghostDistanceAt(samples, refMoving);
      final timeDiff = _ghostElapsedAt(samples, refDistance) - refMoving;
      final spacing = _sampleSpacing(samples, refDistance);
      final conf = spacing <= 0 ? 0.0 : (1.0 - spacing / 400.0).clamp(0.0, 1.0);
      ghost = LiveGhostSnapshot(
        distanceMeters: refDistance,
        timeDifferenceSeconds: timeDiff,
        ahead: timeDiff < 0,
        spatialGapMeters: ghostDist - refDistance,
        confidence: conf,
      );
    }
    return ReplaySnapshot(
      elapsedSeconds: _elapsed,
      totalSeconds: _total,
      state: _state,
      speed: _speed,
      appliedFixes: _cursor,
      totalFixes: _fixes.length,
      position: pos,
      accuracyMeters: accuracy,
      distanceMeters: onRoute ? progressDistance : dist,
      movingSeconds: moving,
      paceMps: paceMps,
      routeProgress: routeProgress,
      offRouteMeters: offRoute,
      ghost: ghost,
      matchStatus: onRoute
          ? (offRoute != null
              ? LiveMatchStatusCode.offRoute
              : LiveMatchStatusCode.matched)
          : LiveMatchStatusCode.none,
      matchConfidence: onRoute ? 1.0 : 0.0,
    );
  }

  @override
  ReplaySnapshot advance(double deltaSeconds) {
    if (_state == ReplayState.playing) {
      final step = deltaSeconds * _speed;
      if (step.isFinite && step > 0) {
        _elapsed = (_elapsed + step).clamp(0.0, _total);
        _applyUpTo(_elapsed);
        if (_elapsed >= _total - 1e-9) {
          _elapsed = _total;
          _state = ReplayState.finished;
        }
      }
    }
    return _snapshot();
  }

  @override
  ReplaySnapshot snapshot() => _snapshot();

  @override
  void dispose() {}
}
