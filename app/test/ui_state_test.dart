// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// UI state coverage for the record flow (test plan Phase 11).
///
/// Pinpoints what the runner actually SEES at every phase and — crucially —
/// that the right controls appear/disappear: running → PAUSE, paused →
/// RESUME, completed → neither pause nor finish control remains.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'package:against_yesterday/widgets/performance_gap.dart';

import 'test_catalog.dart';

void main() {
  /// Drives the fake-GPS acquisition tone by tone so each phase is observed.
  /// Seeds a route so the record flow has a ghost to race (the app starts
  /// empty, so the ghost only exists when a route is picked). The flow is a
  /// pushed screen on top of the shell (M16), reached from Home's primary
  /// action.
  Future<void> openRecordFlow(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        persistenceStoreProvider.overrideWithValue(
          seededStore(routes: [riverLoopRoute]),
        ),
      ],
      child: const AgainstYesterdayApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    // Let the pushed `/record` page transition finish without crossing the
    // first 500 ms acquisition tone, so the phase assertions stay aligned.
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> waitReady(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  bool startEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'START')).enabled;

  testWidgets('acquiring GPS disables START and shows the hourglass cue',
      (tester) async {
    await openRecordFlow(tester);

    // Preparing → acquiring keep the same pre-run screen.
    expect(find.text('GETTING GPS…'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'START'), findsOneWidget);
    expect(startEnabled(tester), isFalse, reason: 'no START until the fix');

    await tester.pump(const Duration(milliseconds: 600)); // → gpsAcquiring
    expect(find.text('ACQUIRING GPS'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(startEnabled(tester), isFalse);
  });

  testWidgets('READY enables START and shows the GPS-ready chip',
      (tester) async {
    await openRecordFlow(tester);
    await waitReady(tester);

    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('GPS READY'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
    // Pre-run controls only — nothing live yet.
    expect(find.text('PAUSE'), findsNothing);
    expect(find.text('RESUME'), findsNothing);
    expect(find.text('FINISH'), findsNothing);
  });

  testWidgets('running shows PAUSE+FINISH; paused shows RESUME+FINISH',
      (tester) async {
    await openRecordFlow(tester);
    await waitReady(tester);

    await tester.tap(find.text('START'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    expect(find.text('RESUME'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600)); // first tick
    expect(find.byType(PerformanceGap), findsOneWidget);

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    expect(find.text('PAUSE'), findsNothing);
  });

  testWidgets('completed shows neither pause nor resume nor finish',
      (tester) async {
    await openRecordFlow(tester);
    await waitReady(tester);

    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('FINISH'));
    await tester.pump(); // AnimatedSwitcher starts the crossfade.
    // Let the phase crossfade (250 ms) and the headline springs in.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('VIEW RESULT'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('PAUSE'), findsNothing);
    expect(find.text('RESUME'), findsNothing);
    expect(find.text('FINISH'), findsNothing);
    expect(find.byType(PerformanceGap), findsNothing);
  });

  testWidgets('rapid pause/resume switching converges on a coherent state',
      (tester) async {
    await openRecordFlow(tester);
    await waitReady(tester);

    await tester.tap(find.text('START'));
    await tester.pump();
    // Two quick pause→resume cycles, one pump apart.
    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);

    // Paused now: the clock and distance are frozen.
    final distance = tester
        .widget<Text>(find.byKey(const ValueKey('live-distance')))
        .data;
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('live-distance'))).data,
      distance,
    );

    // One resume gets back to a running state (not wedged).
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);
  });
}