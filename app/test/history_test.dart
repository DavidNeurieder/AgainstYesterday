// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/history/application/history_grouping.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  Finder tab(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  /// The app behind the seeded catalog; History shows the two demo runs.
  Widget pumpedApp() => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: demoRoutes, activities: demoActivities()),
          ),
        ],
        child: const AgainstYesterdayApp(),
      );

  Activity activity({
    required String id,
    required DateTime startedAt,
    String? routeId,
    int? seconds,
  }) =>
      Activity(
        id: id,
        routeId: routeId,
        startedAt: startedAt,
        duration: seconds == null ? null : Elapsed.seconds(seconds.toDouble()),
        distance: const Distance.kilometers(4.75),
      );

  group('groupByMonth', () {
    test('groups by calendar month, newest month and activity first', () {
      final groups = groupByMonth([
        activity(id: 'a', startedAt: DateTime(2026, 10, 5, 9)),
        activity(id: 'b', startedAt: DateTime(2026, 10, 12, 9)),
        activity(id: 'c', startedAt: DateTime(2025, 12, 30, 9)),
      ], now: DateTime(2026, 10, 20));

      expect(groups, hasLength(2));
      expect(groups.first.label, 'October');
      expect([for (final a in groups.first.activities) a.id], ['b', 'a']);
      expect(groups.last.label, 'December 2025');
      expect(groups.last.activities.single.id, 'c');
    });

    test('same month in an earlier year gets the year suffix', () {
      final groups = groupByMonth([
        activity(id: 'a', startedAt: DateTime(2025, 10, 5, 9)),
        activity(id: 'b', startedAt: DateTime(2026, 10, 5, 9)),
      ], now: DateTime(2026, 10, 20));

      expect([for (final g in groups) g.label], ['October', 'October 2025']);
    });
  });

  group('computeHistoryPb', () {
    final seedRoutes = [
      const Route(
        id: 'river-loop',
        name: 'River Loop',
        distance: Distance.kilometers(4.76),
        geometry: [],
        personalBest: Elapsed.seconds(1470),
      ),
      const Route(
        id: 'park-5k',
        name: 'Park 5K',
        distance: Distance.kilometers(5.0),
        geometry: [],
        personalBest: Elapsed.seconds(1625),
      ),
      const Route(
        id: 'no-seed',
        name: 'No Seed',
        distance: Distance.kilometers(3.0),
        geometry: [],
      ),
    ];

    test('marks chronological improvers and keeps the current best', () {
      final pb = computeHistoryPb(
        [
          activity(
            id: 'slow',
            startedAt: DateTime(2026, 1, 1),
            routeId: 'river-loop',
            seconds: 1502,
          ),
          activity(
            id: 'fast',
            startedAt: DateTime(2026, 2, 1),
            routeId: 'river-loop',
            seconds: 1400,
          ),
          activity(
            id: 'middle',
            startedAt: DateTime(2026, 3, 1),
            routeId: 'river-loop',
            seconds: 1450,
          ),
        ],
        seedRoutes,
      );

      expect(pb.pbSetters, {'fast'});
      expect(pb.bestSeconds['river-loop'], 1400);
    });

    test('ties the seed, unknown routes and seedless first runs', () {
      final pb = computeHistoryPb(
        [
          activity(
            id: 'tie',
            startedAt: DateTime(2026, 1, 1),
            routeId: 'park-5k',
            seconds: 1625,
          ),
          activity(
            id: 'unroutable',
            startedAt: DateTime(2026, 1, 1),
            seconds: 900,
          ),
          activity(
            id: 'first',
            startedAt: DateTime(2026, 1, 1),
            routeId: 'no-seed',
            seconds: 900,
          ),
        ],
        seedRoutes,
      );

      expect(pb.pbSetters, {'first'});
      expect(pb.bestSeconds['park-5k'], 1625);
      expect(pb.bestSeconds.containsKey('unroutable'), isFalse);
      expect(pb.bestSeconds['no-seed'], 900);
    });
  });

  group('History screen', () {
    testWidgets('groups the catalog under a month header', (tester) async {
      await tester.pumpWidget(pumpedApp());
      await tester.pumpAndSettle();

      await tester.tap(tab('History'));
      await tester.pumpAndSettle();

      // The seeded runs are from January 2026 — one group, current-year label.
      expect(find.text('January'), findsOneWidget);
      expect(find.text('River Loop'), findsWidgets); // chip + row
      expect(find.text('Park 5K'), findsWidgets);
      expect(find.textContaining('4.75 km ·'), findsNWidgets(2));
      expect(find.text('2 Jan 2026'), findsNothing); // grouped, not per-row dates
    });

    testWidgets('rows show a PB trophy and a delta versus the route PB',
        (tester) async {
      await tester.pumpWidget(pumpedApp());
      await tester.pumpAndSettle();

      await tester.tap(tab('History'));
      await tester.pumpAndSettle();

      // Park 5K's 1502 s beats its 1625 s seed → trophy; River Loop's
      // 1502 s sits 32 s behind its 1470 s seed → +0:32.
      expect(find.byIcon(Icons.emoji_events), findsOneWidget);
      expect(find.byIcon(Icons.directions_run), findsOneWidget);
      expect(find.text('+0:32'), findsOneWidget);

      // Row content lives inside cards; the route chip shares the name.
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('Park 5K'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('route chip filters the list, All restores it', (tester) async {
      await tester.pumpWidget(pumpedApp());
      await tester.pumpAndSettle();

      await tester.tap(tab('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('filter-route-park-5k')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('Park 5K'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('River Loop'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('filter-all')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('River Loop'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('PBs only keeps trophy runs; empty filters say so',
        (tester) async {
      await tester.pumpWidget(pumpedApp());
      await tester.pumpAndSettle();

      await tester.tap(tab('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('filter-pb-only')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('Park 5K'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('River Loop'),
        ),
        findsNothing,
      );

      // River Loop has no PB run in the fixture → the filter empties out.
      await tester.tap(find.byKey(const ValueKey('filter-route-river-loop')));
      await tester.pumpAndSettle();
      expect(find.text('No runs match this filter.'), findsOneWidget);
    });
  });
}
