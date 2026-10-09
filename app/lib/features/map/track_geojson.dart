// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure GeoJSON builders shared by the map surfaces.
///
/// The route/track geometry the app draws is converted here, with no platform
/// dependency, so the shape handed to MapLibre is unit-testable on the host.
library;

import '../../engine/models.dart';

/// A GeoJSON `FeatureCollection` holding one `LineString` for [points], or an
/// empty collection when there is nothing to draw. Fed straight to
/// `MapLibreMapController.addGeoJsonSource` / `setGeoJsonSource`.
Map<String, Object?> lineStringFeatureCollection(List<GeoPoint> points) {
  if (points.length < 2) {
    return const <String, Object?>{
      'type': 'FeatureCollection',
      'features': <Object?>[],
    };
  }
  return <String, Object?>{
    'type': 'FeatureCollection',
    'features': <Object?>[
      <String, Object?>{
        'type': 'Feature',
        'geometry': <String, Object?>{
          'type': 'LineString',
          'coordinates': <Object?>[
            for (final p in points) <double>[p.longitude, p.latitude],
          ],
        },
        'properties': <String, Object?>{},
      },
    ],
  };
}
