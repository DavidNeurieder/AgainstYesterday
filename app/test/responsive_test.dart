// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// M24: responsive layout (§31).
///
/// The plan targets 390 × 844 and requires the 320–430 px phone range to
/// work without designing around one exact size. Every primary screen is
/// pumped at the range's edges; because `flutter test` fails the test on
/// any RenderFlex overflow, this suite doubles as the layout regression
/// net. It also covers the system font scale (§7), where the same screens
/// are pumped at 1.3× and 2.0×.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  Finder tab(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  Widget seededApp() => ProviderScope(
    overrides: [
      persistenceStoreProvider.overrideWithValue(
        seededStore(routes: demoRoutes, activities: demoActivities()),
      ),
    ],
    child: const AgainstYesterdayApp(),
  );

  /// Pins the surface to [size] logical pixels (device pixel ratio 1).
  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Pins the system font scale (Android's Settings → Display → Font size).
  void useTextScale(WidgetTester tester, double scale) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  const phoneSizes = <String, Size>{
    '320x568': Size(320, 568),
    '390x844': Size(390, 844),
    '430x932': Size(430, 932),
  };

  for (final entry in phoneSizes.entries) {
    testWidgets('browsing screens fit ${entry.key}', (tester) async {
      useSize(tester, entry.value);
      await tester.pumpWidget(seededApp());
      await tester.pumpAndSettle();

      // Home: hero + recent list (M23 entrance settles).
      expect(find.text('READY TO RACE'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'RACE YOUR BEST'),
        findsOneWidget,
      );

      // Routes tab: the full catalog.
      await tester.tap(tab('Routes'));
      await tester.pumpAndSettle();
      expect(find.text('River Loop'), findsWidgets);
      expect(find.text('Park 5K'), findsOneWidget);

      // Route detail from the catalog.
      await tester.tap(find.widgetWithText(Card, 'River Loop'));
      await tester.pumpAndSettle();
      expect(find.text('RACE YOUR BEST'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // History tab: groups, trophies, filters.
      await tester.tap(tab('History'));
      await tester.pumpAndSettle();
      expect(find.text('January'), findsOneWidget);
      expect(find.byIcon(Icons.emoji_events), findsOneWidget);

      // Activity detail from the first row (its back is a custom leading icon).
      await tester.tap(find.byType(Card).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Settings from Home's gear, scrolled to About.
      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Haptics'), findsOneWidget);
      expect(find.text('Units'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Version'), 200);
      expect(find.text('Version'), findsOneWidget);
    });

    testWidgets('the race flow fits ${entry.key}', (tester) async {
      useSize(tester, entry.value);
      await tester.pumpWidget(seededApp());
      await tester.pumpAndSettle();

      // Pre-race.
      await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('READY TO RUN'), findsOneWidget);

      // Countdown → live run.
      await tester.tap(find.text('START'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('PAUSE'), findsOneWidget);
      expect(find.text('FINISH'), findsOneWidget);

      // Finish → complete → result.
      await tester.pump(const Duration(seconds: 10));
      await tester.tap(find.text('FINISH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('confirm-finish')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == 'RUN COMPLETE' || w.data == 'NEW PERSONAL BEST'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('VIEW RESULT'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('RACE AGAIN'), 200);
      expect(find.text('RACE AGAIN'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('DONE'), 200);
      expect(find.text('DONE'), findsOneWidget);
    });
  }

  // §7/§31: Android's font-size setting (Settings → Display) scales every
  // string; the screens must hold at the runner's chosen scale too. The host
  // test font is wider than the device's, so these are conservative.
  for (final scale in const {'1.3x': 1.3, '2.0x': 2.0}.entries) {
    testWidgets('browsing screens fit a ${scale.key} font scale', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      useTextScale(tester, scale.value);
      await tester.pumpWidget(seededApp());
      await tester.pumpAndSettle();

      // Home: hero + recent list.
      expect(find.text('READY TO RACE'), findsOneWidget);

      // Routes tab, then the route detail — its stat rows put a label on the
      // left and a value on the right, which is where a big scale bites.
      await tester.tap(tab('Routes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Card, 'River Loop'));
      await tester.pumpAndSettle();
      expect(find.text('Personal Best'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Attempts'), 200);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // History tab and an activity detail.
      await tester.tap(tab('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Card).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Settings from Home's gear, through to About.
      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Version'), 200);
      expect(find.text('Version'), findsOneWidget);
    });

    testWidgets('the race flow fits a ${scale.key} font scale', (tester) async {
      useSize(tester, const Size(390, 844));
      useTextScale(tester, scale.value);
      await tester.pumpWidget(seededApp());
      await tester.pumpAndSettle();

      // Pre-race. The primary action sits below the fold once the text is
      // taller, so the runner scrolls to it — reachability is the point here.
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'RACE YOUR BEST'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('READY TO RUN'), findsOneWidget);

      // Countdown → live run.
      await tester.ensureVisible(find.text('START'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('START'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('PAUSE'), findsOneWidget);
      expect(find.text('FINISH'), findsOneWidget);

      // Finish → complete → result.
      await tester.pump(const Duration(seconds: 10));
      await tester.tap(find.text('FINISH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('confirm-finish')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == 'RUN COMPLETE' || w.data == 'NEW PERSONAL BEST'),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('VIEW RESULT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VIEW RESULT'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('DONE'), 200);
      expect(find.text('DONE'), findsOneWidget);
    });
  }

  testWidgets('the live run survives landscape (stretch, §31)', (tester) async {
    useSize(tester, const Size(844, 390));
    await tester.pumpWidget(seededApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'RACE YOUR BEST'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.ensureVisible(find.text('START'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
  });
}
