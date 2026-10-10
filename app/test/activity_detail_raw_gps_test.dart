// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Raw GPS readout on activity detail: a collapsible list of every recorded
/// fix (lat/lon, local time, altitude when present) and a copy action that
/// puts one comma-separated line per fix on the clipboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/activity/presentation/activity_detail_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  final track = <TrackPoint>[
    TrackPoint(
      position: const GeoPoint(latitude: 52.498, longitude: 13.36),
      altitudeMeters: 35.5,
      timestamp: DateTime.utc(2026, 1, 2, 14, 5, 0),
    ),
    TrackPoint(
      position: const GeoPoint(latitude: 52.51, longitude: 13.372),
      timestamp: DateTime.utc(2026, 1, 2, 14, 6, 0),
    ),
    TrackPoint(
      position: const GeoPoint(latitude: 52.502, longitude: 13.381),
      timestamp: DateTime.utc(2026, 1, 2, 14, 7, 0),
    ),
  ];

  testWidgets('lists the raw fixes once expanded', (tester) async {
    _tallSurface(tester);
    await _pump(tester, track: track);

    expect(find.text('Raw GPS'), findsOneWidget);
    expect(find.text('3 fixes'), findsOneWidget);
    // Collapsed by default: no coordinate rows yet.
    expect(find.text('52.498000, 13.360000'), findsNothing);

    await tester.tap(find.text('Raw GPS'));
    await tester.pumpAndSettle();

    expect(find.text('52.498000, 13.360000'), findsOneWidget);
    expect(find.text('52.510000, 13.372000'), findsOneWidget);
    expect(find.text('52.502000, 13.381000'), findsOneWidget);
  });

  testWidgets('copies one comma-separated line per fix', (tester) async {
    _tallSurface(tester);
    final copied = _mockClipboard(tester);
    await _pump(tester, track: track);

    await tester.tap(find.text('Raw GPS'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-raw-gps')));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(
      copied.single,
      '52.498000, 13.360000, 2026-01-02T14:05:00.000Z, 35.5 m\n'
      '52.510000, 13.372000, 2026-01-02T14:06:00.000Z\n'
      '52.502000, 13.381000, 2026-01-02T14:07:00.000Z',
    );
    expect(find.text('Raw coordinates copied to clipboard.'), findsOneWidget);
  });

  testWidgets('hidden for a run without a track', (tester) async {
    _tallSurface(tester);
    await _pump(tester, track: null);

    expect(find.text('Raw GPS'), findsNothing);
    expect(find.byKey(const ValueKey('copy-raw-gps')), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required List<TrackPoint>? track,
}) async {
  final activity = Activity(
    id: 'act-gps',
    routeId: 'river-loop',
    startedAt: DateTime.utc(2026, 1, 2, 14, 0, 0),
    duration: const Elapsed.seconds(480),
    distance: const Distance.kilometers(2.1),
    performance: '8:00 · 1st',
    track: track,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        persistenceStoreProvider.overrideWithValue(
          seededStore(activities: [activity], routes: [riverLoopRoute]),
        ),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ActivityDetailScreen(activityId: 'act-gps'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The activity list is lazy: give the test a tall phone-sized surface so the
/// Raw GPS card (below the map and splits) is actually laid out and built.
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Records clipboard writes into [copied]; returns the list to assert on.
List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter/platform', JSONMethodCodec()),
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text']! as String);
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform', JSONMethodCodec()),
      null,
    );
  });
  return copied;
}