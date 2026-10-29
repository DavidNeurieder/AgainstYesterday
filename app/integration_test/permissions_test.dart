// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Android location-permission state machine on the real receiver (test plan
/// Phase 2.1).
///
/// The widget suite injects a fake [GpsSource] and asserts the controller's
/// reaction; this suite instead exercises *Android's* answer. The permission
/// and location-service state is established explicitly by the harness
/// (`./tool/android_integration_test.sh --permissions`) before each case, then
/// named through `--dart-define=PERMISSION_CASE=<case>`. Nothing is inherited
/// from a previous run: the harness revokes the grant and reboots the
/// provider before every case.
///
/// Cases:
///
///  * `denied`          — permission missing but still requestable. Android's
///                         own dialog cannot be answered by a test, so the
///                         harness also pre-answers it with `appops … ignore`;
///                         the app must surface the recoverable GPS error and
///                         *not* start recording.
///  * `deniedForever`   — permission permanently denied (`pm revoke` + the
///                         appops "never ask again" flag). The error screen
///                         must offer the system-settings escape hatch.
///  * `servicesOff`     — permission granted but the location master switch is
///                         off. The app must report *services*, not permission.
///  * `grantedAfterDenial` — the user denies once, then grants from settings.
///                         RETRY must reach the prep gate and start a run.
///
/// Run with:
///
/// ```bash
/// ./tool/android_integration_test.sh --permissions
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:integration_test/integration_test.dart';

import 'support.dart';

/// Mirrors the app's own define semantics (`dependencies.dart`).
const String _useDeviceGps = String.fromEnvironment('USE_DEVICE_GPS');

/// When `true`, this suite must actually run: a missing `USE_DEVICE_GPS` is a
/// hard failure here rather than a silent skip, mirroring
/// `REQUIRE_DEVICE_GPS` in the device-GPS suite.
const String _requireDeviceGps = String.fromEnvironment('REQUIRE_DEVICE_GPS');

/// Which Android permission state the harness established before this run.
const String _case = String.fromEnvironment('PERMISSION_CASE');

/// Everything onscreen plus the controller's own error, so a red run shows
/// what the app actually said instead of only that an assertion missed.
String _diagnostics(WidgetTester tester, ProviderContainer container) {
  final live = container.read(recordingControllerProvider);
  final screen = tester.allWidgets
      .whereType<Text>()
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  return 'case=$_case, status=${live?.status.name}, '
      'error=${live?.error?.message}, screen=[$screen]';
}

/// Opens the record flow and settles whichever state the gate reaches.
///
/// A real [JsonFileStore] is installed so the §33 explanation gate behaves as
/// it does on a real phone (a hermetic store deliberately never explains). The
/// explanation only shows when Android would still offer its own dialog
/// (permission `denied`, not `deniedForever`), so it is conditional. Any of
/// the three states may land first — the explanation, the prep gate, or the
/// GPS-refusal error screen — and the case-specific test asserts which one it
/// must be.
Future<void> _openRecordFlow(WidgetTester tester, {bool seenRationale = false}) async {
  final directory = await getApplicationDocumentsDirectory();
  final store = JsonFileStore(directory);
  // A clean store per case; presetting `onboarding` skips the first-launch
  // intro, which is not what this suite is about.
  await store.write(
    'settings',
    '{"onboarding":true,"locationRationale":$seenRationale}',
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [persistenceStoreProvider.overrideWithValue(store)],
      child: const AgainstYesterdayApp(),
    ),
  );
  await tester.pumpAndSettle();
  await dismissOnboardingIfPresent(tester);
  await tester.tap(find.text('RECORD ROUTE'));
  await tester.pumpAndSettle();

  final continueButton = find.byKey(
    const ValueKey('location-rationale-continue'),
  );
  await waitForCondition(
    tester,
    () =>
        tester.any(continueButton) ||
        tester.any(find.text('GPS READY')) ||
        tester.any(find.text('GPS UNAVAILABLE')),
    'the location explanation, GPS READY, or the GPS error screen',
    timeout: const Duration(seconds: 30),
    diagnostics: () {
      final screen = tester.allWidgets
          .whereType<Text>()
          .map((widget) => widget.data)
          .whereType<String>()
          .join(' | ');
      return 'screen=[$screen]';
    },
  );
  if (tester.any(continueButton)) {
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
  }
}

/// Waits for the recoverable GPS error screen the permission cases share.
Future<void> _waitForGpsRefusal(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await waitForCondition(
    tester,
    () => tester.any(find.text('GPS UNAVAILABLE')),
    'the GPS UNAVAILABLE error screen',
    timeout: const Duration(seconds: 60),
    diagnostics: () => _diagnostics(tester, container),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (_requireDeviceGps == 'true' && _useDeviceGps != 'true') {
    throw StateError(
      'REQUIRE_DEVICE_GPS=true but USE_DEVICE_GPS is not true; the permission '
      'suite would silently exercise the demo timeline. Pass '
      '--dart-define=USE_DEVICE_GPS=true.',
    );
  }

  testWidgets('a denied permission surfaces a recoverable error, not a run',
      (tester) async {
    await _openRecordFlow(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    await _waitForGpsRefusal(tester, container);

    // The copy names the permission, not the engine.
    expect(
      find.textContaining('Location permission is denied'),
      findsOneWidget,
    );

    // The recording must NOT have started: no live screen, no START button
    // past the gate, and the controller is in `error`.
    expect(find.text('FINISH'), findsNothing);
    expect(container.read(recordingControllerProvider)?.status, RunStatus.error);

    // Retry is always offered; the settings shortcut is offered here too.
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Open location settings'), findsOneWidget);
  }, skip: _case != 'denied');

  testWidgets('a permanently denied permission offers the settings path',
      (tester) async {
    await _openRecordFlow(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    await _waitForGpsRefusal(tester, container);

    // Permanent denial is indistinguishable in copy from a plain denial —
    // what differs is that Android will never show its own dialog again, so
    // the app must point the user at system settings. That button must be
    // present and tappable (tapping it would leave the app, so we assert its
    // presence only).
    expect(find.textContaining('Location permission is denied'), findsOneWidget);
    expect(find.text('Open location settings'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(container.read(recordingControllerProvider)?.status, RunStatus.error);
  }, skip: _case != 'deniedForever');

  testWidgets('location services off is reported as such, not as permission',
      (tester) async {
    await _openRecordFlow(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    await _waitForGpsRefusal(tester, container);

    // A granted permission with the master switch off must name the services,
    // never the permission — otherwise the user is sent to the wrong screen.
    expect(
      find.textContaining('Location services are off'),
      findsOneWidget,
    );
    expect(find.textContaining('Location permission is denied'), findsNothing);
    expect(find.text('Open location settings'), findsOneWidget);
    expect(container.read(recordingControllerProvider)?.status, RunStatus.error);
  }, skip: _case != 'servicesOff');

  testWidgets('a run starts once the permission is granted after a denial',
      (tester) async {
    // The harness revokes the permission, then this test relies on a background
    // grant loop (started by the harness for exactly this case) to flip it
    // while the app sits on the error screen. RETRY then has to reach READY.
    await _openRecordFlow(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    await _waitForGpsRefusal(tester, container);
    expect(container.read(recordingControllerProvider)?.status, RunStatus.error);

    // The harness grants ACCESS_FINE_LOCATION a moment after the refusal is on
    // screen; press RETRY in a loop until the gate opens rather than guessing
    // the delay, so the RETRY → READY recovery is genuinely exercised.
    //
    // The tap and the pump live here, not inside the predicate: calling
    // `tester.tap` from within `waitForCondition` trips the framework's async
    // guard.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var ready = false;
    while (DateTime.now().isBefore(deadline)) {
      if (tester.any(find.text('GPS READY'))) {
        ready = true;
        break;
      }
      final retry = find.text('Try again');
      if (tester.any(retry)) {
        await tester.tap(retry, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 600));
      } else {
        await tester.pump(const Duration(milliseconds: 600));
      }
    }
    expect(ready, isTrue,
        reason: 'GPS READY after the permission was granted; '
            '${_diagnostics(tester, container)}');

    // The gate is genuinely open: the run can start.
    await tester.pumpAndSettle();
    expect(find.text('START RECORDING'), findsOneWidget);
  }, skip: _case != 'grantedAfterDenial');
}
