// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings (M21, §26): the screen renders the full table, its toggles
/// genuinely gate behavior, units re-format the readouts, export/delete do
/// what they say, and the model round-trips through the store.
library;

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/features/settings/application/link_launcher.dart';
import 'package:against_yesterday/features/settings/application/settings_controller.dart';
import 'package:against_yesterday/features/settings/application/track_export.dart';
import 'package:against_yesterday/features/settings/domain/settings.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_catalog.dart';

void main() {
  Widget pumpedApp({
    TrackExporter? exporter,
    LinkLauncher? linkLauncher,
  }) =>
      ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: demoRoutes, activities: demoActivities()),
          ),
          if (exporter != null)
            trackExporterProvider.overrideWithValue(exporter),
          if (linkLauncher != null)
            linkLauncherProvider.overrideWithValue(linkLauncher),
        ],
        child: const AgainstYesterdayApp(),
      );

  Future<void> openSettings(
    WidgetTester tester, {
    TrackExporter? exporter,
    LinkLauncher? linkLauncher,
  }) async {
    await tester.pumpWidget(
      pumpedApp(exporter: exporter, linkLauncher: linkLauncher),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
  }

  /// Scrolls the Settings list down to an About row, then taps it — the About
  /// section sits below the fold on the test viewport.
  Future<void> tapAboutRow(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey<String>(key));
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(target);
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

  testWidgets('export GPX saves the catalog to Downloads', (tester) async {
    final exporter = _RecordingTrackExporter();
    await openSettings(tester, exporter: exporter);
    await tester.tap(find.byKey(const ValueKey('export-gpx')));
    await tester.pumpAndSettle();

    expect(exporter.calls, hasLength(1));
    final saved = exporter.calls.single;
    expect(saved.fileName, startsWith('against-yesterday-'));
    expect(saved.fileName, endsWith('.gpx'));
    expect(saved.contents, startsWith('<?xml'));
    expect(saved.contents, contains('<trk>'));
    expect(saved.contents, contains('</gpx>'));
    // Three demo routes, no activity tracks → three <trk> elements.
    expect('<trk>'.allMatches(saved.contents).length, 3);
    expect(find.text('Saved ${saved.fileName} to Downloads.'), findsOneWidget);
  });

  testWidgets('export GPX reports a failed write', (tester) async {
    final exporter = _RecordingTrackExporter(fail: true);
    await openSettings(tester, exporter: exporter);
    await tester.tap(find.byKey(const ValueKey('export-gpx')));
    await tester.pumpAndSettle();

    expect(find.text('Export failed: Downloads is not writable.'), findsOneWidget);
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

  testWidgets('the About card opens GitHub and the issue tracker',
      (tester) async {
    final launcher = _RecordingLinkLauncher();
    await openSettings(tester, linkLauncher: launcher);

    await tapAboutRow(tester, 'github-link');
    await tapAboutRow(tester, 'issues-link');

    expect(launcher.uris, <Uri>[
      Uri.parse(kGitHubUrl),
      Uri.parse(kIssuesUrl),
    ]);
  });

  testWidgets('a link that cannot open says so', (tester) async {
    final launcher = _RecordingLinkLauncher(canOpen: false);
    await openSettings(tester, linkLauncher: launcher);

    await tapAboutRow(tester, 'github-link');

    expect(find.text('Could not open GitHub.'), findsOneWidget);
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

/// A [TrackExporter] that records what the Settings screen asked it to save.
class _RecordingTrackExporter implements TrackExporter {
  _RecordingTrackExporter({this.fail = false});

  final bool fail;
  final calls = <({String fileName, String contents})>[];

  @override
  Future<String> saveToDownloads({
    required String fileName,
    required String contents,
  }) async {
    calls.add((fileName: fileName, contents: contents));
    if (fail) {
      throw const TrackExportException('Downloads is not writable.');
    }
    return 'Download/$fileName';
  }
}

/// A [LinkLauncher] that records the URLs the About card opened, and can be
/// told to report that nothing could handle them.
class _RecordingLinkLauncher implements LinkLauncher {
  _RecordingLinkLauncher({this.canOpen = true});

  final bool canOpen;
  final uris = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    uris.add(uri);
    return canOpen;
  }
}