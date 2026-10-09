// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Offline map Phase 3 — the pure geometry policy and the repository state
/// machine, driven through the downloader seam so nothing touches the native
/// offline database.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/features/map/offline_region_downloader.dart';
import 'package:against_yesterday/features/map/offline_region_repository.dart';
import 'package:against_yesterday/features/map/offline_regions.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  group('region bounds and zoom policy', () {
    test('fits the route tightly', () {
      final bounds = RegionBounds.fromGeometry(riverLoopRoute.geometry);
      expect(bounds.southLat, 52.4980);
      expect(bounds.northLat, 52.5105);
      expect(bounds.westLon, 13.3600);
      expect(bounds.eastLon, 13.3840);
      expect(bounds.isEmpty, isFalse);
    });

    test('is degenerate without geometry', () {
      expect(RegionBounds.fromGeometry(const []).isEmpty, isTrue);
    });

    test('estimates the tile count of the river loop at known zooms', () {
      final bounds = RegionBounds.fromGeometry(riverLoopRoute.geometry);
      expect(estimatedTileCount(bounds, 12), 1);
      expect(estimatedTileCount(bounds, 15), 9);
    });

    test('keeps a route region at the detail cap', () {
      final bounds = RegionBounds.fromGeometry(riverLoopRoute.geometry);
      expect(regionZoomFor(bounds), kOfflineMaxZoom);
    });

    test('backs a huge area off to the floor zoom', () {
      const huge = RegionBounds(
        southLat: 40,
        northLat: 50,
        westLon: -10,
        eastLon: 10,
      );
      expect(estimatedTileCount(huge, kOfflineMaxZoom), greaterThan(kOfflineMaxTiles));
      expect(regionZoomFor(huge), kOfflineMinZoom);
    });

    test('respects a caller tile budget', () {
      final bounds = RegionBounds.fromGeometry(riverLoopRoute.geometry);
      expect(regionZoomFor(bounds, maxTiles: 4), 14);
    });
  });

  group('serialization', () {
    test('region metadata round-trips through JSON', () {
      final region = OfflineRegion(
        routeId: 'river-loop',
        name: 'River Loop',
        bounds: RegionBounds.fromGeometry(riverLoopRoute.geometry),
        zoom: 15,
        status: OfflineRegionStatus.ready,
        progress: 1,
        nativeId: 8,
      );
      final parsed = parseOfflineRegionList(offlineRegionListToJson([region]));
      expect(parsed, [region]);
    });

    test('rejects a malformed document', () {
      expect(() => parseOfflineRegionList('{"nope": true}'),
          throwsFormatException);
    });
  });

  group('repository lifecycle', () {
    test('downloads a route to ready, reporting progress', () async {
      final downloader = _FakeDownloader();
      final container = _container(downloader: downloader);
      final repo = container.read(offlineRegionRepositoryProvider.notifier);

      await repo.downloadRoute(riverLoopRoute);

      final region = container.read(offlineRegionRepositoryProvider).single;
      expect(region.routeId, 'river-loop');
      expect(region.name, 'River Loop');
      expect(region.zoom, kOfflineMaxZoom);
      expect(region.bounds.southLat, 52.4980);
      expect(region.status, OfflineRegionStatus.ready);
      expect(region.progress, 1);
      expect(region.nativeId, 8);
      expect(downloader.downloads, ['river-loop']);
      expect(downloader.reportedProgress, containsAll([0.4, 0.9, 1.0]));
    });

    test('marks a failed download with the native error', () async {
      final downloader = _FakeDownloader(
        failWith: const OfflineDownloadException('Disk full'),
      );
      final container = _container(downloader: downloader);
      final repo = container.read(offlineRegionRepositoryProvider.notifier);

      await repo.downloadRoute(riverLoopRoute);

      final region = container.read(offlineRegionRepositoryProvider).single;
      expect(region.status, OfflineRegionStatus.failed);
      expect(region.errorText, 'Disk full');
    });

    test('ignores an overlapping download for the same route', () async {
      final gate = Completer<int>();
      final downloader = _FakeDownloader(gate: gate);
      final container = _container(downloader: downloader);
      final repo = container.read(offlineRegionRepositoryProvider.notifier);

      final first = repo.downloadRoute(riverLoopRoute);
      // Double tap: must not start a second native download.
      await repo.downloadRoute(riverLoopRoute);
      expect(downloader.downloads, hasLength(1));

      gate.complete(9);
      await first;

      final region = container.read(offlineRegionRepositoryProvider).single;
      expect(region.status, OfflineRegionStatus.ready);
      expect(region.nativeId, 9);
    });

    test('deletes a region and drops its native tiles', () async {
      final downloader = _FakeDownloader();
      final container = _container(downloader: downloader);
      final repo = container.read(offlineRegionRepositoryProvider.notifier);

      await repo.downloadRoute(riverLoopRoute);
      await repo.deleteRegion('river-loop');

      expect(container.read(offlineRegionRepositoryProvider), isEmpty);
      expect(downloader.deletions, [8]);
    });

    test('region metadata survives a repository rebuild', () async {
      final store = MemoryPersistenceStore();
      await _container(store: store)
          .read(offlineRegionRepositoryProvider.notifier)
          .downloadRoute(riverLoopRoute);

      final rebuilt = _container(store: store);
      final region = rebuilt.read(offlineRegionRepositoryProvider).single;
      expect(region.status, OfflineRegionStatus.ready);
      expect(region.nativeId, 8);
    });

    test('a corrupt region document starts empty', () {
      final store = MemoryPersistenceStore();
      store.write(kOfflineRegionsKey, '{"nope": true}');
      expect(_container(store: store).read(offlineRegionRepositoryProvider),
          isEmpty);
    });
  });
}

ProviderContainer _container({
  PersistenceStore? store,
  OfflineRegionDownloader? downloader,
}) {
  final container = ProviderContainer(
    overrides: [
      persistenceStoreProvider.overrideWithValue(
        store ?? MemoryPersistenceStore(),
      ),
      offlineRegionDownloaderProvider.overrideWithValue(
        downloader ?? _FakeDownloader(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Records every call; optionally fails or gates so a test can control pacing.
class _FakeDownloader implements OfflineRegionDownloader {
  _FakeDownloader({this.failWith, this.gate});

  final OfflineDownloadException? failWith;
  final Completer<int>? gate;

  final List<String> downloads = [];
  final List<int> deletions = [];
  final List<double> reportedProgress = [];

  @override
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  }) async {
    downloads.add(metadataKey);
    void report(double progress) {
      reportedProgress.add(progress);
      onProgress?.call(progress);
    }

    report(0.4);
    report(0.9);
    if (failWith case final error?) {
      throw error;
    }
    final id = gate == null ? 7 + downloads.length : await gate!.future;
    report(1.0);
    return id;
  }

  @override
  Future<void> delete(int nativeId) async => deletions.add(nativeId);
}