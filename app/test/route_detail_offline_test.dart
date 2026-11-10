// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Offline map Phase 3 — route detail saves the route's map automatically:
/// opening the page starts the download through the seam, one region per route
/// is reused by every run, a failed save offers a retry, and builds without the
/// MapLibre renderer hide it all.
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
  testWidgets('saves the route map automatically when the page opens',
      (tester) async {
    final downloader = _RecordingDownloader();

    await _pump(tester, downloader: downloader);

    expect(downloader.downloads, ['river-loop']);
    expect(find.textContaining('Offline map ready'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-offline-river-loop')),
      findsNothing,
    );
  });

  testWidgets('a ready region is reused instead of downloaded again',
      (tester) async {
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
    final downloader = _RecordingDownloader();

    await _pump(tester, store: store, downloader: downloader);

    expect(downloader.downloads, isEmpty);
    expect(
      find.byKey(const ValueKey('download-offline-river-loop')),
      findsNothing,
    );
    expect(find.textContaining('Offline map ready'), findsOneWidget);
  });

  testWidgets('a failed automatic save leaves a retry control', (tester) async {
    final downloader = _RecordingDownloader(failFirst: true);

    await _pump(tester, downloader: downloader);

    // The first, automatic attempt failed, so the card offers the retry.
    expect(downloader.downloads, ['river-loop']);
    expect(find.text('Network unavailable'), findsOneWidget);
    final retry = find.byKey(const ValueKey('retry-offline-river-loop'));
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(downloader.downloads, ['river-loop', 'river-loop']);
    expect(find.textContaining('Offline map ready'), findsOneWidget);
  });

  testWidgets('is hidden when this build cannot download regions',
      (tester) async {
    final downloader = _RecordingDownloader();

    await _pump(tester, downloader: downloader, offlineAvailable: false);

    expect(downloader.downloads, isEmpty);
    expect(
      find.byKey(const ValueKey('download-offline-river-loop')),
      findsNothing,
    );
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
  _RecordingDownloader({this.failFirst = false});

  /// Fails the first automatic attempt, so a retry can be exercised.
  final bool failFirst;

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
    if (failFirst && downloads.length == 1) {
      throw const OfflineDownloadException('Network unavailable');
    }
    onProgress?.call(0.5);
    return 8;
  }

  @override
  Future<void> delete(int nativeId, {String? routeId}) async =>
      deletions.add(nativeId);
}
