// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Device-GPS source tests (M15 Phase 12).
///
/// Pins the raw-fix contract: every sensor field the receiver actually
/// reported survives the conversion, and the ones it didn't stay `null` — the
/// app never invents a value to fill a gap. The source is exercised through
/// the pure [gpsFixFromPlatformMap] mapper so no method channel is touched.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/engine/device_gps_source.dart';

Map<String, dynamic> _map({
  double latitude = 52.505,
  double longitude = 13.36,
  int timestamp = 1767278400000, // 2026-01-01T12:00:00Z
  double? accuracy = 5.0,
  double? altitude = 60.0,
  double? speed = 3.3,
  double? bearing = 42.0,
  bool hasAccuracy = true,
  bool hasAltitude = true,
  bool hasSpeed = true,
  bool hasBearing = true,
}) {
  return <String, dynamic>{
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp,
    'accuracy': hasAccuracy ? accuracy : null,
    'altitude': hasAltitude ? altitude : null,
    'speed': hasSpeed ? speed : null,
    'bearing': hasBearing ? bearing : null,
  };
}

void main() {
  group('gpsFixFromPlatformMap', () {
    test('keeps every reported sensor field', () {
      final fix = gpsFixFromPlatformMap(_map());

      expect(fix.latitude, 52.505);
      expect(fix.longitude, 13.36);
      expect(fix.accuracyMeters, 5.0);
      expect(fix.altitudeMeters, 60.0);
      expect(fix.speedMetersPerSecond, 3.3);
      expect(fix.bearingDegrees, 42.0);
    });

    test('leaves unreported fields null instead of inventing a value', () {
      final fix = gpsFixFromPlatformMap(
        _map(hasAccuracy: false, hasAltitude: false, hasBearing: false),
      );

      expect(fix.accuracyMeters, isNull);
      expect(fix.altitudeMeters, isNull);
      expect(fix.bearingDegrees, isNull);
      expect(fix.speedMetersPerSecond, 3.3);
    });
  });

  group('DeviceGpsSource', () {
    test('exposes the device-GPS identity', () {
      expect(const DeviceGpsSource().description, 'device GPS');
    });
  });
}