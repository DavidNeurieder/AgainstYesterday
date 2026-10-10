// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Keeps the Android recording foreground service matched to the device GPS
/// stream.
///
/// On Android 12+ a stopped activity makes the app "background", and Android
/// delivers no location fixes to background apps. The native
/// `RecordingForegroundService` (a `location`-type foreground service) is the
/// sanctioned way around that: while it runs the OS treats the process as
/// foreground and keeps feeding the receiver stream. The Dart side only tells
/// it to start/stop; it never touches GPS itself.
///
/// This is a platform seam in the same spirit as [MapSurface]: the controller
/// talks to it through [RunForegroundLifespan], the Android build wires the
/// real channel implementation, and everything else (host tests, desktop, the
/// deterministic scenario) uses the no-op. Since the seam is only consulted
/// while a device [GpsSource] is streaming, scenario runs never touch the
/// channel at all.
///
/// Startup is *observable*: [RunForegroundLifespan.start] reports a typed
/// failure when the platform could not start the service, and the controller
/// turns that into [BackgroundProtection.unavailable] instead of silently
/// assuming protection (Android foreground-recording hardening, Phase 1).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The platform channel the recording service is driven over.
const String recordingMethodChannelName =
    'dev.neurieder.against_yesterday/recording';

/// Why a foreground-service start attempt failed. Each value carries a
/// human-readable [message] for logs and diagnostics.
enum ForegroundStartFailure {
  /// The host has no recording channel — a missing registrar/plugin or no
  /// Flutter binding (host tests, non-Android embedders).
  unavailable(
    'No native recording service is available on this host.',
  ),

  /// Android refused on location-permission grounds (`permission-denied` /
  /// `security`).
  denied('Location permission is missing, so screen-off recording is off.'),

  /// Android reports location services as disabled.
  locationDisabled('Location services are off.'),

  /// The OS refused the start itself (`not-allowed`) — normally a background
  /// start that the current app state does not permit.
  notAllowed('Android refused to start the background recording service.'),

  /// The channel or the native service reported a generic failure.
  platform('The recording service could not be started.'),

  /// The call threw something the seam cannot classify.
  unknown('The recording service failed for an unknown reason.');

  const ForegroundStartFailure(this.message);

  final String message;
}

/// Matches [RunForegroundLifespan.start] and stop to the device receiver's
/// life: start elevation at stream subscription, restore at cancellation.
abstract interface class RunForegroundLifespan {
  /// Ask the platform to keep GPS alive with the screen off.
  ///
  /// Completes with `null` once the platform has taken the start, or a typed
  /// [ForegroundStartFailure] when it could not — a successful start is
  /// thereby distinguishable from a start request, and the caller decides
  /// what a failure means instead of assuming protection.
  Future<ForegroundStartFailure?> start();

  /// Drop back to an ordinary backgrounded app. Best effort: there is nothing
  /// meaningful to report if the stop itself fails.
  Future<void> stop();
}

/// The real implementation, backed by the native recording service. A missing
/// registrar (host tests) or a missing Flutter binding is reported as
/// [ForegroundStartFailure.unavailable], never thrown or silently swallowed.
class AndroidRunForegroundLifespan implements RunForegroundLifespan {
  const AndroidRunForegroundLifespan();

  static const MethodChannel _channel =
      MethodChannel(recordingMethodChannelName);

  @override
  Future<ForegroundStartFailure?> start() async {
    try {
      await _channel.invokeMethod<void>('startRecording');
      return null;
    } on PlatformException catch (error) {
      return mapForegroundStartFailure(error);
    } on MissingPluginException {
      return ForegroundStartFailure.unavailable;
    } on FlutterError {
      // No Flutter binding (bare host tests have no binary messenger), so
      // the channel cannot exist either — same no-op as a missing plugin.
      return ForegroundStartFailure.unavailable;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopRecording');
    } on MissingPluginException {
      // No host registrar: nothing to drop back from.
    } on FlutterError {
      // No Flutter binding: nothing to drop back from.
    }
  }
}

/// Translates a native platform error into the typed [ForegroundStartFailure]
/// the controller understands. A recovery-friendly, user-visible code beats a
/// raw native message; unknown codes fall back to [platform].
@visibleForTesting
ForegroundStartFailure mapForegroundStartFailure(PlatformException error) {
  return switch (error.code) {
    'permission-denied' || 'security' => ForegroundStartFailure.denied,
    'location-disabled' => ForegroundStartFailure.locationDisabled,
    'not-allowed' => ForegroundStartFailure.notAllowed,
    'start-failed' => ForegroundStartFailure.platform,
    _ => ForegroundStartFailure.unknown,
  };
}

/// No-op for hosts with no recording service (tests, desktop, web).
class NoopRunForegroundLifespan implements RunForegroundLifespan {
  const NoopRunForegroundLifespan();

  @override
  Future<ForegroundStartFailure?> start() async => null;

  @override
  Future<void> stop() async {}
}

/// The lifespan for the current platform: the native service on Android, a
/// no-op everywhere else. Tests override this with a recording fake to assert
/// the service tracks the device stream.
final runForegroundLifespanProvider = Provider<RunForegroundLifespan>(
  (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const AndroidRunForegroundLifespan()
      : const NoopRunForegroundLifespan(),
);