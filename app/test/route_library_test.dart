import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/app/app.dart';
import 'package:gps_app/features/routes/presentation/route_detail_screen.dart';

void main() {
  Finder tab(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  testWidgets('Routes tab lists the route library with stats', (tester) async {
    await tester.pumpWidget(const GpsApp());
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
    await tester.pumpWidget(const GpsApp());
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
}