// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// M19: racing a specific route (§9–§11).
///
/// Every race entry — Home's hero, a courses-tab RACE button, a route
/// detail's RACE YOUR BEST — lands on that route's pre-race screen, and
/// START plays the 3-2-1-GO countdown before the live run begins. The app
/// ships with an empty catalog, so routes are seeded explicitly.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/routes/presentation/routes_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  Widget app({List<Route> routes = const []}) => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(seededStore(routes: routes)),
        ],
        child: const AgainstYesterdayApp(),
      );

  /// Drives the fake-GPS acquisition to READY.
  Future<void> waitReady(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('the hero race counts down 3-2-1-GO into a live run',
      (tester) async {
    await tester.pumpWidget(app(routes: demoRoutes));
    await tester.pumpAndSettle();

    // The hero races the featured route — its pre-race names it.
    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await waitReady(tester);
    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('River Loop'), findsWidgets); // AppBar + route card
    expect(find.text('NEW PERSONAL BEST'), findsNothing);

    // START begins the countdown, not the run: 3 → 2 → 1 → GO!.
    await tester.tap(find.text('START'));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('PAUSE'), findsNothing);
    expect(find.text('FINISH'), findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('2'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GO!'), findsOneWidget);

    // At GO the live screen appears and the countdown is gone.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);

    // Let the GO!→live crossfade finish (M16 AnimatedSwitcher).
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('GO!'), findsNothing);
  });

  testWidgets('a routes-tab card races exactly its own route', (tester) async {
    await tester.pumpWidget(app(routes: demoRoutes));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Routes'),
    ));
    await tester.pumpAndSettle();

    // Park 5K's card RACE leads to Park 5K's pre-race.
    await tester.tap(find.descendant(
      of: find.widgetWithText(Card, 'Park 5K'),
      matching: find.text('RACE'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await waitReady(tester);

    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('Park 5K'), findsWidgets);
    expect(find.textContaining('Personal Best'), findsOneWidget);
    expect(find.text('River Loop'), findsNothing);
  });

  testWidgets('the route detail races the route you are looking at',
      (tester) async {
    await tester.pumpWidget(app(routes: demoRoutes));
    await tester.pumpAndSettle();

    // Open Park 5K's detail page.
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Routes'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(RoutesScreen),
      matching: find.text('Park 5K'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('RACE YOUR BEST'), findsOneWidget);

    // RACE YOUR BEST from the detail keeps racing Park 5K, not the featured
    // River Loop.
    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await waitReady(tester);

    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('Park 5K'), findsWidgets);
    expect(find.text('River Loop'), findsNothing);
  });

  testWidgets('the result offers RACE AGAIN back into a fresh pre-race',
      (tester) async {
    await tester.pumpWidget(app(routes: demoRoutes));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await waitReady(tester);
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('FINISH'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('VIEW RESULT'));
    await tester.pumpAndSettle();
    expect(find.text('RACE AGAIN'), findsOneWidget);

    // RACE AGAIN leaves the finished session and drops into the same route's
    // pre-race: fresh, headed for READY, countdown still in front of it.
    await tester.tap(find.widgetWithText(FilledButton, 'RACE AGAIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await waitReady(tester);
    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('River Loop'), findsWidgets);
    expect(find.text('PAUSE'), findsNothing);
  });
}