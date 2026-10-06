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
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
  }) async {
    final req = _W()
      ..str(activityId)
      ..str(routeId)
      ..points(points)
      ..coordinates(routeGeometry);
    final r = _R(_ffi.createAttempt(req.takeBytes()));
    return Attempt(
      activityId: activityId,
      routeId: routeId,
      elapsed: Elapsed.seconds(r.f64()),
      samples: r.attemptSamples(),
    );
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

/// The demo loop both engines agree on, passed to the native generator.
/// Mirrors `FakeEngineService.riverLoop` so fake and Rust engines seed the
/// same catalog geometry.
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

  int u32() {
    _ensure(4);
    final v = ByteData.sublistView(data, _pos, _pos + 4)
        .getUint32(0, Endian.little);
    _pos += 4;
    return v;
  }

  int _rawI64() {
    _ensure(8);
    final v = ByteData.sublistView(data, _pos, _pos + 8)
        .getInt64(0, Endian.little);
    _pos += 8;
    return v;
  }

  double f64() {
    _ensure(8);
    final v = ByteData.sublistView(data, _pos, _pos + 8)
        .getFloat64(0, Endian.little);
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
      result.add(TrackPoint(
        position: GeoPoint(latitude: latitude, longitude: longitude),
        altitudeMeters: altitude,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
      ));
    }
    return result;
  }

  List<AttemptSample> attemptSamples() {
    final n = u32();
    final result = <AttemptSample>[];
    for (var i = 0; i < n; i++) {
      result.add(AttemptSample(
        distance: Distance.meters(f64()),
        elapsed: Elapsed.seconds(f64()),
      ));
    }
    return result;
  }
}