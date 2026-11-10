// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Offline map Phase 3 — Settings → Map: the region list, progress while a
/// region downloads, delete with confirmation, and the OSM attribution.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/features/map/map_settings_section.dart';
import 'package:against_yesterday/features/map/offline_region_repository.dart';
import 'package:against_yesterday/features/map/offline_regions.dart';
import 'package:against_yesterday/features/settings/application/settings_controller.dart';
import 'package:against_yesterday/features/settings/domain/settings.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  testWidgets('lists a downloaded region and deletes it after confirmation',
      (tester) async {
    final store = MemoryPersistenceStore();
    store.write(
      kOfflineRegionsKey,
      offlineRegionListToJson([
        _readyRegion(),
      ]),
    );

    await _pump(tester, store);

    expect(find.text('River Loop'), findsOneWidget);
    expect(find.textContaining('zoom 15'), findsOneWidget);
    expect(find.textContaining('OpenStreetMap'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-offline-river-loop')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this region?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-delete-offline')));
    await tester.pumpAndSettle();

    expect(find.text('River Loop'), findsNothing);
    expect(parseOfflineRegionList(store.read(kOfflineRegionsKey)!), isEmpty);
  });

  testWidgets('cancelling the confirm dialog keeps the region', (tester) async {
    final store = MemoryPersistenceStore();
    store.write(kOfflineRegionsKey, offlineRegionListToJson([_readyRegion()]));

    await _pump(tester, store);

    await tester.tap(find.byKey(const ValueKey('delete-offline-river-loop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('River Loop'), findsOneWidget);
  });

  testWidgets('a downloading region shows its progress', (tester) async {
    final store = MemoryPersistenceStore();
    store.write(
      kOfflineRegionsKey,
      offlineRegionListToJson([
        _readyRegion().copyWith(
          status: OfflineRegionStatus.downloading,
          progress: 0.4,
          nativeId: null,
        ),
      ]),
    );

    await _pump(tester, store);

    expect(
      find.byKey(const ValueKey('offline-progress-river-loop')),
      findsOneWidget,
    );
    expect(find.textContaining('Downloading 40%'), findsOneWidget);
  });

  testWidgets('shows the empty state and the disclosure', (tester) async {
    await _pump(tester, MemoryPersistenceStore());

    expect(find.textContaining('No offline regions saved yet'),
        findsOneWidget);
    expect(find.textContaining('personal use'), findsOneWidget);
  });

  testWidgets('the Use maps switch defaults on', (tester) async {
    await _pump(tester, MemoryPersistenceStore());

    final toggle = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const ValueKey('maps-switch')),
        matching: find.byType(Switch),
      ),
    );
    expect(toggle.value, isTrue);
  });

  testWidgets('turning maps off hides map data and persists the choice',
      (tester) async {
    final store = MemoryPersistenceStore();
    store.write(kOfflineRegionsKey, offlineRegionListToJson([_readyRegion()]));

    await _pump(tester, store);

    await tester.tap(find.byKey(const ValueKey('maps-switch')));
    await tester.pumpAndSettle();

    expect(find.text('River Loop'), findsNothing);
    expect(find.textContaining('Maps are off'), findsOneWidget);
    expect(find.textContaining('OpenStreetMap'), findsNothing);
    expect(store.read('settings'), contains('"maps":false'));
  });

  testWidgets('a stored off switch starts the app fully offline',
      (tester) async {
    final store = MemoryPersistenceStore();
    store.write(
      'settings',
      appSettingsToJson(AppSettings.defaults.copyWith(mapsEnabled: false)),
    );

    await _pump(tester, store);

    final toggle = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const ValueKey('maps-switch')),
        matching: find.byType(Switch),
      ),
    );
    expect(toggle.value, isFalse);
    expect(find.textContaining('No offline regions saved yet'), findsNothing);
    expect(find.textContaining('personal use'), findsNothing);
  });
}

Future<void> _pump(WidgetTester tester, PersistenceStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [persistenceStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MapSettingsSection(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OfflineRegion _readyRegion() => OfflineRegion(
      routeId: 'river-loop',
      name: 'River Loop',
      bounds: RegionBounds.fromGeometry(riverLoopRoute.geometry),
      zoom: 15,
      status: OfflineRegionStatus.ready,
      progress: 1,
      nativeId: 8,
    );