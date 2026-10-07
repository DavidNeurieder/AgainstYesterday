// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Device-GPS source tests (M15 Phase 12).
///
/// Pins the raw-fix contract: every sensor field the receiver actually
/// reported survives the conversion, and the ones it didn't stay `null` — the
/// app never invents a value to fill a gap. The source is exercised through a
/// fake [GeolocatorPlatform] so no method channel is touched.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';

/// A minimal deterministic [GeolocatorPlatform] whose state the test controls.
class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  _FakeGeolocatorPlatform({
    required this.serviceEnabled,
    required this.permission,
    Stream<Position>? positions,
  }) : positions = positions ?? const Stream.empty();

  bool serviceEnabled;
  LocationPermission permission;
  final Stream<Position> positions;
  int requests = 0;
  int appSettingsOpened = 0;
  int locationSettingsOpened = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    permission = LocationPermission.whileInUse;
    return permission;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions;

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsOpened++;
    return true;
  }
}

Position _position({
  double latitude = 52.505,
  double longitude = 13.36,
  double accuracy = 5.0,
  double altitude = 60.0,
  double speed = 3.3,
  double heading = 42.0,
  bool hasAccuracy = true,
  bool hasAltitude = true,
  bool hasSpeed = true,
  bool hasHeading = true,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime.utc(2026, 1, 1, 12),
    accuracy: accuracy,
    altitude: altitude,
    altitudeAccuracy: 0,
    heading: heading,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
    hasAccuracy: hasAccuracy,
    hasAltitude: hasAltitude,
    hasHeading: hasHeading,
    hasSpeed: hasSpeed,
  );
}

void main() {
  group('gpsFixFromPosition', () {
    test('keeps every reported sensor field', () {
      final fix = gpsFixFromPosition(_position());

      expect(fix.timestamp, DateTime.utc(2026, 1, 1, 12));
      expect(fix.latitude, 52.505);
      expect(fix.longitude, 13.36);
      expect(fix.accuracyMeters, 5.0);
      expect(fix.altitudeMeters, 60.0);
      expect(fix.speedMetersPerSecond, 3.3);
      expect(fix.bearingDegrees, 42.0);
    });

    test('leaves unreported fields null instead of inventing a value', () {
      final fix = gpsFixFromPosition(
        _position(hasAccuracy: false, hasAltitude: false, hasHeading: false),
      );

      expect(fix.accuracyMeters, isNull);
      expect(fix.altitudeMeters, isNull);
      expect(fix.bearingDegrees, isNull);
      expect(fix.speedMetersPerSecond, 3.3);
    });
  });

  group('DeviceGpsSource.ensureAvailable', () {
    late DeviceGpsSource source;

    setUp(() {
      source = const DeviceGpsSource();
    });

    test('ready when services are on and permission was already granted', () async {
      final platform = _FakeGeolocatorPlatform(
        serviceEnabled: true,
        permission: LocationPermission.whileInUse,
      );
      GeolocatorPlatform.instance = platform;

      expect(await source.ensureAvailable(), isNull);
      expect(platform.requests, 0);
    });

    test('requests permission when it was previously denied', () async {
      final platform = _FakeGeolocatorPlatform(
        serviceEnabled: true,
        permission: LocationPermission.denied,
      );
      GeolocatorPlatform.instance = platform;

      expect(await source.ensureAvailable(), isNull);
      expect(platform.requests, 1);
    });

    test('reports a reason when the permission stays denied', () async {
      final platform = _FakeGeolocatorPlatform(
        serviceEnabled: true,
        permission: LocationPermission.deniedForever,
      );
      GeolocatorPlatform.instance = platform;

      expect(
        await source.ensureAvailable(),
        startsWith('Location permission is denied.'),
      );
    });

    test('reports a reason when location services are off', () async {
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(
        serviceEnabled: false,
        permission: LocationPermission.whileInUse,
      );

      expect(
        await source.ensureAvailable(),
        startsWith('Location services are off.'),
      );
    });
  });

  group('DeviceGpsSource.openSettings', () {
    test('routes to the location-services settings when GPS is off', () async {
      final platform = _FakeGeolocatorPlatform(
        serviceEnabled: false,
        permission: LocationPermission.whileInUse,
      );
      GeolocatorPlatform.instance = platform;

      await const DeviceGpsSource().openSettings();

      expect(platform.locationSettingsOpened, 1);
      expect(platform.appSettingsOpened, 0);
    });

    test('routes to the app settings otherwise (permission denied)', () async {
      final platform = _FakeGeolocatorPlatform(
        serviceEnabled: true,
        permission: LocationPermission.deniedForever,
      );
      GeolocatorPlatform.instance = platform;

      await const DeviceGpsSource().openSettings();

      expect(platform.appSettingsOpened, 1);
      expect(platform.locationSettingsOpened, 0);
    });
  });

  group('DeviceGpsSource.fixes', () {
    test('replays the receiver output as raw fixes', () async {
      final positions = Stream.fromIterable([
        _position(),
        _position(latitude: 52.506, speed: 3.7, hasHeading: false),
      ]);
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(
        serviceEnabled: true,
        permission: LocationPermission.whileInUse,
        positions: positions,
      );

      final fixes = await const DeviceGpsSource().fixes().toList();

      expect(fixes, hasLength(2));
      expect(fixes.first.latitude, 52.505);
      expect(fixes.last.latitude, 52.506);
      expect(fixes.last.speedMetersPerSecond, 3.7);
      expect(fixes.last.bearingDegrees, isNull);
      expect(fixes.last.timestamp, DateTime.utc(2026, 1, 1, 12));
    });
  });

  group('GpsSource.provider default', () {
    test('deviceGpsProvider exposes the real source under the define', () {
      expect(const DeviceGpsSource().description, 'device GPS');
    });
  });
}