// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/app/app.dart';

import 'package:gps_app/widgets/performance_gap.dart';

void main() {
  Finder tab(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  /// Drives the fake-GPS acquisition to READY.
  Future<void> waitReady(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('pre-run reaches READY TO RUN with GPS', (tester) async {
    await tester.pumpWidget(const GpsApp());
    await tester.pumpAndSettle();

    await tester.tap(tab('Record'));
    await tester.pump();
    await waitReady(tester);

    expect(find.text('READY TO RUN'), findsOneWidget);
    expect(find.text('GPS READY'), findsOneWidget);
    expect(find.text('River Loop'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
  });

  testWidgets('start, live gap, pause, resume, finish, done', (tester) async {
    await tester.pumpWidget(const GpsApp());
    await tester.pumpAndSettle();

    await tester.tap(tab('Record'));
    await tester.pump();
    await waitReady(tester);

    await tester.tap(find.text('START'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);

    // Map is live: YOU + PB ghost markers on screen with a route name.
    expect(find.byKey(const ValueKey('you-marker')), findsOneWidget);
    expect(find.byKey(const ValueKey('ghost-marker')), findsOneWidget);

    // Moves during the run and shows the hero gap.
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(PerformanceGap), findsOneWidget);
    final distanceText = tester.widget<Text>(
      find.byKey(const ValueKey('live-distance')),
    ).data;
    expect(distanceText, isNot('0 m'));
    expect(distanceText, isNot('0.00 km'));

    // Pause freezes distance.
    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('live-distance'))).data,
      distanceText,
    );

    // Resume moves again.
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);

    // Run long enough (>1 km) for per-km splits to appear later.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 10));
    }

    // Finish completes the run.
    await tester.tap(find.text('FINISH'));
    await tester.pump();
    // Let the phase crossfade (M14 AnimatedSwitcher) finish so the live
    // screen and its gap are fully gone.
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data == 'RUN COMPLETE' || w.data == 'NEW PERSONAL BEST')),
      findsOneWidget,
    );
    expect(find.byType(PerformanceGap), findsNothing);

    // M11: VIEW RESULT opens the detailed result with splits visible.
    await tester.tap(find.text('VIEW RESULT'));
    await tester.pumpAndSettle();
    await waitReady(tester); // no GPS frame needed at the result screen
    expect(find.text('Splits'), findsOneWidget);

    // M10: the finished run lands in Home's recent history.
    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.directions_run), findsNWidgets(3));

    // M11: tapping the most recent activity opens its detail screen.
    await tester.tap(find.byIcon(Icons.directions_run).first);
    await tester.pumpAndSettle();
    expect(find.text('River Loop'), findsWidgets);
    expect(find.textContaining('Run on'), findsOneWidget);
  });
}