// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Real-receiver end-to-end tests (M30).
///
/// These exercise the USE_DEVICE_GPS=true path: fixes arrive through the
/// real geolocator platform channel from the phone/emulator receiver, not
/// from the demo timeline. They are skipped unless the suite is launched
/// with `--dart-define=USE_DEVICE_GPS=true`, because without a location feed
/// the acquisition gate never resolves. The harness
/// (`./tool/android_integration_test.sh --device-gps`) supplies the feed:
/// it grants location permission, and pushes 1 Hz fixes along the start
/// segment of the saved route (out-and-back over ~50 m) through the
/// emulator geo console.
///
/// Run with:
///
/// ```bash
/// ./tool/android_integration_test.sh --device-gps
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:integration_test/integration_test.dart';

import '../test/test_catalog.dart';
import 'support.dart';

/// Mirrors the app's own define semantics (`dependencies.dart`).
const String _useDeviceGps = String.fromEnvironment('USE_DEVICE_GPS');

/// Why the acquisition gate never resolved: controller state plus everything
/// onscreen (the gate screens replace their copy with the failure reason).
String _gateDiagnostics(WidgetTester tester, ProviderContainer container) {
  final live = container.read(recordingControllerProvider);
  final screen = tester.allWidgets
      .whereType<Text>()
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  return 'status=${live?.status.name}, '
      'error=${live?.error?.message}, screen=[$screen]';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Acquisition against the real receiver: service check + permission, both
  // prepared by the harness, so READY must arrive without an app fallback.
  // Generous — cold geolocator/GMS start on a headless emulator is slow.
  const gpsTimeout = Duration(seconds: 60);

  testWidgets('records a route from the device receiver', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    // Empty catalog → the home CTA records a fresh route.
    await tester.tap(find.text('RECORD ROUTE'));
    await tester.pumpAndSettle();

    // The prep gate runs the real permission/service checks; the harness
    // keeps the grant alive, so READY must show on its own.
    await waitForCondition(
      tester,
      () => tester.any(find.text('GPS READY')),
      'GPS READY on the record prep screen',
      timeout: gpsTimeout,
      diagnostics: () => _gateDiagnostics(tester, container),
    );
    expect(find.text('START RECORDING'), findsOneWidget);

    await tester.tap(find.text('START RECORDING'));
    await waitForText(tester, 'FINISH');

    // Real fixes only: the distance must clear the 0.5 m/s motion floor by
    // an unambiguous margin (the feeder walks ~5 m per second).
    await waitForCondition(
      tester,
      () => recordDistanceMeters(tester) > 15,
      'the recorded distance to advance past 15 m',
      timeout: gpsTimeout,
      diagnostics: () =>
          'distance=${recordDistanceMeters(tester)} m (device fixes only)',
    );

    // Finish → name → save → the catalog holds the new route.
    await tester.tap(find.text('FINISH'));
    await waitForText(tester, 'Route complete');
    await tester.enterText(find.byType(TextField), 'Device GPS Loop');
    // enterText only marks the widget dirty; without a build the SAVE button
    // still sees the empty name and stays disabled.
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE ROUTE'));
    await waitForText(tester, 'Route saved');
    await waitForCondition(
      tester,
      () => container.read(routeRepositoryProvider).length == 1,
      'the saved route to land in the catalog',
    );

    // DONE → Home lists it alongside the (empty) activity history. The saved
    // screen shows the route name too, so wait for the home-only title before
    // asserting the tile.
    await tester.tap(find.text('DONE'));
    await waitForText(tester, 'Run against yesterday');
    expect(find.text('Device GPS Loop'), findsOneWidget);
  }, skip: _useDeviceGps != 'true');

  testWidgets('races a saved route on the device receiver', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container
        .read(routeRepositoryProvider.notifier)
        .saveRoute(riverLoopRoute);
    await tester.pumpAndSettle();

    // Same pre-run gate as the demo suite, but fed by the real receiver.
    await tester.tap(find.text('RACE YOUR BEST'));
    await tester.pumpAndSettle();
    await waitForCondition(
      tester,
      () => tester.any(find.text('READY TO RUN')),
      'READY TO RUN on the race pre-run screen',
      timeout: gpsTimeout,
      diagnostics: () => _gateDiagnostics(tester, container),
    );
    expect(find.text('GPS READY'), findsOneWidget);
    expect(find.textContaining('Personal Best'), findsOneWidget);

    // START → the countdown runs on the wall clock, so poll for live.
    await tester.tap(find.text('START'));
    await waitForText(tester, 'PACE');
    expect(find.text('TIME'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);

    // The race axis must move under device fixes alone. The harness feeds
    // fixes along the route's start segment, so the projection along the
    // route grows from 0 instead of snapping to a foreign position.
    await waitForCondition(
      tester,
      () => displayedMeters(tester) > 15,
      'the raced distance to advance past 15 m',
      timeout: gpsTimeout,
      diagnostics: () => 'distance=${displayedMeters(tester)} m',
    );

    // Finish on the device clock; a short real run completes normally.
    await tester.tap(find.text('FINISH'));
    await waitForText(tester, 'VIEW RESULT');
    final header = tester.any(find.text('RUN COMPLETE')) ||
        tester.any(find.text('NEW PERSONAL BEST'));
    expect(header, isTrue, reason: 'expected a completion header');

    await tester.tap(find.text('VIEW RESULT'));
    await tester.pumpAndSettle();
    expect(find.text('PERFORMANCE'), findsOneWidget);

    // DONE ends the result ListView; a content-heavy result (splits, gap
    // chart, ranking) pushes it below the fold, so bring it into view and
    // wait out the 620 ms stagger before tapping.
    final done = find.text('DONE');
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await waitForCondition(
      tester,
      () => tester.any(done.hitTestable()),
      'the DONE button to become tappable',
      diagnostics: () => 'DONE rect=${tester.getRect(done)}',
    );
    await tester.tap(done);
    await waitForText(tester, 'Run against yesterday');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, skip: _useDeviceGps != 'true');
}
