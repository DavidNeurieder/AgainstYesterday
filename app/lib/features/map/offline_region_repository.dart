// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The offline-region repository: owns the list of downloaded regions and the
/// per-route lifecycle (download → ready/failed, delete), backed by the
/// persistence store for metadata and an [OfflineRegionDownloader] for the
/// native tiles. Modeled on the activity/route repositories so the UI stays
/// reactive without routing data through the recording controller.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/models.dart';
import '../../persistence/persistence.dart';
import 'map_surface.dart';
import 'offline_region_downloader.dart';
import 'offline_regions.dart';

const String kOfflineRegionsKey = 'offline_regions';

/// The downloader backend for this build: MapLibre on device, disabled on
/// host/tests (which override it with a fake).
final offlineRegionDownloaderProvider = Provider<OfflineRegionDownloader>(
  (ref) => selectedMapRenderer == MapRenderer.maplibre
      ? MapLibreOfflineRegionDownloader(styleUrl: kMapStyleUrlDefine)
      : const DisabledOfflineRegionDownloader(),
);

/// Whether this build can download offline regions (MapLibre renderer).
final offlineMapsAvailableProvider = Provider<bool>(
  (ref) => selectedMapRenderer == MapRenderer.maplibre,
);

/// Region list, newest download last — what Settings → Map and the route
/// detail page render.
final offlineRegionRepositoryProvider =
    NotifierProvider<OfflineRegionRepository, List<OfflineRegion>>(
        OfflineRegionRepository.new);

class OfflineRegionRepository extends Notifier<List<OfflineRegion>> {
  @override
  List<OfflineRegion> build() {
    ref.watch(persistenceStoreProvider);
    final raw = readBestEffort(ref.read(persistenceStoreProvider), kOfflineRegionsKey);
    if (raw == null) {
      return const [];
    }
    try {
      return parseOfflineRegionList(raw);
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  OfflineRegion? regionFor(String routeId) {
    for (final region in state) {
      if (region.routeId == routeId) {
        return region;
      }
    }
    return null;
  }

  /// Downloads the region for [route]. One download per route at a time:
  /// overlapping requests are ignored so a double tap cannot start twice.
  Future<void> downloadRoute(Route route) async {
    if (regionFor(route.id)?.status == OfflineRegionStatus.downloading) {
      return;
    }
    final bounds = RegionBounds.fromGeometry(route.geometry);
    if (bounds.isEmpty) {
      return;
    }
    final zoom = regionZoomFor(bounds);
    state = [
      ...state.where((r) => r.routeId != route.id),
      OfflineRegion(
        routeId: route.id,
        name: route.name,
        bounds: bounds,
        zoom: zoom,
        status: OfflineRegionStatus.downloading,
      ),
    ];
    await _persist();

    final downloader = ref.read(offlineRegionDownloaderProvider);
    try {
      final nativeId = await downloader.download(
        bounds: bounds,
        zoom: zoom,
        metadataKey: route.id,
        onProgress: (progress) => _update(
          route.id,
          (r) => r.copyWith(progress: progress),
        ),
      );
      _update(
        route.id,
        (r) => r.copyWith(
          status: OfflineRegionStatus.ready,
          progress: 1,
          nativeId: nativeId,
        ),
      );
    } on OfflineDownloadException catch (error) {
      _update(
        route.id,
        (r) => r.copyWith(
          status: OfflineRegionStatus.failed,
          errorText: error.message,
        ),
      );
    }
    await _persist();
  }

  /// Removes the region for [routeId], dropping its tiles from the device.
  Future<void> deleteRegion(String routeId) async {
    final region = regionFor(routeId);
    if (region == null) {
      return;
    }
    if (region.nativeId case final nativeId?) {
      await ref.read(offlineRegionDownloaderProvider).delete(nativeId);
    }
    state = state.where((r) => r.routeId != routeId).toList();
    await _persist();
  }

  void _update(String routeId, OfflineRegion Function(OfflineRegion) transform) {
    final next = [
      for (final r in state) r.routeId == routeId ? transform(r) : r,
    ];
    if (!_same(next, state)) {
      state = next;
    }
  }

  static bool _same(List<OfflineRegion> a, List<OfflineRegion> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Future<void> _persist() async {
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return;
    }
    await writeBestEffort(store, kOfflineRegionsKey, offlineRegionListToJson(state));
  }
}

/// JSON for the region metadata list (the tiles themselves live in MapLibre's
/// native offline database, keyed by [OfflineRegion.nativeId]).
String offlineRegionListToJson(List<OfflineRegion> regions) =>
    const JsonEncoder().convert([
      for (final r in regions)
        <String, Object?>{
          'routeId': r.routeId,
          'name': r.name,
          'bounds': <String, Object?>{
            'southLat': r.bounds.southLat,
            'northLat': r.bounds.northLat,
            'westLon': r.bounds.westLon,
            'eastLon': r.bounds.eastLon,
          },
          'zoom': r.zoom,
          'status': r.status.name,
          'progress': r.progress,
          if (r.errorText != null) 'errorText': r.errorText,
          if (r.nativeId != null) 'nativeId': r.nativeId,
        },
    ]);

List<OfflineRegion> parseOfflineRegionList(String json) {
  final raw = const JsonDecoder().convert(json);
  if (raw is! List) {
    throw const FormatException('offline regions: expected a list');
  }
  return [
    for (final entry in raw)
      if (entry is Map<String, Object?>) _regionFromJson(entry),
  ];
}

OfflineRegion _regionFromJson(Map<String, Object?> json) {
  final bounds = (json['bounds'] as Map<String, Object?>).cast<String, Object?>();
  return OfflineRegion(
    routeId: json['routeId']! as String,
    name: json['name']! as String,
    bounds: RegionBounds(
      southLat: (bounds['southLat']! as num).toDouble(),
      northLat: (bounds['northLat']! as num).toDouble(),
      westLon: (bounds['westLon']! as num).toDouble(),
      eastLon: (bounds['eastLon']! as num).toDouble(),
    ),
    zoom: (json['zoom']! as num).toInt(),
    status: OfflineRegionStatus.values.asNameMap()[json['status']] ??
        OfflineRegionStatus.failed,
    progress: ((json['progress'] as num?) ?? 0).toDouble(),
    errorText: json['errorText'] as String?,
    nativeId: (json['nativeId'] as num?)?.toInt(),
  );
}