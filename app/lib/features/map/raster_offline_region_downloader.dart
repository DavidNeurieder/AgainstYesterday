// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Raster (flutter_map) offline region backend for platforms without MapLibre.
///
/// Downloads the route's raster tiles into an on-disk cache and deletes them
/// with the region. The tile provider reads from the same cache so a saved
/// route renders without a network connection.
library;

import 'dart:io';
import 'dart:typed_data';

import 'offline_region_downloader.dart';
import 'offline_regions.dart';

/// Where per-route raster tiles are stored: `<root>/regions/<routeId>/<z>/<x>/<y>.png`.
Directory rasterRegionDirectory(Directory cacheRoot, String routeId) =>
    Directory('${cacheRoot.path}/regions/$routeId');

/// The on-disk location of one cached raster tile, or `null` if [cacheRoot]
/// is unavailable.
File? rasterTileFile({
  required Directory cacheRoot,
  required String routeId,
  required int z,
  required int x,
  required int y,
}) =>
    File('${rasterRegionDirectory(cacheRoot, routeId).path}/$z/$x/$y.png');

/// Downloads raster tiles for a region into [cacheRoot].
class RasterOfflineRegionDownloader implements OfflineRegionDownloader {
  RasterOfflineRegionDownloader({
    required this.cacheRoot,
    required this.tileUrlTemplate,
    HttpClient? client,
  }) : _client = client ?? HttpClient(),
       _ownsClient = client == null;

  /// Root directory that holds per-route tile folders.
  final Directory cacheRoot;

  /// Slippy-map URL template containing `{z}`, `{x}`, `{y}` (and optionally
  /// `{s}`, `{r}`).
  final String tileUrlTemplate;

  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<int> download({
    required RegionBounds bounds,
    required int zoom,
    required String metadataKey,
    void Function(double progress)? onProgress,
  }) async {
    final tiles = tilesForRegion(
      bounds,
      minZoom: kOfflineMinZoom,
      maxZoom: zoom,
    ).toList(growable: false);
    final total = tiles.length;
    if (total == 0) {
      return metadataKey.hashCode & 0x7fffffff;
    }
    final regionDir = rasterRegionDirectory(cacheRoot, metadataKey);
    var done = 0;
    for (final tile in tiles) {
      final file = File('${regionDir.path}/${tile.z}/${tile.x}/${tile.y}.png');
      if (!file.existsSync()) {
        final url = _tileUrl(z: tile.z, x: tile.x, y: tile.y);
        final request = await _client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader,
            'app.against_yesterday');
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Drain to allow connection reuse, then report failure.
          await response.drain<void>();
          throw OfflineDownloadException(
            'Tile download failed (${response.statusCode}) for $url',
          );
        }
        final bytes = await _readBytes(response);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      done++;
      onProgress?.call(done / total);
    }
    return metadataKey.hashCode & 0x7fffffff;
  }

  @override
  Future<void> delete(int nativeId, {String? routeId}) async {
    if (routeId == null || routeId.isEmpty) {
      return;
    }
    final dir = rasterRegionDirectory(cacheRoot, routeId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Releases the HTTP client when this downloader owns it.
  void close() {
    if (_ownsClient) {
      _client.close(force: true);
    }
  }

  String _tileUrl({required int z, required int x, required int y}) {
    return tileUrlTemplate
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y')
        .replaceAll('{s}', 'a')
        .replaceAll('{r}', '');
  }

  static Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
