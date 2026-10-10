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
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Matches [RunForegroundLifespan.start] and stop to the device receiver's
/// life: start elevation at stream subscription, restore at cancellation.
abstract interface class RunForegroundLifespan {
  /// Elevate the app to a foreground location service.
  Future<void> start();

  /// Drop back to an ordinary backgrounded app.
  Future<void> stop();
}

/// The real implementation, backed by the native recording service. A missing
/// registrar (host tests, or a non-Android embedder) is a no-op, not a crash.
class AndroidRunForegroundLifespan implements RunForegroundLifespan {
  const AndroidRunForegroundLifespan();

  static const MethodChannel _channel =
      MethodChannel('dev.neurieder.against_yesterday/recording');

  @override
  Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('startRecording');
    } on MissingPluginException {
      // No host registrar: nothing to elevate on.
    } on FlutterError {
      // No Flutter binding (bare host tests have no binary messenger), so
      // the channel cannot exist either — same no-op as a missing plugin.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopRecording');
    } on MissingPluginException {
      // No host registrar: nothing to drop back from.
    } on FlutterError {
      // No Flutter binding (bare host tests have no binary messenger), so
      // the channel cannot exist either — same no-op as a missing plugin.
    }
  }
}

/// No-op for hosts with no recording service (tests, desktop, web).
class NoopRunForegroundLifespan implements RunForegroundLifespan {
  const NoopRunForegroundLifespan();

  @override
  Future<void> start() async {}

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