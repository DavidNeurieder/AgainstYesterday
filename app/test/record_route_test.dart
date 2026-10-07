// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/persistence/persistence.dart';

/// M18: the record-a-route flow (§8) — prep → recording → name-and-save →
/// saved. Runs against the deterministic demo timeline: a fresh install walks
/// the demo loop during recording, so a named route really lands in the
/// catalog with its first attempt as the baseline PB.
void main() {
  Widget pumpedApp() => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
        ],
        child: const AgainstYesterdayApp(),
      );

  /// Home (empty) → the /record-route flow, GPS acquired.
  Future<void> openRecording(WidgetTester tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RECORD ROUTE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GPS READY'), findsOneWidget);
  }

  String distance(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('record-distance')))
      .data!;

  testWidgets('records, names and saves a new route with a first PB',
      (tester) async {
    await openRecording(tester);

    // START RECORDING stays locked until GPS is READY (the gate already
    // passed above, so it is live).
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'START RECORDING'),
    );
    expect(start.onPressed, isNotNull);
    await tester.tap(find.text('START RECORDING'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Recording: simpler than the race — distance + time + pause/finish.
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    final before = distance(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(distance(tester), isNot(before));

    // FINISH → name-and-save.
    await tester.tap(find.text('FINISH'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Route complete'), findsOneWidget);

    // The route needs a name; SAVE stays locked until one is typed.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'SAVE ROUTE'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'Riverside Loop');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'SAVE ROUTE'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('SAVE ROUTE'));
    await tester.pumpAndSettle();

    // Saved: the celebration shows the route's first PB.
    expect(find.text('Route saved'), findsOneWidget);
    expect(find.text('Personal best'), findsOneWidget);

    // The route — geometry, distance, count, baseline — plus the tagged
    // activity are in the repositories.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    final routes = container.read(routeRepositoryProvider);
    expect(routes, hasLength(1));
    final route = routes.single;
    expect(route.name, 'Riverside Loop');
    expect(route.attemptCount, 1);
    expect(route.personalBest, isNotNull);
    expect(route.geometry, isNotEmpty);
    expect(route.distance.meters, greaterThan(0));
    final acts = container.read(activityRepositoryProvider);
    expect(acts, hasLength(1));
    expect(acts.single.routeId, route.id);

    // DONE returns Home, which now features the new route.
    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'RACE YOUR BEST'), findsOneWidget);
    expect(find.text('Riverside Loop'), findsOneWidget);
  });

  testWidgets('pause holds the recording and resume continues it',
      (tester) async {
    await openRecording(tester);

    await tester.tap(find.text('START RECORDING'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pump(const Duration(seconds: 4));
    final before = distance(tester);

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
    final frozen = distance(tester);
    expect(frozen, before);

    // While paused, the clock and the distance are both still.
    await tester.pump(const Duration(seconds: 4));
    expect(distance(tester), frozen);

    await tester.tap(find.text('RESUME'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('PAUSED'), findsNothing);
    expect(distance(tester), isNot(frozen));
  });

  testWidgets('routes tab offers record-route as its primary action',
      (tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();

    Finder tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();
    expect(find.text('No routes yet. Record your first route.'), findsOneWidget);
    expect(find.text('Record Route'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Record Route'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('START RECORDING'), findsOneWidget);
  });
}