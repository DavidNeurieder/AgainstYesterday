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

  testWidgets('home shows the primary start action and catalogs', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    // Primary action per §43.
    expect(find.widgetWithText(FilledButton, 'Start a run'), findsOneWidget);

    // Section content from the seeded home directory.
    expect(find.text('River Loop'), findsWidgets);
    expect(find.text('Park 5K'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Hügelrunde'), 200);
    expect(find.text('Hügelrunde'), findsWidgets);
  });

  testWidgets('shell navigates between tabs', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    Finder tab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();
    expect(find.text('River Loop'), findsWidgets);

    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    // The seeded catalog has finished activities → History rows.
    expect(find.byIcon(Icons.directions_run), findsWidgets);

    await tester.tap(tab('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Start a run'), findsOneWidget);
  });

  testWidgets('home gear opens the settings stub', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Settings arrive in a later milestone.'), findsOneWidget);
  });

  testWidgets('start a run routes to pre-run screen', (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Start a run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);
  });
}