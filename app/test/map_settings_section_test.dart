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

    expect(find.textContaining('No offline regions downloaded yet'),
        findsOneWidget);
    expect(find.textContaining('personal use'), findsOneWidget);
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