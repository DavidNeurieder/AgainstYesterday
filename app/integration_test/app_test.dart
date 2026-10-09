// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// On-device end-to-end tests (§45, M14+).
///
/// These run against the REAL app on an emulator/device — real wall clock,
/// real timers, real rendering — and therefore use generous timeouts instead
/// of `fakeAsync`. Run with:
///
/// ```bash
/// flutter test integration_test -d <device>
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/features/routes/presentation/routes_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:integration_test/integration_test.dart';

import '../test/test_catalog.dart';
import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records a run end to end', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    // The app ships with an empty catalog, so seed a route through the app's
    // own repository (a fresh install would get this after its first saved
    // run / imported route).
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container
        .read(routeRepositoryProvider.notifier)
        .saveRoute(riverLoopRoute);
    await tester.pumpAndSettle();

    // Home is the default tab.
    expect(find.text('Run against yesterday'), findsOneWidget);
    expect(find.text('River Loop'), findsWidgets);

    // Home → Record via the hero's race action.
    await tester.tap(find.text('RACE YOUR BEST'));
    await tester.pumpAndSettle();
    await waitForText(tester, 'READY TO RUN');
    expect(find.text('GPS READY'), findsOneWidget);
    expect(find.textContaining('Personal Best'), findsOneWidget);

    // START → the 3-2-1-GO countdown (§11) runs on the wall clock, so poll
    // for the live screen rather than assuming it after pumpAndSettle.
    await tester.tap(find.text('START'));
    await waitForText(tester, 'PACE');
    expect(find.text('TIME'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);

    // GPS advances the distance on real ticks. Poll rather than sleeping a
    // fixed two seconds: the CI emulator has no hardware acceleration, and a
    // cold GPS start can need considerably longer to deliver its first fixes.
    final before = displayedMeters(tester);
    await waitForCondition(
      tester,
      () => displayedMeters(tester) > before,
      'the distance to advance past $before m',
    );

    // Pause shows the PAUSED overlay and stops the clock.
    await tester.tap(find.text('PAUSE'));
    await tester.pumpAndSettle();
    expect(find.text('PAUSED'), findsOneWidget);

    // Resume and finish.
    await tester.tap(find.text('RESUME'));
    await tester.pumpAndSettle();
    await pumpFor(tester, const Duration(milliseconds: 800));
    await tester.tap(find.text('FINISH'));
    await waitForText(tester, 'VIEW RESULT');

    // M11: a short demo run may land on either completion header.
    final header = tester.any(find.text('RUN COMPLETE')) ||
        tester.any(find.text('NEW PERSONAL BEST'));
    expect(header, isTrue, reason: 'expected a completion header');

    // Result screen: performance bar, ranking, and the save persisted the run.
    await tester.tap(find.text('VIEW RESULT'));
    await tester.pumpAndSettle();
    expect(find.text('PERFORMANCE'), findsOneWidget);
    expect(find.textContaining('fastest run'), findsOneWidget);

    // DONE → Home now shows the finished run (empty start + this one = one
    // tile). The save runs in the background on purpose, so poll for the tile
    // rather than assuming it landed while the screens changed underneath.
    await tester.tap(find.text('DONE'));
    await waitForCondition(
      tester,
      () => tester.widgetList(find.byIcon(Icons.directions_run)).isNotEmpty,
      'the finished run to appear on Home as a tile',
      // On timeout, separate "the save never ran" (activities still 0) from
      // "the save ran but Home never rebuilt" (activities 1, tiles 0), report
      // the live run's status (still recording = the finish tap never landed),
      // and say how far the background save got / where it broke.
      diagnostics: () {
        final activities = container.read(activityRepositoryProvider).length;
        final snapshot = container.read(runSnapshotProvider);
        final status =
            container.read(recordingControllerProvider)?.status.name;
        final save = container.read(saveProgressProvider);
        return 'tiles='
            '${tester.widgetList(find.byIcon(Icons.directions_run)).length}, '
            'activities=$activities, '
            'run_snapshot=${snapshot == null ? 'null' : 'present'}, '
            'run_status=$status, save=$save';
      },
    );
    expect(find.byIcon(Icons.directions_run), findsNWidgets(1));
    expect(find.text('Run against yesterday'), findsOneWidget);
  });

  testWidgets('browses the route library', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    // The app ships with an empty catalog; seed the library through the app's
    // own repositories as a user would accumulate it.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final routes = container.read(routeRepositoryProvider.notifier);
    for (final route in demoRoutes) {
      await routes.saveRoute(route);
    }
    await container
        .read(activityRepositoryProvider.notifier)
        .saveActivity(seedActivity(id: 'act-003'));
    await container
        .read(activityRepositoryProvider.notifier)
        .saveActivity(seedActivity(id: 'act-002', routeId: parkLoopRoute.id));
    await tester.pumpAndSettle();

    // Routes tab lists the seeded catalog — scope into the NavigationBar to
    // avoid the AppBar title also matching.
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Routes'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('River Loop'), findsWidgets);
    expect(find.text('Park 5K'), findsWidgets);
    expect(find.text('Hügelrunde'), findsWidgets);

    // A course card opens its detail page — scope into RoutesScreen so the
    // IndexedStack twin copies in Home/Record don't interfere.
    await tester.tap(find.descendant(
      of: find.byType(RoutesScreen),
      matching: find.text('River Loop'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Personal Best'), findsOneWidget);
    expect(find.text('Attempts'), findsOneWidget);

    // Back returns to the library.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Park 5K'), findsWidgets);
  });

  // -------------------------------------------------------------------------
  // Phase 12: backgrounding snapshots the run; a "relaunch" over the same
  // store resumes the interrupted run instead of starting a fresh session.
  // -------------------------------------------------------------------------
  testWidgets('restores an interrupted run across app relaunch',
      (tester) async {
    // A shared store stands in for device storage: the relaunched app reads
    // the same snapshot the backgrounded instance wrote.
    final store = MemoryPersistenceStore();
    Widget app() => ProviderScope(
          overrides: [persistenceStoreProvider.overrideWithValue(store)],
          child: const AgainstYesterdayApp(),
        );

    // "First process": seed a route (a fresh install with no catalog has no
    // race hero — RECORD ROUTE records a fresh route, it does not resume), get
    // to READY and start recording.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container
        .read(routeRepositoryProvider.notifier)
        .saveRoute(riverLoopRoute);
    await tester.pumpAndSettle();
    await tester.tap(find.text('RACE YOUR BEST'));
    await tester.pumpAndSettle();
    await waitForText(tester, 'READY TO RUN');
    await tester.tap(find.text('START'));
    await tester.pumpAndSettle();
    await waitForCondition(
      tester,
      () => displayedMeters(tester) > 0,
      'the distance to start moving',
    );
    final before = requireDisplayedMeters(tester);

    // Background: the app's lifecycle observer snapshots the interrupted run.
    // Post both transitions back-to-back: the live test binding stops
    // producing frames while `paused`, so an interleaved `pump*` would block
    // forever awaiting a frame that never renders.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(store.read('run_snapshot'), isNotNull);
    expect(requireDisplayedMeters(tester), greaterThanOrEqualTo(before));

    // "Process death": tear the tree down and relaunch over the same store.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // The snapshot is still there (and the seeded route still carries a PB ghost),
    // so Home's hero resumes it — the live screen (not the pre-run/READY
    // screen) must appear, at distance greater-or-equal to where the app died.
    await tester.tap(find.text('RACE YOUR BEST'));
    await tester.pumpAndSettle();
    await waitForText(tester, 'PACE');
    expect(find.text('TIME'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    final restored = requireDisplayedMeters(tester);
    // Deliberately not polled: the snapshot carries the distance itself, so
    // this must hold on the first render — a reset here is a real defect.
    expect(restored, greaterThanOrEqualTo(before));

    // The restored session is alive, not a static screenshot.
    await waitForCondition(
      tester,
      () => displayedMeters(tester) > restored,
      'the restored distance to advance past $restored m',
    );

    // Finishing the restored run clears the interrupted-run snapshot — but
    // only after the background save chain lands, so poll instead of guessing
    // how long that takes.
    await tester.tap(find.text('FINISH'));
    await waitForText(tester, 'VIEW RESULT');
    await waitForCondition(
      tester,
      () => store.read('run_snapshot') == 'null',
      'the interrupted-run snapshot to be cleared',
    );

    // Clean the tree so the binding is left in a good state for any later
    // test in this file/process.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}