// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The Android recording channel reports startup outcomes faithfully.
///
/// Phase 1 of the foreground-recording hardening makes service startup
/// observable: a successful start must be distinguishable from a start
/// request, and every native failure must surface as a typed
/// [ForegroundStartFailure] instead of being swallowed or crashing the run.
/// These tests exercise [AndroidRunForegroundLifespan] against a mocked
/// binary messenger.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/features/recording/application/run_foreground_lifespan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(recordingMethodChannelName);
  final messenger =
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a clean native start completes null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'startRecording');
      return null;
    });

    expect(await const AndroidRunForegroundLifespan().start(), isNull);
  });

  test('native error codes map onto typed failures', () async {
    const expected = <String, ForegroundStartFailure>{
      'not-allowed': ForegroundStartFailure.notAllowed,
      'permission-denied': ForegroundStartFailure.denied,
      'security': ForegroundStartFailure.denied,
      'location-disabled': ForegroundStartFailure.locationDisabled,
      'start-failed': ForegroundStartFailure.platform,
      'some-unexpected-code': ForegroundStartFailure.unknown,
    };

    for (final entry in expected.entries) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: entry.key);
      });
      expect(
        await const AndroidRunForegroundLifespan().start(),
        entry.value,
        reason: 'for native code ${entry.key}',
      );
    }
  });

  test('no handler is reported as unavailable, not thrown', () async {
    // No mock handler registered: the messenger answers with nothing.
    expect(
      await const AndroidRunForegroundLifespan().start(),
      ForegroundStartFailure.unavailable,
    );
  });

  test('mapForegroundStartFailure is the single mapping source', () {
    expect(
      mapForegroundStartFailure(
        PlatformException(code: 'permission-denied'),
      ),
      ForegroundStartFailure.denied,
    );
    expect(
      mapForegroundStartFailure(PlatformException(code: 'not-allowed')),
      ForegroundStartFailure.notAllowed,
    );
    expect(
      mapForegroundStartFailure(PlatformException(code: 'nope')),
      ForegroundStartFailure.unknown,
    );
  });

  test('stop is silent when no registrar exists', () async {
    await const AndroidRunForegroundLifespan().stop();
  });
}