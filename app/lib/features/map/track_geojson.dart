// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure GeoJSON builders shared by the map surfaces.
///
/// The route/track geometry the app draws is converted here, with no platform
/// dependency, so the shape handed to MapLibre is unit-testable on the host.
library;

import 'dart:math' as math;

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

/// The leading portion of [points] up to [fraction] of its length — the line
/// the runner has covered. An empty list below/at zero, all of [points] at/above
/// one. Cuts on raw coordinates (a proportional slice, unlike the painter's
/// cos-corrected projection), which is all the accent line needs.
List<GeoPoint> traveledGeometry(List<GeoPoint> points, double fraction) {
  if (points.length < 2) {
    return const [];
  }
  final f = fraction.clamp(0.0, 1.0);
  if (f <= 0) {
    return const [];
  }
  if (f >= 1) {
    return points;
  }
  var total = 0.0;
  final segments = <double>[];
  for (var i = 1; i < points.length; i++) {
    final segment = _planarDistance(points[i - 1], points[i]);
    segments.add(segment);
    total += segment;
  }
  if (total <= 0) {
    return const [];
  }
  final target = total * f;
  final result = <GeoPoint>[points.first];
  var covered = 0.0;
  for (var i = 1; i < points.length; i++) {
    final segment = segments[i - 1];
    if (covered + segment >= target) {
      final t = segment <= 0 ? 0.0 : (target - covered) / segment;
      result.add(_lerp(points[i - 1], points[i], t));
      return result;
    }
    covered += segment;
    result.add(points[i]);
  }
  return result;
}

double _planarDistance(GeoPoint a, GeoPoint b) {
  final dx = b.longitude - a.longitude;
  final dy = b.latitude - a.latitude;
  return math.sqrt(dx * dx + dy * dy);
}

GeoPoint _lerp(GeoPoint a, GeoPoint b, double t) => GeoPoint(
      latitude: a.latitude + (b.latitude - a.latitude) * t,
      longitude: a.longitude + (b.longitude - a.longitude) * t,
    );
