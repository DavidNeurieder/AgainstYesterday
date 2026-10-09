// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/features/map/painter_map_surface.dart';
import 'package:against_yesterday/features/map/track_geojson.dart';
import 'package:against_yesterday/widgets/route_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 0 of the offline map (`ideas/offline_map_plan.txt`): the renderer
/// switch resolves safely, the painter fallback still draws the scene, and the
/// seam can be swapped for a fake by a test.
void main() {
  const scene = MapScene(
    geometry: [
      GeoPoint(latitude: 52.5, longitude: 13.4),
      GeoPoint(latitude: 52.5005, longitude: 13.4005),
    ],
    you: GeoPoint(latitude: 52.5005, longitude: 13.4005),
    youProgress: 0.25,
    name: 'River Loop',
  );

  group('mapRendererFromDefine', () {
    test('only the exact "true" selects MapLibre', () {
      expect(mapRendererFromDefine('true'), MapRenderer.maplibre);
    });

    test('unset, empty, false or odd casing keep the painter fallback', () {
      for (final raw in ['', 'false', 'TRUE', '1', 'mapibre']) {
        expect(mapRendererFromDefine(raw), MapRenderer.painter, reason: raw);
      }
    });
  });

  group('lineStringFeatureCollection', () {
    test('is an empty collection for fewer than two points', () {
      final empty = lineStringFeatureCollection(const []);
      expect(empty['type'], 'FeatureCollection');
      expect(empty['features'], isEmpty);

      final single = lineStringFeatureCollection(const [
        GeoPoint(latitude: 1, longitude: 2),
      ]);
      expect(single['features'], isEmpty);
    });

    test('wraps the geometry as one LineString with lon/lat order', () {
      final collection = lineStringFeatureCollection(scene.geometry);
      final features = collection['features']! as List<Object?>;
      final geometry =
          (features.single as Map<String, Object?>)['geometry']!
              as Map<String, Object?>;
      expect(geometry['type'], 'LineString');
      expect(geometry['coordinates'], [
        [13.4, 52.5],
        [13.4005, 52.5005],
      ]);
    });
  });

  group('traveledGeometry', () {
    const points = [
      GeoPoint(latitude: 52.5, longitude: 13.4),
      GeoPoint(latitude: 52.5, longitude: 13.42),
      GeoPoint(latitude: 52.5, longitude: 13.44),
    ];

    test('is empty below or at zero and full at or above one', () {
      expect(traveledGeometry(points, 0), isEmpty);
      expect(traveledGeometry(points, -1), isEmpty);
      expect(traveledGeometry(points, 1), points);
      expect(traveledGeometry(points, 2), points);
    });

    test('cuts the polyline proportionally by length', () {
      final half = traveledGeometry(points, 0.5);
      // Two equal segments, so half the total length lands exactly on the
      // middle node (13.42) — the polygon is cut at 13.42 with no dangling tip.
      expect(half, hasLength(2));
      expect(half.first, points.first);
      expect(half.last.longitude, closeTo(13.42, 1e-9));
      expect(half.last.latitude, 52.5);

      final quarter = traveledGeometry(points, 0.25);
      // A quarter of 0.04° is halfway along the first segment.
      expect(quarter.last.longitude, closeTo(13.41, 1e-9));
    });

    test('does not slice a degenerate or single-point trace', () {
      expect(traveledGeometry([points.first], 0.5), isEmpty);
    });
  });

  testWidgets('the painter fallback still renders the scene', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => const PainterMapSurface().build(context, scene),
        ),
      ),
    );
    final map = tester.widget<RouteMap>(find.byType(RouteMap));
    expect(map.geometry, scene.geometry);
    expect(map.you, scene.you);
    expect(map.youProgress, 0.25);
    expect(map.name, 'River Loop');
    expect(map.staticView, isFalse);
  });

  test('the default build selects the painter fallback', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(mapSurfaceProvider), isA<PainterMapSurface>());
  });

  testWidgets('a screen renders through an overridden surface', (tester) async {
    final surface = _RecordingMapSurface();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mapSurfaceProvider.overrideWithValue(surface)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) =>
                ref.watch(mapSurfaceProvider).build(context, scene),
          ),
        ),
      ),
    );
    expect(surface.scenes, hasLength(1));
    expect(surface.scenes.single.name, 'River Loop');
  });
}

/// Captures the scene a screen asked to draw, without a native map.
class _RecordingMapSurface implements MapSurface {
  final scenes = <MapScene>[];

  @override
  Widget build(BuildContext context, MapScene scene) {
    scenes.add(scene);
    return const SizedBox.shrink();
  }
}
