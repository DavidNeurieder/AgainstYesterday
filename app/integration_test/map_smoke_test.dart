// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// On-device map smoke (offline map Phase 4).
///
/// Renders the real MapLibre map — native view, real style document pulled
/// over the network — and waits for the style to load and the first scene to
/// be drawn, so a broken maplibre integration fails on the device instead of
/// only on a phone in someone's pocket. It then checks the behaviour the
/// screens depend on but a widget test cannot see: the camera follows YOU as
/// new fixes arrive, a scene update reaches the native map, and an
/// unreachable style document degrades quietly instead of taking the screen
/// down. Needs network, so it is nightly / connected-only: the suite skips
/// unless launched with `--dart-define=MAP_VIEW=true`, which the harness does
/// for `--map-smoke` (`./tool/android_integration_test.sh --map-smoke`).
/// Off-network CI stays hermetic.
///
/// The hermetic half of the map coverage stays on the host: the screens'
/// scene hand-off is pinned by `test/live_run_map_test.dart` and friends, and
/// `test/route_map_test.dart` covers the painter fallback. This suite is
/// deliberately about the native renderer only.
///
/// Run with:
///
/// ```bash
/// ./tool/android_integration_test.sh --map-smoke
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/map/maplibre_map_surface.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/features/map/track_geojson.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Mirrors the app's own define semantics (`map_surface.dart`).
const String _mapView = String.fromEnvironment('MAP_VIEW');

/// How long the native side may take to load the style and draw the first
/// scene. Generous: a cold emulator pulled the style+tiles slowly.
const Duration _styleTimeout = Duration(seconds: 60);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'renders the live scene on the real MapLibre map',
    // Skipped unless launched with --dart-define=MAP_VIEW=true (the
    // --map-smoke harness invocation): the real map needs network.
    skip: _mapView != 'true',
    (tester) async {
      final ready = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: MaplibreRouteMap(
              scene: MapScene(
                geometry: FakeEngineService.riverLoop,
                you: FakeEngineService.riverLoop.first,
                youProgress: 0.3,
                staticView: true,
              ),
              onReady: ready.complete,
            ),
          ),
        ),
      );

      // Style load, source/layer setup and the first camera move happen on the
      // native side. `onReady` only fires after the route and traveled
      // GeoJSON sources plus their line layers were added for real, so waiting
      // for it is also the source/layer-configuration assertion.
      await ready.future.timeout(_styleTimeout, onTimeout: () {
        fail(
          'MapLibre did not reach style-loaded within 60 s. The map likely '
          'failed to initialise or the style document was unreachable.',
        );
      });

      await tester.pumpAndSettle();
      expect(find.byType(MapLibreMap), findsOneWidget);
    },
  );

  testWidgets(
    'follows YOU and keeps syncing as fixes arrive',
    skip: _mapView != 'true',
    (tester) async {
      final geometry = FakeEngineService.riverLoop;
      // YOU sits at the end of the travelled line, exactly as a live scene
      // sends it: a source query only answers from the tiles the camera has
      // loaded, so a scene whose marker is 800 m off the accent line would
      // legitimately answer with nothing.
      final first = traveledGeometry(geometry, 0.25).last;
      final second = traveledGeometry(geometry, 0.75).last;
      final ready = Completer<void>();
      MapLibreMapController? controller;
      var readyCalls = 0;

      Widget map(MapScene scene) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: MaplibreRouteMap(
            scene: scene,
            onMapCreated: (c) => controller = c,
            onReady: () {
              readyCalls++;
              if (!ready.isCompleted) {
                ready.complete();
              }
            },
          ),
        ),
      );

      await tester.pumpWidget(
        map(MapScene(geometry: geometry, you: first, youProgress: 0.25)),
      );

      // The native view is created from these properties, so assert them on
      // the widget: the app's style document, no platform location layer (the
      // recorder draws YOU itself), and camera tracking on so a user pan can
      // be detected.
      final view = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(view.styleString, kMapStyleUrlDefine);
      expect(view.trackCameraPosition, isTrue);
      expect(view.myLocationEnabled, isFalse);
      final camera = view.initialCameraPosition;
      expect(camera, isNotNull, reason: 'the map must open on a camera');
      final start = camera!.target;
      final lats = geometry.map((p) => p.latitude);
      final lons = geometry.map((p) => p.longitude);
      expect(start.latitude, greaterThanOrEqualTo(lats.reduce(_min)));
      expect(start.latitude, lessThanOrEqualTo(lats.reduce(_max)));
      expect(start.longitude, greaterThanOrEqualTo(lons.reduce(_min)));
      expect(start.longitude, lessThanOrEqualTo(lons.reduce(_max)));

      await ready.future.timeout(_styleTimeout, onTimeout: () {
        fail('MapLibre did not become ready within 60 s.');
      });
      await _settle(tester, const Duration(seconds: 2));

      final native = controller;
      if (native == null) {
        fail('the native controller was never created');
      }

      // A live run follows YOU: the scene the style-load path drew centred the
      // native camera on the fix, not on the whole route. The visible region is
      // asked of the native map, so this is the camera itself, not a cached
      // value the widget believes.
      final atStart = await native.getVisibleRegion();
      final startCentre = _centreOf(atStart);
      expect(startCentre.latitude, closeTo(first.latitude, 1e-3));
      expect(startCentre.longitude, closeTo(first.longitude, 1e-3));

      // The route source carries the route geometry. Android answers a source
      // query per loaded tile and clips at the tile edges, so one GeoJSON line
      // can come back as several LineStrings — assert the coordinates belong to
      // the route instead of a feature count.
      final route = await _sourceCoordinates(
        native,
        MaplibreRouteMap.routeSourceId,
        reason: 'the route source must hold the route',
      );
      _expectWithin(route, geometry, reason: 'the route source must hold the route');

      // The travelled source carries only the covered fraction, so every
      // coordinate stays inside the first quarter of the loop.
      final traveledBefore = await _sourceCoordinates(
        native,
        MaplibreRouteMap.traveledSourceId,
        reason: 'the travelled source must hold the covered fraction',
      );
      _expectWithin(
        traveledBefore,
        traveledGeometry(geometry, 0.25),
        reason: 'the travelled source must hold only the covered fraction',
      );

      // New fixes land as a new scene: the travelled source grows and the
      // camera keeps following. A failed source/layer update surfaces here as
      // an exception.
      await tester.pumpWidget(
        map(
          MapScene(
            geometry: geometry,
            you: second,
            youProgress: 0.75,
            ghost: geometry.last,
          ),
        ),
      );
      await _settle(tester, const Duration(seconds: 2));

      final traveledAfter = await _sourceCoordinates(
        native,
        MaplibreRouteMap.traveledSourceId,
        reason: 'the travelled source must follow the new position',
      );
      expect(
        traveledAfter.length,
        greaterThan(1),
        reason: 'the travelled line must follow the new position',
      );
      // The travelled line now reaches YOU at 75 % of the loop.
      expect(
        traveledAfter.any((c) => (c[0] - second.longitude).abs() < 1e-5 &&
            (c[1] - second.latitude).abs() < 1e-5),
        isTrue,
        reason: 'the travelled source must reach the new position',
      );
      _expectWithin(
        traveledAfter,
        traveledGeometry(geometry, 0.75),
        reason: 'the travelled source must hold only the covered fraction',
      );

      final moved = _centreOf(await native.getVisibleRegion());
      expect(moved.latitude, closeTo(second.latitude, 1e-3));
      expect(moved.longitude, closeTo(second.longitude, 1e-3));
      // The style setup runs once; later scenes only sync sources/markers.
      expect(readyCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unreachable style document fails quietly',
    skip: _mapView != 'true',
    (tester) async {
      var readyCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: MaplibreRouteMap(
              scene: MapScene(
                geometry: FakeEngineService.riverLoop,
                you: FakeEngineService.riverLoop.first,
                youProgress: 0,
              ),
              // Reserved TLD: resolution always fails, deterministically.
              styleUrl: 'https://style.invalid/style.json',
              onReady: () => readyCalls++,
            ),
          ),
        ),
      );

      await _settle(tester, const Duration(seconds: 15));

      // No style means no map to draw, but the screen must survive: the view
      // stays mounted, nothing is reported ready, and no Dart error escapes.
      // (The route-detail thumbnail shows its empty state instead of hanging,
      // which is covered by the hermetic painter tests.)
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(readyCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Pumps frames for [duration] of wall time so native camera animations can
/// finish; the native side does not schedule Dart frames while it moves.
Future<void> _settle(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The centre of a visible region, as the native map reports it.
LatLng _centreOf(LatLngBounds bounds) => LatLng(
  (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
  (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
);

/// Reads a line source's coordinates, waiting for the native map to have tiled
/// it for the current viewport.
///
/// A source query is answered from the tiles the renderer has loaded, so it is
/// briefly empty right after a camera move (the first attempt after the map
/// jumped onto YOU answered `[]`). Poll until it has something, and fail with
/// the source id rather than an empty matcher diff if it never does.
Future<List<List<double>>> _sourceCoordinates(
  MapLibreMapController controller,
  String sourceId, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final coordinates = _lineCoordinates(
      await controller.querySourceFeatures(sourceId, null, null),
    );
    if (coordinates.isNotEmpty) {
      return coordinates;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail(
    'the native source "$sourceId" stayed empty for ${timeout.inSeconds}s '
    '($reason)',
  );
}

/// Every coordinate pair a GeoJSON line source holds.
///
/// `querySourceFeatures` proves what is actually in the native source instead of
/// trusting the widget. Android answers per loaded tile and clips the lines at
/// the tile edges, so one source line can arrive as several LineStrings — the
/// coordinates are flattened, and callers assert containment rather than shape.
List<List<double>> _lineCoordinates(List features) {
  final coordinates = <List<double>>[];
  void addLine(List positions) {
    for (final pair in positions) {
      coordinates.add([
        ((pair as List)[0] as num).toDouble(),
        (pair[1] as num).toDouble(),
      ]);
    }
  }

  for (final feature in features) {
    final geometry = (feature as Map)['geometry'] as Map;
    // MapLibre answers per tile and may hand back either a LineString or the
    // tile-clipped pieces as a MultiLineString, occasionally for the same
    // source in one run.
    switch (geometry['type']) {
      case 'LineString':
        addLine(geometry['coordinates'] as List);
      case 'MultiLineString':
        for (final line in geometry['coordinates'] as List) {
          addLine(line as List);
        }
      default:
        fail('unexpected geometry in a line source: ${geometry['type']}');
    }
  }
  return coordinates;
}

/// Asserts every coordinate lies inside the bounding box of [geometry].
///
/// Clipping only ever removes ground, so a source that covers the route (or the
/// travelled fraction of it) can never answer with a coordinate outside it.
void _expectWithin(
  List<List<double>> coordinates,
  List<GeoPoint> geometry, {
  required String reason,
}) {
  expect(coordinates, isNotEmpty, reason: reason);
  final lats = geometry.map((p) => p.latitude);
  final lons = geometry.map((p) => p.longitude);
  final minLat = lats.reduce(_min);
  final maxLat = lats.reduce(_max);
  final minLon = lons.reduce(_min);
  final maxLon = lons.reduce(_max);
  for (final coordinate in coordinates) {
    expect(coordinate[0], inInclusiveRange(minLon - 1e-6, maxLon + 1e-6),
        reason: reason);
    expect(coordinate[1], inInclusiveRange(minLat - 1e-6, maxLat + 1e-6),
        reason: reason);
  }
}

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;
