// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/routes/presentation/route_detail_screen.dart';

void main() {
  Finder tab(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  testWidgets('Routes tab lists the route library with stats', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();

    expect(find.text('River Loop'), findsOneWidget);
    expect(find.text('Park 5K'), findsOneWidget);
    expect(find.text('Hügelrunde'), findsOneWidget);
    expect(find.textContaining('runs'), findsNWidgets(3));
    expect(find.text('PB'), findsNWidgets(3));
  });

  testWidgets('tapping a route card opens its detail', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('River Loop'));
    await tester.pumpAndSettle();

    // §23 blocks.
    expect(find.text('Personal Best'), findsOneWidget);
    expect(find.text('Average'), findsOneWidget);
    expect(find.text('Last'), findsOneWidget);
    expect(find.text('Performance'), findsOneWidget);

    // The seeded PB clocks in at 24:30.
    expect(find.text('24:30'), findsOneWidget);

    // Scroll down to the Attempts section which may be below the fold.
    await tester.dragUntilVisible(
      find.text('Attempts'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('Attempts'), findsOneWidget);
    // The seeded attempt is a fixed 26 hours old, so its label is "Yesterday"
    // for part of the day and an absolute date for the rest. Assert the shape
    // here — dateLabelFor's branch behaviour is covered below with an injected
    // clock, which is the part that can actually break.
    expect(
      find.textContaining(RegExp(r'^(Today|Yesterday|\d{1,2} [A-Z][a-z]{2} \d{4})$')),
      findsWidgets,
    );
  });

  group('dateLabelFor', () {
    final noon = DateTime(2026, 10, 6, 12);

    test('labels today, yesterday and older dates', () {
      expect(dateLabelFor(DateTime(2026, 10, 6, 3), now: noon), 'Today');
      expect(dateLabelFor(DateTime(2026, 10, 5, 23), now: noon), 'Yesterday');
      expect(dateLabelFor(DateTime(2026, 10, 4, 22), now: noon), '4 Oct 2026');
    });

    test('ignores the time of day on either side', () {
      expect(dateLabelFor(DateTime(2026, 10, 4, 22), now: DateTime(2026, 10, 6)),
          '4 Oct 2026');
      expect(dateLabelFor(DateTime(2026, 10, 5, 22), now: DateTime(2026, 10, 6)),
          'Yesterday');
    });

    test('crosses month and year boundaries', () {
      expect(dateLabelFor(DateTime(2026, 1, 1), now: DateTime(2026, 3, 1)),
          '1 Jan 2026');
      // Midnight-to-midnight is a whole day, so Dec 31 is "Yesterday" on Jan 1.
      expect(dateLabelFor(DateTime(2025, 12, 31), now: DateTime(2026, 1, 1)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 12, 30), now: DateTime(2026, 1, 1)),
          '30 Dec 2025');
    });

    // The seeded history that made this flaky: 26 hours before midnight lands
    // two days back, not one.
    test('a 26-hour-old attempt is not "Yesterday" just after midnight', () {
      final now = DateTime(2026, 10, 6, 0, 17);
      expect(dateLabelFor(now.subtract(const Duration(hours: 26)), now: now),
          '4 Oct 2026');
    });
  });

  // Every assertion below depends only on the y/m/d fields passed in, never on
  // the machine's timezone, so none of them can flake because CI runs in UTC.
  // The cases that are *discriminating* (they would fail the old elapsed-time
  // implementation) are the spring ones: CI runs this file once more under
  // TZ=Europe/Berlin, where the 23-hour day exists.
  group('dateLabelFor around DST transitions', () {
    test('spring forward (Europe, 30 Mar 2025 — a 23-hour day)', () {
      expect(dateLabelFor(DateTime(2025, 3, 29), now: DateTime(2025, 3, 30)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 3, 30), now: DateTime(2025, 3, 31)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 3, 30), now: DateTime(2025, 3, 30)),
          'Today');
      expect(dateLabelFor(DateTime(2025, 3, 29), now: DateTime(2025, 3, 31)),
          '29 Mar 2025');
    });

    test('spring forward (US, 9 Mar 2025)', () {
      expect(dateLabelFor(DateTime(2025, 3, 8), now: DateTime(2025, 3, 9)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 3, 9), now: DateTime(2025, 3, 10)),
          'Yesterday');
    });

    test('autumn fallback (Europe, 27 Oct 2024 / 26 Oct 2025 — 25-hour days)',
        () {
      expect(dateLabelFor(DateTime(2024, 10, 26), now: DateTime(2024, 10, 27)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 10, 26), now: DateTime(2025, 10, 27)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 10, 25), now: DateTime(2025, 10, 27)),
          '25 Oct 2025');
    });

    test('autumn fallback (US, 2 Nov 2025)', () {
      expect(dateLabelFor(DateTime(2025, 11, 1), now: DateTime(2025, 11, 2)),
          'Yesterday');
      expect(dateLabelFor(DateTime(2025, 11, 2), now: DateTime(2025, 11, 3)),
          'Yesterday');
    });
  });

  group('calendarDayDifference', () {
    test('counts calendar days, ignoring the time of day on both sides', () {
      // A naive difference of these two is 1.5 hours, i.e. 0 whole days.
      expect(calendarDayDifference(DateTime(2025, 3, 30, 23, 30),
          DateTime(2025, 3, 31, 1, 0)), 1);
      expect(calendarDayDifference(DateTime(2025, 6, 10, 23, 59),
          DateTime(2025, 6, 10, 0, 1)), 0);
    });

    test('counts a 23-hour spring day as one day', () {
      expect(
        calendarDayDifference(DateTime(2025, 3, 30), DateTime(2025, 3, 31)),
        1,
        reason: 'consecutive local midnights are 23h apart in Europe, so '
            'elapsed-time arithmetic truncates to 0',
      );
    });

    test('counts a 25-hour autumn day as one day', () {
      expect(
        calendarDayDifference(DateTime(2025, 10, 26), DateTime(2025, 10, 27)),
        1,
      );
      expect(
        calendarDayDifference(DateTime(2025, 10, 25), DateTime(2025, 10, 28)),
        3,
        reason: 'two extra hours in one day must not shift the total',
      );
    });

    test('spans month and year boundaries', () {
      expect(
          calendarDayDifference(DateTime(2026, 1, 1), DateTime(2026, 2, 1)), 31);
      expect(calendarDayDifference(DateTime(2026, 1, 31), DateTime(2026, 2, 1)),
          1);
      expect(calendarDayDifference(DateTime(2025, 12, 30), DateTime(2026, 1, 2)),
          3);
    });

    test('is negative when the later date comes first', () {
      expect(calendarDayDifference(DateTime(2025, 6, 11), DateTime(2025, 6, 10)),
          -1);
      expect(calendarDayDifference(DateTime(2025, 6, 11), DateTime(2025, 6, 11)),
          0);
    });

    test('uses each argument\'s own calendar fields, whatever its offset', () {
      // UTC and local inputs mix freely: what matters is the y/m/d on each
      // value, not the instants they represent.
      expect(
          calendarDayDifference(
              DateTime.utc(2025, 3, 30, 23), DateTime(2025, 3, 31, 1)),
          1);
      expect(
          calendarDayDifference(
              DateTime(2025, 3, 30, 1), DateTime.utc(2025, 3, 31, 23)),
          1);
      expect(
          calendarDayDifference(DateTime.utc(2025, 3, 31), DateTime.utc(2025, 3, 31)),
          0);
    });
  });
}