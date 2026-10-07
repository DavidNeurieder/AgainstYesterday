// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/app/router.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/features/dev/application/fixture_export.dart';
import 'package:against_yesterday/features/dev/presentation/diagnostics_screen.dart';
import 'package:against_yesterday/features/home/presentation/home_screen.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

/// M15 Phase 10: the developer diagnostics entry point and screen.
void main() {
  Widget app() => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    routerConfig: buildRouter(),
  );

  ProviderScope enabledApp() => ProviderScope(
    overrides: [
      devToolsEnabledProvider.overrideWithValue(true),
      // Seed a route so a live run has geometry and a PB ghost to race —
      // the shipped app starts with an empty catalog.
      persistenceStoreProvider.overrideWithValue(
        seededStore(routes: [riverLoopRoute]),
      ),
    ],
    child: app(),
  );

  List<String> mockClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform', JSONMethodCodec()),
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text']! as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform', JSONMethodCodec()),
        null,
      );
    });
    return copied;
  }

  Future<void> goToDiagnostics(WidgetTester tester) async {
    // The record flow is a pushed full-screen route (M16) with no shell
    // chrome, so reach diagnostics through the router instead of the floating
    // dev-tools button — whether the caller is on Home or in a live run.
    final where = find.byType(LiveRunScreen).evaluate().isEmpty
        ? find.byType(HomeScreen)
        : find.byType(LiveRunScreen);
    GoRouter.of(tester.element(where)).go('/dev/diagnostics');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> startLiveRun(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Start a run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  // The recording timer runs forever, so `pumpAndSettle` would never return
  // once a run is live. Advance just enough for a dialog/snackbar transition.
  Future<void> settleTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('dev button is hidden by default', (tester) async {
    await tester.pumpWidget(ProviderScope(child: app()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dev-diagnostics')), findsNothing);
  });

  testWidgets('the dev route is blocked when the gate is off', (tester) async {
    await tester.pumpWidget(ProviderScope(child: app()));
    await tester.pumpAndSettle();

    GoRouter.of(tester.element(find.byType(HomeScreen))).go('/dev/diagnostics');
    await tester.pumpAndSettle();

    expect(find.byType(DiagnosticsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('dev gate exposes diagnostics and the engine identity', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(enabledApp());
    await tester.pumpAndSettle();

    await goToDiagnostics(tester);

    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
    // The readout must name the engine actually wired in, whichever it is —
    // the native Rust engine when its library loaded, else the deterministic
    // demo fallback.
    final engine = ProviderScope.containerOf(
      tester.element(find.byType(DiagnosticsScreen)),
    ).read(engineServiceProvider);
    expect(
      engine.engineDescription,
      anyOf('fake (deterministic demo)', startsWith('rust v')),
    );
    expect(find.text(engine.engineDescription), findsOneWidget);
  });

  testWidgets('a live run populates the GPS / TRACK / GHOST readouts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(enabledApp());
    await tester.pumpAndSettle();

    await startLiveRun(tester);
    await goToDiagnostics(tester);

    // GPS: the fake engine circles the river loop at 52.5°N.
    expect(
      find.descendant(
        of: find.byType(DiagnosticsScreen),
        matching: find.textContaining('52.5'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(DiagnosticsScreen),
        matching: find.text('4:57 /km'),
      ),
      findsOneWidget,
    );
    // TRACK: raw fixes are retained and processed points synthesised.
    expect(find.text('Raw fixes'), findsOneWidget);
    expect(find.text('Session points'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    // GHOST: River Loop carries a PB, so the live run races one.
    expect(find.text('Racing'), findsOneWidget);
    expect(find.text('yes'), findsOneWidget);
  });

  testWidgets('backgrounding surfaces the recovery snapshot', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(enabledApp());
    await tester.pumpAndSettle();

    await startLiveRun(tester);

    // Simulate the OS backgrounding the app while the run is live (§28).
    final container = ProviderScope.containerOf(
      tester.element(find.text('PAUSE')),
    );
    container.read(recordingControllerProvider.notifier).appBackgrounded();
    await tester.pump();

    await goToDiagnostics(tester);

    expect(find.text('PERSISTENCE'), findsOneWidget);
    expect(find.text('running'), findsWidgets);
    expect(find.text('available'), findsOneWidget);
  });

  testWidgets('export warns about privacy; cancelling copies nothing', (
    tester,
  ) async {
    final copied = mockClipboard(tester);
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(enabledApp());
    await tester.pumpAndSettle();

    await startLiveRun(tester);
    await goToDiagnostics(tester);

    await tester.tap(find.byKey(const ValueKey('export-fixture')));
    await settleTransition(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(fixturePrivacyWarning),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await settleTransition(tester);

    expect(copied, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'confirming export writes a schema-valid fixture to the clipboard',
    (tester) async {
      final copied = mockClipboard(tester);
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(enabledApp());
      await tester.pumpAndSettle();

      await startLiveRun(tester);
      await goToDiagnostics(tester);

      await tester.tap(find.byKey(const ValueKey('export-fixture')));
      await settleTransition(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-export')));
      await settleTransition(tester);

      expect(copied, hasLength(1));
      final doc = jsonDecode(copied.single) as Map<String, Object?>;
      expect(doc['schema_version'], fixtureSchemaVersion);
      expect((doc['route']! as List).length, greaterThanOrEqualTo(2));
      final fixes = doc['fixes']! as List;
      expect(fixes, isNotEmpty);
      final first = fixes.first as Map;
      expect(first['timestamp_ms'], isA<int>());
      expect(first['latitude'], closeTo(52.5, 0.01));
      expect(first['longitude'], closeTo(13.36, 0.01));
      // Every sensor field is present; the first live fix has an accuracy and
      // altitude but no predecessor, so no bearing.
      for (final field in [
        'accuracy_m',
        'altitude_m',
        'speed_mps',
        'bearing_deg',
      ]) {
        expect(first.containsKey(field), isTrue, reason: field);
      }
      expect(first['bearing_deg'], isNull);
      expect(find.text('Fixture JSON copied to clipboard.'), findsOneWidget);
    },
  );

  testWidgets(
    'a route-less recording refuses export instead of borrowing a route',
    (tester) async {
      final copied = mockClipboard(tester);
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(enabledApp());
      await tester.pumpAndSettle();

      await startLiveRun(tester);
      // Drop the detected route ('Continue without route', §11) while keeping
      // the raw fixes already received.
      final container = ProviderScope.containerOf(
        tester.element(find.text('PAUSE')),
      );
      container
          .read(recordingControllerProvider.notifier)
          .continueWithoutRoute();
      await tester.pump();

      await goToDiagnostics(tester);
      await tester.tap(find.byKey(const ValueKey('export-fixture')));
      await settleTransition(tester);

      expect(copied, isEmpty);
      expect(find.text(noRouteGeometryMessage), findsOneWidget);
    },
  );
}
