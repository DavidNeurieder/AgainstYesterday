// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A live feed of raw GPS fixes from the device receiver — the real
/// counterpart to the deterministic demo timeline the recording controller
/// replays when no device source is wired in.
///
/// The source only performs *acquisition* ([GpsSource.ensureAvailable]) and
/// exposes the unprocessed fix stream ([GpsSource.fixes]); it never sniffs or
/// processes a fix. Conversion to the app's own [GpsFix] model happens here so
/// the rest of the app stays ignorant of the geolocator API.
library;

import 'package:geolocator/geolocator.dart';

import 'models.dart';

/// Maps a receiver update onto the app's raw [GpsFix] model, keeping every
/// sensor field the platform actually reported (M15 Phase 12) and leaving the
/// ones it didn't `null` — the app never invents a value to fill a gap.
GpsFix gpsFixFromPosition(Position position) {
  return GpsFix(
    timestamp: position.timestamp.toUtc(),
    latitude: position.latitude,
    longitude: position.longitude,
    accuracyMeters: position.hasAccuracy ? position.accuracy : null,
    altitudeMeters: position.hasAltitude ? position.altitude : null,
    speedMetersPerSecond: position.hasSpeed ? position.speed : null,
    bearingDegrees: position.hasHeading ? position.heading : null,
  );
}

/// A provider of raw GPS observations the recording consumes while running.
///
/// Two personalities exist:
///
///  * [DeviceGpsSource] — the real receiver, wired in for phone builds
///    (`USE_DEVICE_GPS=true`);
///  * a deterministic fake implementing this interface — tests inject one to
///    drive the device path with a canned fix timeline.
///
/// `null` is not a source: the `deviceGpsProvider` in `app/dependencies.dart`
/// holds a `null` when the build should keep replaying the deterministic demo
/// timeline instead (unit/widget tests and the E2E default).
abstract interface class GpsSource {
  /// Human-readable identity for the diagnostics readout.
  String get description;

  /// Confirms the receiver is usable: service enabled and permission granted
  /// (requesting it when needed). Returns `null` when fixes can flow,
  /// otherwise a short reason the recording surfaces as an error state.
  Future<String?> ensureAvailable();

  /// Unprocessed fixes from the receiver. The app is expected to remain
  /// subscribed for the whole session and ignore anything arriving while the
  /// run is paused or finishing.
  Stream<GpsFix> fixes();
}

/// The real device receiver backed by the geolocator plugin.
class DeviceGpsSource implements GpsSource {
  const DeviceGpsSource();

  @override
  String get description => 'device GPS';

  @override
  Future<String?> ensureAvailable() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'location services are off';
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return 'location permission denied';
    }
    return null;
  }

  @override
  Stream<GpsFix> fixes() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        // ~1 fix/sec, matching the engine's 1 Hz sample cadence.
        timeLimit: null,
      ),
    ).map(gpsFixFromPosition);
  }
}