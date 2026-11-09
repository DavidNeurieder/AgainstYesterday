// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A live feed of raw GPS fixes from the device receiver — the real
/// counterpart to the deterministic demo timeline the recording controller
/// replays when no device source is wired in.
///
/// The source only performs *acquisition* ([GpsSource.ensureAvailable]) and
/// exposes the unprocessed fix stream ([GpsSource.fixes]); it never sniffs or
/// processes a fix. Conversion to the app's own [GpsFix] model happens here so
/// the rest of the app stays ignorant of the platform location API.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

/// Maps a platform location update onto the app's raw [GpsFix] model, keeping
/// every sensor field the platform actually reported and leaving the ones it
/// didn't `null` — the app never invents a value to fill a gap.
GpsFix gpsFixFromPlatformMap(Map<String, dynamic> map) {
  final timestampMs = map['timestamp'];
  DateTime timestamp;
  if (timestampMs is int) {
    timestamp = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
  } else if (timestampMs is double) {
    timestamp = DateTime.fromMillisecondsSinceEpoch(timestampMs.toInt(),
        isUtc: true);
  } else {
    timestamp = DateTime.now().toUtc();
  }
  return GpsFix(
    timestamp: timestamp,
    latitude: (map['latitude'] as num).toDouble(),
    longitude: (map['longitude'] as num).toDouble(),
    accuracyMeters: map['accuracy'] == null
        ? null
        : (map['accuracy'] as num).toDouble(),
    altitudeMeters: map['altitude'] == null
        ? null
        : (map['altitude'] as num).toDouble(),
    speedMetersPerSecond: map['speed'] == null
        ? null
        : (map['speed'] as num).toDouble(),
    bearingDegrees: map['bearing'] == null
        ? null
        : (map['bearing'] as num).toDouble(),
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

  /// Whether Android would still show its own location-permission dialog:
  /// permission is missing but not permanently denied.
  ///
  /// The UI gives the §33 explanation *before* that dialog can appear, so it
  /// asks this first — a granted permission means there is nothing to explain,
  /// and a permanently denied one means no dialog will appear to explain.
  Future<bool> canAskPermission();

  /// Unprocessed fixes from the receiver. The app is expected to remain
  /// subscribed for the whole session and ignore anything arriving while the
  /// run is paused or finishing.
  Stream<GpsFix> fixes();

  /// Opens the system screen that can put the receiver back in service:
  /// the location-services settings when they are off, otherwise the app's
  /// own settings (for a denied permission).
  Future<void> openSettings();
}

/// The real device receiver backed by the platform's own location service
/// (Android's [LocationManager] / iOS's [CLLocationManager]) — no Google Play
/// Services, so the build stays F-Droid-clean.
class DeviceGpsSource implements GpsSource {
  const DeviceGpsSource();

  static const MethodChannel _method =
      MethodChannel('dev.neurieder.against_yesterday/location');
  static const EventChannel _events =
      EventChannel('dev.neurieder.against_yesterday/location_updates');

  @override
  String get description => 'device GPS';

  @override
  Future<String?> ensureAvailable() async {
    // The settings check behind this can hang forever on an offline/uncertified
    // emulator, so time it out and optimistically continue — the fix stream
    // surfaces a real problem through its own error path.
    final serviceEnabled = await _isLocationServiceEnabled()
        .timeout(const Duration(seconds: 5), onTimeout: () => true);
    if (!serviceEnabled) {
      return 'Location services are off. Turn on GPS, then try again.';
    }
    var permission = await _checkPermission();
    if (permission == 'denied') {
      permission = await _requestPermission();
    }
    if (permission != 'granted') {
      return 'Location permission is denied. Allow location access for '
          'Against Yesterday, then try again.';
    }
    return null;
  }

  @override
  Future<bool> canAskPermission() async {
    final permission = await _checkPermission().timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'deniedForever',
    );
    return permission == 'denied';
  }

  @override
  Stream<GpsFix> fixes() {
    return _events.receiveBroadcastStream().map((event) {
      return gpsFixFromPlatformMap(Map<String, dynamic>.from(event as Map));
    });
  }

  @override
  Future<void> openSettings() async {
    if (!await _isLocationServiceEnabled()) {
      await _method.invokeMethod<void>('openLocationSettings');
      return;
    }
    await _method.invokeMethod<void>('openAppSettings');
  }

  static Future<bool> _isLocationServiceEnabled() async {
    try {
      return await _method.invokeMethod<bool>('isLocationServiceEnabled') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String> _checkPermission() async {
    try {
      return await _method.invokeMethod<String>('checkPermission') ?? 'denied';
    } on MissingPluginException {
      return 'deniedForever';
    } on PlatformException {
      return 'deniedForever';
    }
  }

  static Future<String> _requestPermission() async {
    try {
      return await _method.invokeMethod<String>('requestPermission') ??
          'denied';
    } on MissingPluginException {
      return 'deniedForever';
    } on PlatformException {
      return 'deniedForever';
    }
  }
}