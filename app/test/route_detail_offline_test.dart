// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Offline map Phase 3 — route detail's Download offline map affordance:
/// the button starts a download through the seam, a ready region replaces it
/// with a status line, and builds without the MapLibre renderer hide it all.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/features/map/offline_region_downloader.dart';
import 'package:against_yesterday/features/map/offline_region_repository.dart';
import 'package:against_yesterday/features/map/offline_regions.dart';
import 'package:against_yesterday/features/routes/presentation/route_detail_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  testWidgets('starts a download from the route page', (tester) async {
    final downloader = _RecordingDownloader();

    await _pump(tester, downloader: downloader);

    final button =
        find.byKey(const ValueKey('download-offline-river-loop'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(downloader.downloads, ['river-loop']);
    expect(find.textContaining('Offline map ready'), findsOneWidget);
  });

  testWidgets('a ready region replaces the download button', (tester) async {
    final store = seededStore(routes: [riverLoopRoute]);
    store.write(
      kOfflineRegionsKey,
      offlineRegionListToJson([
        OfflineRegion(
          routeId: 'river-loop',
          name: 'River Loop',
          bounds: RegionBounds.fromGeometry(riverLoopRoute.geometry),
          zoom: 15,
          status: OfflineRegionStatus.ready,
          progress: 1,
          nativeId: 8,
        ),
      ]),
    );

    await _pump(tester, store: store);

    expect(find.byKey(const ValueKey('download-offline-river-loop')),
        findsNothing);
    expect(find.textContaining('Offline map ready'), findsOneWidget);
  });

  testWidgets('is hidden when this build cannot download regions',
      (tester) async {
    await _pump(tester, offlineAvailable: false);

    expect(find.byKey(const ValueKey('download-offline-river-loop')),
        findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  PersistenceStore? store,
  OfflineRegionDownloader? downloader,
  bool offlineAvailable = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        persistenceStoreProvider.overrideWithValue(
          store ?? seededStore(routes: [riverLoopRoute]),
        ),
        offlineMapsAvailableProvider.overrideWithValue(offlineAvailable),
        offlineRegionDownloaderProvider.overrideWithValue(
          downloader ?? _RecordingDownloader(),
        ),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const RouteDetailScreen(routeId: 'river-loop'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _RecordingDownloader implements OfflineRegionDownloader {
  final List<String> downloads = [];
  final List<int> deletions = [];

  @override
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  }) async {
    downloads.add(metadataKey);
    onProgress?.call(0.5);
    return 8;
  }

  @override
  Future<void> delete(int nativeId) async => deletions.add(nativeId);
}