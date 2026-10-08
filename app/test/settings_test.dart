// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings (M21, §26): the screen renders the full table, its toggles
/// genuinely gate behavior, units re-format the readouts, export/delete do
/// what they say, and the model round-trips through the store.
library;

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/features/settings/application/settings_controller.dart';
import 'package:against_yesterday/features/settings/domain/settings.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_catalog.dart';

void main() {
  Widget pumpedApp() => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: demoRoutes, activities: demoActivities()),
          ),
        ],
        child: const AgainstYesterdayApp(),
      );

  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(pumpedApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('the countdown toggle really skips the 3-2-1-GO', (tester) async {
    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('countdown-switch')));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'START'));
    await tester.pump();
    // No countdown digits ever appear…
    expect(find.text('3'), findsNothing);
    expect(find.text('GO!'), findsNothing);
    // …and the live screen follows the press directly, no timer ticks.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('live-distance')), findsOneWidget);
    expect(find.text('PACE'), findsOneWidget);
  });

  testWidgets('switching to miles re-formats the readouts', (tester) async {
    await openSettings(tester);
    await tester.tap(find.text('Miles'));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    // River Loop is 4.76 km → 2.96 mi on the hero card.
    expect(find.text('2.96 mi · 12 attempts'), findsOneWidget);
    expect(find.textContaining('4.76 km'), findsNothing);
    expect(find.textContaining('4.75 km'), findsNothing);
  });

  testWidgets('the haptics toggle survives reopening settings',
      (tester) async {
    Switch switchValue(WidgetTester tester) => tester.widget<Switch>(
          find.descendant(
            of: find.byKey(const ValueKey('haptics-switch')),
            matching: find.byType(Switch),
          ),
        );

    await openSettings(tester);
    expect(switchValue(tester).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('haptics-switch')));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(switchValue(tester).value, isFalse);
  });

  testWidgets('export GPX copies the catalog to the clipboard', (tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('export-gpx')));
    await tester.pumpAndSettle();

    expect(clipboard, hasLength(1));
    expect(clipboard.single, startsWith('<?xml'));
    expect(clipboard.single, contains('<trk>'));
    expect(clipboard.single, contains('</gpx>'));
    // Three demo routes, no activity tracks → three <trk> elements.
    expect('<trk>'.allMatches(clipboard.single).length, 3);
    expect(find.textContaining('3 tracks as GPX'), findsOneWidget);
  });

  testWidgets('delete all data empties the catalog after a confirm',
      (tester) async {
    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all data?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-delete-all')));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    // Home is back to the first-launch empty state.
    expect(find.text('Your first race awaits.'), findsOneWidget);
    expect(find.text('READY TO RACE'), findsNothing);

    // And History is empty too.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('History'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.directions_run), findsNothing);
  });

  test('settings round-trip through the store codec', () {
    const custom = AppSettings(
      hapticsEnabled: false,
      countdownEnabled: false,
      units: Units.miles,
      onboardingSeen: false,
    );
    expect(parseAppSettings(appSettingsToJson(custom)), custom);
    expect(parseAppSettings(appSettingsToJson(AppSettings.defaults)),
        AppSettings.defaults);
  });

  test('corrupt settings fall back to the defaults', () {
    expect(parseAppSettings('{"units":"furlongs"}'), AppSettings.defaults);
    expect(parseAppSettings('{}'), AppSettings.defaults);
  });

  test('unit-aware formatting', () {
    const tenK = Distance.kilometers(4.76);
    expect(tenK.formatWith(Units.kilometers), '4.76 km');
    expect(tenK.formatWith(Units.miles), '2.96 mi');
    expect(const Distance.meters(120).formatWith(Units.miles), '120 m');

    const sixMinKm = Speed.fromPaceSecondsPerKm(360);
    expect(sixMinKm.formatPaceWith(Units.kilometers), '6:00 /km');
    expect(sixMinKm.formatPaceWith(Units.miles), '9:39 /mi');
    expect(
      const Speed.zero().formatPaceWith(Units.miles),
      '— /mi',
    );
    expect(sixMinKm.formatWith(Units.miles).endsWith('mph'), isTrue);
  });
}