// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A [flutter_map] tile provider that serves raster tiles from the on-disk
/// per-route cache when available, falling back to the network otherwise.
///
/// Used on Linux desktop: saved route regions render without a connection, and
/// missing tiles still load from the network while maps are enabled.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Serves `<cacheRoot>/regions/*/<z>/<x>/<y>.png` from disk when present.
class CachedRasterTileProvider extends TileProvider {
  CachedRasterTileProvider({
    required this.cacheRoot,
    super.headers,
  }) : _network = NetworkTileProvider(headers: headers);

  /// Root directory containing the per-route `regions/` folders.
  final Directory cacheRoot;

  final NetworkTileProvider _network;

  @override
  bool get supportsCancelLoading => _network.supportsCancelLoading;

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final file = _findCached(coordinates);
    if (file != null) {
      return FileImage(file);
    }
    return _network.getImageWithCancelLoadingSupport(
      coordinates,
      options,
      cancelLoading,
    );
  }

  @override
  void dispose() {
    _network.dispose();
    super.dispose();
  }

  File? _findCached(TileCoordinates coordinates) {
    final regionsDir = Directory('${cacheRoot.path}/regions');
    if (!regionsDir.existsSync()) {
      return null;
    }
    final suffix = '/${coordinates.z}/${coordinates.x}/${coordinates.y}.png';
    try {
      for (final entity in regionsDir.listSync()) {
        if (entity is! Directory) {
          continue;
        }
        final candidate = File('${entity.path}$suffix');
        if (candidate.existsSync()) {
          return candidate;
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}
