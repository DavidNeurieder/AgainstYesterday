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
  /// otherwise the failure reason the recording surfaces on the error screen.
  Future<String?> ensureAvailable();

  /// Unprocessed fixes from the receiver. The app is expected to remain
  /// subscribed for the whole session and ignore anything arriving while the
  /// run is paused or finishing.
  Stream<GpsFix> fixes();

  /// Opens the system screen that can put the receiver back in service:
  /// the location-services settings when they are off, otherwise the app's
  /// own settings (for a denied permission).
  Future<void> openSettings();
}

/// The real device receiver backed by the geolocator plugin.
class DeviceGpsSource implements GpsSource {
  const DeviceGpsSource();

  @override
  String get description => 'device GPS';

  @override
  Future<String?> ensureAvailable() async {
    // The GMS-backed settings check behind this can hang forever on an
    // offline/uncertified emulator (WAITING_FOR_SERVER), so time it out and
    // optimistically continue — the fix stream surfaces a real problem
    // through its own error path.
    final serviceEnabled = await Geolocator.isLocationServiceEnabled()
        .timeout(const Duration(seconds: 5), onTimeout: () => true);
    if (!serviceEnabled) {
      return 'Location services are off. Turn on GPS, then try again.';
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return 'Location permission is denied. Allow location access for '
          'Against Yesterday, then try again.';
    }
    return null;
  }

  @override
  Stream<GpsFix> fixes() {
    return Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        // Raw LocationManager fixes instead of the GMS FusedLocationProvider:
        // the latter gates its first request behind a SettingsClient check
        // that hangs forever (WAITING_FOR_SERVER) on offline/uncertified
        // emulators, so no fix would ever arrive.
        forceLocationManager: true,
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        // ~1 fix/sec, matching the engine's 1 Hz sample cadence.
        intervalDuration: const Duration(seconds: 1),
        timeLimit: null,
      ),
    ).map(gpsFixFromPosition);
  }

  @override
  Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
      return;
    }
    await Geolocator.openAppSettings();
  }
}