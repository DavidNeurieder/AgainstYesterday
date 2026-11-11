// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  /// The app behind a seeded catalog — the shipped app starts empty, so tests
  /// that render routes or race one seed them explicitly.
  Widget pumpedApp() => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: demoRoutes, activities: demoActivities()),
          ),
        ],
        child: const AgainstYesterdayApp(),
      );

  Finder tab(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  testWidgets('the route library is the landing screen', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    // The app opens on the full route catalog, with recording as the primary
    // action (§4).
    expect(
      find.widgetWithText(FilledButton, 'RECORD ROUTE'),
      findsOneWidget,
    );
    expect(find.text('River Loop'), findsOneWidget);
    expect(find.text('Park 5K'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Hügelrunde'), 200);
    expect(find.text('Hügelrunde'), findsOneWidget);

    // Home is gone from the shell.
    expect(tab('Home'), findsNothing);
    expect(tab('Routes'), findsOneWidget);
    expect(tab('Settings'), findsOneWidget);
    expect(tab('History'), findsOneWidget);
  });

  testWidgets('a first install opens the route library', (tester) async {
    // A real store with no settings document at all — a fresh install. There
    // is no intro to walk: the app opens straight on the route library.
    final dir = Directory.systemTemp.createTempSync('first-install');
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
        ],
        child: const AgainstYesterdayApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Against Yesterday'), findsNothing);
    expect(find.text('Race your best.'), findsNothing);
    expect(find.text('GET STARTED'), findsNothing);
    // The empty library explains itself before the first run exists.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('routes-welcome')),
        matching: find.text('Welcome to Against Yesterday'),
      ),
      findsOneWidget,
    );
    expect(find.text('No routes yet. Record your first route.'), findsOneWidget);
    // …and it names the other way in: GPX import under Settings → Data.
    expect(
      find.text('Already have a GPX track? Import it in Settings → Data.'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'RECORD ROUTE'),
      findsOneWidget,
    );
  });

  testWidgets('shell navigates between tabs', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    // The full catalog lives on the landing tab.
    expect(find.text('River Loop'), findsOneWidget);
    expect(find.text('Park 5K'), findsOneWidget);

    await tester.tap(tab('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Haptics'), findsOneWidget);
    expect(find.text('Units'), findsOneWidget);

    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    // The seeded catalog has finished activities → History rows.
    expect(find.byIcon(Icons.directions_run), findsWidgets);

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();
    expect(find.text('River Loop'), findsOneWidget);
  });

  testWidgets('the Settings tab opens the settings table', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(tab('Settings'));
    await tester.pumpAndSettle();
    // M21: the tab lands on the real settings table (§26), not a stub.
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Haptics'), findsOneWidget);
    expect(find.text('Countdown'), findsOneWidget);
    expect(find.text('Units'), findsOneWidget);
    expect(find.text('Delete all data'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(
            find.descendant(
              of: find.byKey(const ValueKey('haptics-switch')),
              matching: find.byType(Switch),
            ),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<Switch>(
            find.descendant(
              of: find.byKey(const ValueKey('countdown-switch')),
              matching: find.byType(Switch),
            ),
          )
          .value,
      isTrue,
    );
    // About sits below the fold in the scrollable list.
    await tester.scrollUntilVisible(find.text('Version'), 200);
    expect(find.text('Version'), findsOneWidget);
  });

  testWidgets('the old /routes link lands on the library', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    GoRouter.of(tester.element(find.byType(NavigationBar))).go('/routes');
    await tester.pumpAndSettle();

    expect(find.text('RECORD ROUTE'), findsOneWidget);
    expect(find.text('River Loop'), findsOneWidget);
  });

  testWidgets('a library RACE opens the pre-run flow', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await raceFromLibrary(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);
  });
}
