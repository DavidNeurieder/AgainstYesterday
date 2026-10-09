// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Fixed-outcome race tests (test plan Phase 2).
///
/// The demo timeline always outruns its jittered ghost, so the on-device suites
/// can only accept either completion header (`app_test.dart`,
/// `device_gps_test.dart`). Here a [LinearGhostEngine] makes the reference time
/// exact, so a scripted run pins the gap's sign and magnitude, and the
/// completion header is asserted for the ahead, behind, and exact-tie
/// boundaries.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/features/recording/presentation/run_complete_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'gps_fixtures.dart';
import 'race_fixtures.dart';

void main() {
  ({ProviderContainer container, ScriptedGpsSource source}) harness() {
    final source = ScriptedGpsSource();
    final container = ProviderContainer(
      overrides: [
        deviceGpsProvider.overrideWithValue(source),
        engineServiceProvider.overrideWithValue(
          LinearGhostEngine(ghostSpeedMps: raceGhostSpeedMps),
        ),
        persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
      ],
    );
    final sub = container.listen(recordingControllerProvider, (_, _) {});
    addTearDown(() async {
      await source.close();
      sub.close();
      container.dispose();
    });
    return (container: container, source: source);
  }

  LiveRunState live(ProviderContainer c) =>
      c.read(recordingControllerProvider)!;

  RecordingController controller(ProviderContainer c) =>
      c.read(recordingControllerProvider.notifier);

  /// Boots to READY on [raceRoute], starts, and replays a run that covers
  /// [fraction] of the line in [movingSeconds], then finishes.
  GhostState runToFinish(
    FakeAsync async, {
    required double fraction,
    required double movingSeconds,
  }) {
    final h = harness();
    final ctrl = controller(h.container);
    ctrl.ensureSession([raceRoute]);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(live(h.container).status, RunStatus.ready);
    ctrl.beginRun();
    async.flushMicrotasks();

    h.source.replay(
      async,
      raceScenario(fraction: fraction, movingSeconds: movingSeconds),
    );

    ctrl.finishRun();
    async.flushMicrotasks();
    final s = live(h.container);
    expect(s.status, RunStatus.completed);
    expect(s.ghostGap, isNotNull);
    return s.ghostGap!;
  }

  group('the gap follows the fixed ghost', () {
    test('ahead of a linear ghost is a negative difference', () {
      fakeAsync((async) {
        // 60 s quicker than the ghost over the whole line; at the halfway
        // point the projection shows half the advantage.
        final gap = runToFinish(
          async,
          fraction: 0.5,
          movingSeconds: raceReferenceSeconds(1.0) - 60,
        );
        expect(gap.ahead, isTrue);
        expect(gap.timeDifference.seconds, closeTo(-30, 0.5));
      });
    });

    test('behind a linear ghost is a positive difference', () {
      fakeAsync((async) {
        final gap = runToFinish(
          async,
          fraction: 0.5,
          movingSeconds: raceReferenceSeconds(1.0) + 60,
        );
        expect(gap.ahead, isFalse);
        expect(gap.timeDifference.seconds, closeTo(30, 0.5));
      });
    });

    test('the magnitude scales with how far along the line the runner is', () {
      fakeAsync((async) {
        // The same 60 s advantage, but only a quarter of the way in.
        final gap = runToFinish(
          async,
          fraction: 0.25,
          movingSeconds: raceReferenceSeconds(1.0) - 60,
        );
        expect(gap.ahead, isTrue);
        expect(gap.timeDifference.seconds, closeTo(-15, 0.5));
      });
    });
  });

  group('the completion header', () {
    LiveRunState completed({GhostState? gap}) => LiveRunState(
          status: RunStatus.completed,
          elapsed: const Elapsed.seconds(222),
          distance: Distance.meters(raceLineLengthMeters),
          pace: const Speed.zero(),
          routeProgress: 1,
          ghostGap: gap,
          route: raceRoute,
        );

    GhostState ghost({required double seconds, required bool ahead}) =>
        GhostState(
          distance: Distance.meters(raceLineLengthMeters),
          timeDifference: Elapsed.seconds(seconds),
          ahead: ahead,
        );

    Future<void> pumpComplete(WidgetTester tester, LiveRunState state) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: RunCompleteScreen(state: state)),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// How many completion headers are on screen (must always be exactly one).
    int headers(WidgetTester tester) =>
        find.text('RUN COMPLETE').evaluate().length +
        find.text('NEW PERSONAL BEST').evaluate().length;

    testWidgets('ahead of the ghost celebrates a personal best', (tester) async {
      await pumpComplete(
        tester,
        completed(gap: ghost(seconds: -30, ahead: true)),
      );
      expect(find.text('NEW PERSONAL BEST'), findsOneWidget);
      expect(find.text('RUN COMPLETE'), findsNothing);
      expect(headers(tester), 1);
      expect(find.byIcon(Icons.emoji_events), findsOneWidget);
    });

    testWidgets('behind the ghost is a plain completion', (tester) async {
      await pumpComplete(
        tester,
        completed(gap: ghost(seconds: 30, ahead: false)),
      );
      expect(find.text('RUN COMPLETE'), findsOneWidget);
      expect(find.text('NEW PERSONAL BEST'), findsNothing);
      expect(headers(tester), 1);
      expect(find.byIcon(Icons.emoji_events), findsNothing);
    });

    testWidgets('exactly at the PB is a completion, not a new best',
        (tester) async {
      // The boundary rule: a PB needs a *strictly* negative gap, so an exact
      // tie reads as RUN COMPLETE.
      await pumpComplete(
        tester,
        completed(gap: ghost(seconds: 0, ahead: true)),
      );
      expect(find.text('RUN COMPLETE'), findsOneWidget);
      expect(find.text('NEW PERSONAL BEST'), findsNothing);
      expect(headers(tester), 1);
      expect(find.byIcon(Icons.emoji_events), findsNothing);
    });

    testWidgets('a run with no ghost is a plain completion', (tester) async {
      await pumpComplete(tester, completed());
      expect(find.text('RUN COMPLETE'), findsOneWidget);
      expect(headers(tester), 1);
    });
  });
}
