// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Offline map regions — model and pure geometry policy.
///
/// A region is one route's tile box. Download size is capped on the client so
/// a tap never floods the tile provider (its terms forbid automated bulk
/// collection): the zoom is chosen per route so the estimated tile count stays
/// under [kOfflineMaxTiles], and the repository downloads one region at a
/// time. Everything here is platform-free so the whole policy is unit-testable
/// on the host.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../engine/models.dart';

/// Lowest zoom cached for a region (street context).
const int kOfflineMinZoom = 12;

/// Highest zoom cached for a region (city detail). Deliberately below the
/// full street-level detail so regions stay small.
const int kOfflineMaxZoom = 15;

/// Tile budget per region; [regionZoomFor] backs the zoom off to stay under it.
const int kOfflineMaxTiles = 1500;

/// A lat/lon box exactly covering one route (or track), in world degrees.
@immutable
class RegionBounds {
  const RegionBounds({
    required this.southLat,
    required this.northLat,
    required this.westLon,
    required this.eastLon,
  }) : assert(southLat <= northLat),
       assert(westLon <= eastLon);

  /// Tight box around [geometry]; degenerate (empty) when there is none.
  factory RegionBounds.fromGeometry(List<GeoPoint> geometry) {
    if (geometry.isEmpty) {
      return const RegionBounds(
        southLat: 0,
        northLat: 0,
        westLon: 0,
        eastLon: 0,
      );
    }
    var south = geometry.first.latitude;
    var north = geometry.first.latitude;
    var west = geometry.first.longitude;
    var east = geometry.first.longitude;
    for (final p in geometry) {
      south = math.min(south, p.latitude);
      north = math.max(north, p.latitude);
      west = math.min(west, p.longitude);
      east = math.max(east, p.longitude);
    }
    return RegionBounds(
      southLat: south,
      northLat: north,
      westLon: west,
      eastLon: east,
    );
  }

  final double southLat;
  final double northLat;
  final double westLon;
  final double eastLon;

  bool get isEmpty => southLat == northLat && westLon == eastLon;
  double get widthDegrees => eastLon - westLon;
  double get heightDegrees => northLat - southLat;

  @override
  bool operator ==(Object other) =>
      other is RegionBounds &&
      other.southLat == southLat &&
      other.northLat == northLat &&
      other.westLon == westLon &&
      other.eastLon == eastLon;

  @override
  int get hashCode =>
      Object.hash(southLat, northLat, westLon, eastLon);
}

/// Rough Web-Mercator-ish tile count for [bounds] at [zoom]. Deliberately a
/// conservative upper bound: it ignores the latitude compression Mercator
/// applies, so the estimate never under-counts the real request.
int estimatedTileCount(RegionBounds bounds, int zoom) {
  final world = 1 << zoom;
  final cols = math.max(1, (bounds.widthDegrees / 360.0 * world).ceil());
  final rows = math.max(1, (bounds.heightDegrees / 180.0 * world).ceil());
  return cols * rows;
}

/// Highest zoom at or below [maxZoom] whose tile estimate fits [maxTiles];
/// never below [minZoom].
int regionZoomFor(
  RegionBounds bounds, {
  int minZoom = kOfflineMinZoom,
  int maxZoom = kOfflineMaxZoom,
  int maxTiles = kOfflineMaxTiles,
}) {
  for (var zoom = maxZoom; zoom >= minZoom; zoom--) {
    if (estimatedTileCount(bounds, zoom) <= maxTiles) {
      return zoom;
    }
  }
  return minZoom;
}

/// Lifecycle of one region download.
enum OfflineRegionStatus { downloading, ready, failed }

/// One downloaded (or in-flight) offline region for a route.
@immutable
class OfflineRegion {
  const OfflineRegion({
    required this.routeId,
    required this.name,
    required this.bounds,
    required this.zoom,
    required this.status,
    this.progress = 0,
    this.errorText,
    this.nativeId,
  });

  final String routeId;
  final String name;
  final RegionBounds bounds;
  final int zoom;
  final OfflineRegionStatus status;

  /// 0..1 while [OfflineRegionStatus.downloading].
  final double progress;
  final String? errorText;

  /// MapLibre's region id once the native download assigned one.
  final int? nativeId;

  OfflineRegion copyWith({
    OfflineRegionStatus? status,
    double? progress,
    String? errorText,
    int? nativeId,
    bool clearError = false,
  }) =>
      OfflineRegion(
        routeId: routeId,
        name: name,
        bounds: bounds,
        zoom: zoom,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        errorText: clearError ? null : (errorText ?? this.errorText),
        nativeId: nativeId ?? this.nativeId,
      );

  @override
  bool operator ==(Object other) =>
      other is OfflineRegion &&
      other.routeId == routeId &&
      other.name == name &&
      other.bounds == bounds &&
      other.zoom == zoom &&
      other.status == status &&
      other.progress == progress &&
      other.errorText == errorText &&
      other.nativeId == nativeId;

  @override
  int get hashCode =>
      Object.hash(routeId, name, bounds, zoom, status, progress, errorText, nativeId);
}

/// The failure the native offline database reports for a region download.
class OfflineDownloadException implements Exception {
  const OfflineDownloadException(this.message);

  final String message;

  @override
  String toString() => 'OfflineDownloadException: $message';
}