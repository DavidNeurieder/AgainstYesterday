// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The download backend for offline map regions.
///
/// The MapLibre build talks to MapLibre Native's offline database; the host
/// default is disabled because MapLibre is a device-only renderer. The app
/// repository depends only on this seam, so tests drive a recording fake.
library;

import 'package:maplibre_gl/maplibre_gl.dart' as mlib;

import 'offline_regions.dart';

/// Downloads and deletes one offline region.
abstract interface class OfflineRegionDownloader {
  /// Starts a download for [bounds] at [zoom]. Reports progress 0..1 through
  /// [onProgress] and resolves with the native region id on success.
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  });

  Future<void> delete(int nativeId);
}

/// Talks to MapLibre Native's offline database.
///
/// The package reports failure through events rather than exceptions, so this
/// implementation collects them and throws an [OfflineDownloadException] once
/// the download call returns.
class MapLibreOfflineRegionDownloader implements OfflineRegionDownloader {
  const MapLibreOfflineRegionDownloader({required this.styleUrl});

  final String styleUrl;

  @override
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  }) async {
    var errorText = '';
    final region = await mlib.downloadOfflineRegion(
      mlib.OfflineRegionDefinition(
        bounds: mlib.LatLngBounds(
          southwest: mlib.LatLng(bounds.southLat, bounds.westLon),
          northeast: mlib.LatLng(bounds.northLat, bounds.eastLon),
        ),
        mapStyleUrl: styleUrl,
        minZoom: kOfflineMinZoom.toDouble(),
        maxZoom: zoom.toDouble(),
      ),
      metadata: <String, dynamic>{'routeId': metadataKey},
      onEvent: (event) {
        if (event is mlib.InProgress) {
          onProgress?.call(event.progress.clamp(0.0, 1.0));
        }
        if (event is mlib.Error) {
          errorText = event.cause.message ?? 'Offline download failed';
        }
      },
    );
    if (errorText.isNotEmpty) {
      throw OfflineDownloadException(errorText);
    }
    return region.id;
  }

  @override
  Future<void> delete(int nativeId) => mlib.deleteOfflineRegion(nativeId);
}

/// Host/tests default: offline regions are device-only (MapLibre renderer).
class DisabledOfflineRegionDownloader implements OfflineRegionDownloader {
  const DisabledOfflineRegionDownloader();

  @override
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  }) async {
    throw const OfflineDownloadException(
      'Offline maps need the MapLibre renderer (MAP_VIEW=true).',
    );
  }

  @override
  Future<void> delete(int nativeId) async {}
}