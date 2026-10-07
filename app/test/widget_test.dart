// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('home leads into the race loop', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    // Primary action per §4: race the featured route.
    expect(find.widgetWithText(FilledButton, 'RACE YOUR BEST'), findsOneWidget);

    // Hero content from the seeded home directory.
    expect(find.text('READY TO RACE'), findsOneWidget);
    expect(find.text('River Loop'), findsOneWidget); // featured route
    expect(find.text('PB'), findsOneWidget);

    // Recent activity stays on Home; the full route catalog lives on Routes.
    expect(find.byIcon(Icons.directions_run), findsWidgets);
  });

  testWidgets('shell navigates between tabs', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    Finder tab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();
    // The full catalog lives on the Routes tab (§4 Home features one route).
    expect(find.text('River Loop'), findsWidgets);
    expect(find.text('Park 5K'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Hügelrunde'), 200);
    expect(find.text('Hügelrunde'), findsOneWidget);

    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    // The seeded catalog has finished activities → History rows.
    expect(find.byIcon(Icons.directions_run), findsWidgets);

    await tester.tap(tab('Home'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'RACE YOUR BEST'), findsOneWidget);
  });

  testWidgets('home gear opens the settings screen', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    // M21: the gear lands on the real settings table (§26), not a stub.
    expect(find.text('Settings'), findsOneWidget);
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

  testWidgets('race your best opens the pre-run flow', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);
  });
}