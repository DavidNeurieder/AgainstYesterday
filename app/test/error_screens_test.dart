// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// §33 error screens: the race's route-load failure and the finish/result
/// save-error block — same skeleton, same recovery-first copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/presentation/record_flow_screen.dart';
import 'package:against_yesterday/features/recording/presentation/run_complete_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

/// Wraps [inner] so `routes` reads as empty until [open] flips — RETRY after
/// a load failure finds the route that was "missing" before.
class _GateStore implements PersistenceStore {
  _GateStore(this.inner);

  final PersistenceStore inner;
  bool open = false;

  @override
  String? read(String key) => open ? inner.read(key) : null;

  @override
  Future<void> write(String key, String value) => inner.write(key, value);

  @override
  void remove(String key) => inner.remove(key);
}

void main() {
  group('route load failure (§33)', () {
    testWidgets('an unknown race route shows COULDN\'T LOAD ROUTE with RETRY',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(seededStore()),
        ],
        child: const MaterialApp(home: RecordFlowScreen(routeId: 'missing')),
      ));
      await tester.pumpAndSettle();

      expect(find.text('COULDN\'T LOAD ROUTE'), findsOneWidget);
      expect(find.text('Try again.'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);
      // The pre-run never appears for a route that cannot load.
      expect(find.text('READY TO RUN'), findsNothing);

      // RETRY reloads the catalog — still missing, still no crash.
      await tester.tap(find.text('RETRY'));
      await tester.pumpAndSettle();
      expect(find.text('COULDN\'T LOAD ROUTE'), findsOneWidget);
    });

    testWidgets('RETRY recovers once the route is back in the catalog',
        (tester) async {
      final store = _GateStore(seededStore(routes: [riverLoopRoute]));
      await tester.pumpWidget(ProviderScope(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: RecordFlowScreen(routeId: riverLoopRoute.id),
        ),
      ));
      await tester.pumpAndSettle();
      // The first catalog read saw nothing, so the session came up missing.
      expect(find.text('COULDN\'T LOAD ROUTE'), findsOneWidget);

      store.open = true;
      await tester.tap(find.text('RETRY'));
      await tester.pump();
      // Acquisition runs on the fake GPS clock — same recipe as the flow tests.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('COULDN\'T LOAD ROUTE'), findsNothing);
      expect(find.text('READY TO RUN'), findsOneWidget);
    });
  });

  group('save error block (§33)', () {
    Widget screen({required bool unsaved}) => ProviderScope(
          child: MaterialApp(
            home: RunCompleteScreen(
              state: LiveRunState(
                status: RunStatus.completed,
                elapsed: const Elapsed.seconds(300),
                distance: const Distance.meters(1200),
                pace: const Speed.metersPerSecond(3.2),
                routeProgress: 1.0,
                hasUnsavedData: unsaved,
              ),
            ),
          ),
        );

    testWidgets('a failed disk write offers TRY AGAIN on the finish screen',
        (tester) async {
      await tester.pumpWidget(screen(unsaved: true));
      await tester.pumpAndSettle();

      expect(find.text('COULDN\'T SAVE ACTIVITY'), findsOneWidget);
      expect(
        find.text('Your activity is safely stored and can be retried.'),
        findsOneWidget,
      );

      // Tapping runs retrySave — with nothing held (no failed session) it is
      // a silent no-op, never an error.
      await tester.tap(find.widgetWithText(FilledButton, 'TRY AGAIN'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a saved run shows no save block', (tester) async {
      await tester.pumpWidget(screen(unsaved: false));
      await tester.pumpAndSettle();

      expect(find.text('COULDN\'T SAVE ACTIVITY'), findsNothing);
      expect(find.text('TRY AGAIN'), findsNothing);
    });
  });
}
