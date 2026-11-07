// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [`EngineService`] backed by the Rust engine over FFI (M9).
///
/// Mirrors `rust/gps-engine/src/capi.rs` on the Dart side: every method
/// encodes the request into the documented little-endian buffer, calls the
/// C API, and decodes the response back into domain models. All methods are
/// deterministic and synchronous at the call site (the interface's `Future`
/// return is a cheap `Future.sync` wrapper).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'engine_service.dart';
import 'gps_ffi.dart';
import '../core/units.dart';
import 'models.dart';

/// A `EngineService` that delegates geometry to the native Rust engine.
final class RustEngineService implements EngineService {
  RustEngineService(this._ffi);

  /// Loads and wraps the shared library found at [libraryPath].
  factory RustEngineService.open(String libraryPath) =>
      RustEngineService(GpsEngineFfi.open(libraryPath));

  final GpsEngineFfi _ffi;

  String get version => _ffi.version;

  @override
  String get engineDescription => 'rust v$version';

  @override
  Future<ProcessedTrack> processTrack({
    required String id,
    required List<TrackPoint> points,
  }) async {
    final req = _W()
      ..str(id)
      ..points(points);
    final r = _R(_ffi.processTrack(req.takeBytes()));
    return ProcessedTrack(
      id: id,
      inputPoints: r.u32(),
      outputPoints: r.u32(),
      originalDistance: Distance.meters(r.f64()),
      processedDistance: Distance.meters(r.f64()),
      duration: Elapsed.seconds(r.f64()),
      movingTime: Elapsed.seconds(r.f64()),
    );
  }

  @override
  Future<RouteMatchResult> matchRoutes({
    required List<TrackPoint> a,
    required List<TrackPoint> b,
  }) async {
    final req = _W()
      ..points(a)
      ..points(b);
    final r = _R(_ffi.matchRoutes(req.takeBytes()));
    return RouteMatchResult(
      score: MatchScore(
        startDistance: Distance.meters(r.f64()),
        endDistance: Distance.meters(r.f64()),
        distanceRatio: r.f64(),
        spatialOverlap: r.f64(),
        directionSimilarity: r.f64(),
        overallScore: r.f64(),
      ),
      sameRoute: r.u8() == 1,
    );
  }

  @override
  Future<List<RouteSegmentComparison>> compareRouteSegments({
    required List<Attempt> attempts,
    required double segmentDistanceMeters,
    required double routeDistanceMeters,
  }) async {
    final req = _W()
      ..f64(routeDistanceMeters)
      ..f64(segmentDistanceMeters)
      ..u32(attempts.length);
    for (final a in attempts) {
      req.attempt(a.samples);
    }
    final r = _R(_ffi.compareRouteSegments(req.takeBytes()));
    final count = r.u32();
    final result = <RouteSegmentComparison>[];
    for (var i = 0; i < count; i++) {
      final index = r.u32();
      final start = r.f64();
      final end = r.f64();
      final attemptCount = r.u32();
      final segments = <RouteSegment>[];
      for (var j = 0; j < attemptCount; j++) {
        segments.add(
          RouteSegment(
            index: index,
            startDistanceM: start,
            endDistanceM: end,
            durationSeconds: r.f64(),
            averageSpeedMps: r.f64(),
            complete: r.u8() == 1,
          ),
        );
      }
      result.add(
        RouteSegmentComparison(
          index: index,
          startDistanceM: start,
          endDistanceM: end,
          segments: segments,
          minSpeedMps: r.f64(),
          maxSpeedMps: r.f64(),
          meanSpeedMps: r.f64(),
          speedSpreadMps: r.f64(),
        ),
      );
    }
    return result;
  }

  @override
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
    bool movingTime = false,
  }) async {
    final req = _W()
      ..str(activityId)
      ..str(routeId)
      ..points(points)
      ..coordinates(routeGeometry)
      ..u8(movingTime ? 1 : 0);
    final r = _R(_ffi.createAttempt(req.takeBytes()));
    return Attempt(
      activityId: activityId,
      routeId: routeId,
      elapsed: Elapsed.seconds(r.f64()),
      samples: r.attemptSamples(),
    );
  }

  @override
  Future<({double lengthMeters, double durationSeconds})> routeInfo({
    required List<TrackPoint> points,
  }) async {
    final req = _W()..points(points);
    final r = _R(_ffi.routeInfo(req.takeBytes()));
    return (lengthMeters: r.f64(), durationSeconds: r.f64());
  }

  @override
  Future<LiveRunHandle> createLiveRun({
    List<GeoPoint>? route,
    List<AttemptSample>? ghostSamples,
  }) async {
    final req = _W();
    if (route != null) {
      req.u8(1);
      req.coordinates(route);
    } else {
      req.u8(0);
    }
    if (ghostSamples != null) {
      req.u8(1);
      req.attempt(ghostSamples);
    } else {
      req.u8(0);
    }
    final r = _R(_ffi.liveNew(req.takeBytes()));
    return _RustLiveRun(_ffi, r.u64());
  }

  @override
  GhostState ghostStateAt({
    required Ghost ghost,
    required Attempt current,
    required Distance distance,
  }) {
    final req = _W()
      ..attempt(ghost.samples)
      ..attempt(current.samples)
      ..f64(distance.meters);
    final r = _R(_ffi.ghostStateAt(req.takeBytes()));
    return GhostState(
      distance: Distance.meters(r.f64()),
      timeDifference: Elapsed.seconds(r.f64()),
      ahead: r.u8() == 1,
    );
  }

  @override
  GhostState liveGhostGap({
    required Ghost ghost,
    required double distanceM,
    required double movingSeconds,
    required double loopLengthM,
  }) {
    final req = _W()
      ..attempt(ghost.samples)
      ..f64(distanceM)
      ..f64(movingSeconds)
      ..f64(loopLengthM);
    final r = _R(_ffi.liveGhostGap(req.takeBytes()));
    return GhostState(
      distance: Distance.meters(r.f64()),
      timeDifference: Elapsed.seconds(r.f64()),
      ahead: r.u8() == 1,
    );
  }

  @override
  List<TrackPoint> generateRecording({
    double noiseMeters = 2.0,
    double speedMetersPerSecond = 2.5,
    double sampleEverySeconds = 1.0,
  }) {
    final req = _W()
      ..coordinates(_recordingGeometry)
      ..f64(speedMetersPerSecond)
      ..f64(sampleEverySeconds)
      ..f64(noiseMeters);
    final r = _R(_ffi.generateRecording(req.takeBytes()));
    return r.points();
  }
}

/// The demo loop the host-side generator walks, mirroring
/// `FakeEngineService.riverLoop` so fake and Rust engines produce matching
/// deterministic fixtures. This is the engine's test geometry — the app
/// catalog starts empty and is user-built only.
/// A stateful live recorder backed by the Rust engine's opaque handle.
class _RustLiveRun implements LiveRunHandle {
  _RustLiveRun(this._ffi, this._handle);

  final GpsEngineFfi _ffi;
  int _handle;
  bool _disposed = false;

  void _check() {
    if (_disposed) {
      throw StateError('LiveRunHandle used after dispose');
    }
  }

  @override
  void push(GpsFix fix) {
    _check();
    final req = _W()
      ..u64(_handle)
      ..fix(fix);
    _ffi.livePush(req.takeBytes());
  }

  @override
  void pause() {
    _check();
    _ffi.livePause((_W()..u64(_handle)).takeBytes());
  }

  @override
  void resume() {
    _check();
    _ffi.liveResume((_W()..u64(_handle)).takeBytes());
  }

  @override
  void finish() {
    _check();
    _ffi.liveFinish((_W()..u64(_handle)).takeBytes());
  }

  @override
  void seed({required double distanceMeters, required double movingSeconds}) {
    _check();
    final req = _W()
      ..u64(_handle)
      ..f64(distanceMeters)
      ..f64(movingSeconds);
    _ffi.liveSeed(req.takeBytes());
  }

  @override
  void setGhost(List<AttemptSample>? samples) {
    _check();
    final req = _W()..u64(_handle);
    if (samples != null) {
      req.u8(1);
      req.attempt(samples);
    } else {
      req.u8(0);
    }
    _ffi.liveSetGhost(req.takeBytes());
  }

  @override
  LiveEngineSnapshot snapshot() {
    _check();
    final r = _R(_ffi.liveSnapshot((_W()..u64(_handle)).takeBytes()));
    final distanceMeters = r.f64();
    final movingSeconds = r.f64();
    final paceMps = r.f64();
    final routeProgress = r.f64();
    final hasOff = r.u8() == 1;
    final off = r.f64();
    final hasAcc = r.u8() == 1;
    final acc = r.f64();
    final hasPos = r.u8() == 1;
    final lat = r.f64();
    final lon = r.f64();
    final hasGhost = r.u8() == 1;
    final gDistance = r.f64();
    final gDiff = r.f64();
    final gAhead = r.u8() == 1;
    final gSpatial = r.f64();
    final gConf = r.f64();
    final matchStatus = r.u8();
    final matchConfidence = r.f64();
    return LiveEngineSnapshot(
      distanceMeters: distanceMeters,
      movingSeconds: movingSeconds,
      paceMps: paceMps,
      routeProgress: routeProgress,
      offRouteMeters: hasOff ? off : null,
      accuracyMeters: hasAcc ? acc : null,
      position: hasPos ? GeoPoint(latitude: lat, longitude: lon) : null,
      ghost: hasGhost
          ? LiveGhostSnapshot(
              distanceMeters: gDistance,
              timeDifferenceSeconds: gDiff,
              ahead: gAhead,
              spatialGapMeters: gSpatial,
              confidence: gConf,
            )
          : null,
      matchStatus: matchStatus,
      matchConfidence: matchConfidence,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.liveFree(_handle);
    _handle = 0;
  }
}

final List<GeoPoint> _recordingGeometry = const [
  GeoPoint(latitude: 52.5050, longitude: 13.3600),
  GeoPoint(latitude: 52.5095, longitude: 13.3660),
  GeoPoint(latitude: 52.5105, longitude: 13.3760),
  GeoPoint(latitude: 52.5065, longitude: 13.3840),
  GeoPoint(latitude: 52.5000, longitude: 13.3820),
  GeoPoint(latitude: 52.4980, longitude: 13.3720),
  GeoPoint(latitude: 52.5000, longitude: 13.3620),
  GeoPoint(latitude: 52.5050, longitude: 13.3600),
];

// ---------------------------------------------------------------------------
// Binary wire codec (mirror of capi.rs)
// ---------------------------------------------------------------------------

/// Request writer, little-endian.
class _W {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _W str(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    _builder.add(bytes);
    return this;
  }

  _W u64(int value) => _add(value, 8);
  _W u32(int value) => _add(value, 4);
  _W i64(int value) => _add(value, 8);
  _W f64(double value) {
    _addFromBytes(ByteData(8)..setFloat64(0, value, Endian.little));
    return this;
  }

  _W u8(int value) {
    _builder.addByte(value & 0xff);
    return this;
  }

  _W _add(int value, int size) {
    final data = ByteData(size);
    if (size == 4) {
      data.setUint32(0, value, Endian.little);
    } else {
      data.setInt64(0, value, Endian.little);
    }
    _addFromBytes(data);
    return this;
  }

  void _addFromBytes(ByteData data) {
    _builder.add(data.buffer.asUint8List());
  }

  _W fix(GpsFix fix) {
    f64(fix.latitude);
    f64(fix.longitude);
    i64(fix.timestamp.millisecondsSinceEpoch);
    var mask = 0;
    if (fix.accuracyMeters != null) mask |= 0x01;
    if (fix.altitudeMeters != null) mask |= 0x02;
    if (fix.speedMetersPerSecond != null) mask |= 0x04;
    if (fix.bearingDegrees != null) mask |= 0x08;
    u8(mask);
    if (fix.accuracyMeters != null) f64(fix.accuracyMeters!);
    if (fix.altitudeMeters != null) f64(fix.altitudeMeters!);
    if (fix.speedMetersPerSecond != null) f64(fix.speedMetersPerSecond!);
    if (fix.bearingDegrees != null) f64(fix.bearingDegrees!);
    return this;
  }

  _W points(List<TrackPoint> points) {
    u32(points.length);
    for (final p in points) {
      f64(p.position.latitude);
      f64(p.position.longitude);
      final altitude = p.altitudeMeters;
      if (altitude == null) {
        u8(0);
      } else {
        u8(1);
        f64(altitude);
      }
      i64(p.timestamp.millisecondsSinceEpoch);
    }
    return this;
  }

  _W coordinates(List<GeoPoint> geometry) {
    u32(geometry.length);
    for (final p in geometry) {
      f64(p.latitude);
      f64(p.longitude);
    }
    return this;
  }

  _W attempt(List<AttemptSample> samples) {
    u32(samples.length);
    for (final s in samples) {
      f64(s.distance.meters);
      f64(s.elapsed.seconds);
    }
    return this;
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Response reader, little-endian, with bounds checks.
class _R {
  _R(this.data);

  final Uint8List data;
  int _pos = 0;

  void _ensure(int n) {
    if (_pos + n > data.length) {
      throw const FormatException('gps_engine: truncated response buffer');
    }
  }

  int u8() {
    _ensure(1);
    return data[_pos++];
  }

  int u64() => _rawI64(); // Dart int holds 64-bit on 64-bit platforms
  int u32() {
    _ensure(4);
    final v = ByteData.sublistView(
      data,
      _pos,
      _pos + 4,
    ).getUint32(0, Endian.little);
    _pos += 4;
    return v;
  }

  int _rawI64() {
    _ensure(8);
    final v = ByteData.sublistView(
      data,
      _pos,
      _pos + 8,
    ).getInt64(0, Endian.little);
    _pos += 8;
    return v;
  }

  double f64() {
    _ensure(8);
    final v = ByteData.sublistView(
      data,
      _pos,
      _pos + 8,
    ).getFloat64(0, Endian.little);
    _pos += 8;
    return v;
  }

  List<TrackPoint> points() {
    final n = u32();
    final result = <TrackPoint>[];
    for (var i = 0; i < n; i++) {
      final latitude = f64();
      final longitude = f64();
      final hasAlt = u8();
      final altitude = hasAlt == 1 ? f64() : null;
      final tsMs = _rawI64();
      result.add(
        TrackPoint(
          position: GeoPoint(latitude: latitude, longitude: longitude),
          altitudeMeters: altitude,
          timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
        ),
      );
    }
    return result;
  }

  List<AttemptSample> attemptSamples() {
    final n = u32();
    final result = <AttemptSample>[];
    for (var i = 0; i < n; i++) {
      result.add(
        AttemptSample(
          distance: Distance.meters(f64()),
          elapsed: Elapsed.seconds(f64()),
        ),
      );
    }
    return result;
  }
}
