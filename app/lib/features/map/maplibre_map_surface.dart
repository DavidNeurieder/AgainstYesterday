// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The offline MapLibre renderer behind [MapSurface].
///
/// Draws the scene's geometry as a GeoJSON `LineString` over a vector style and
/// moves the camera: follows YOU on a live run, or fits the whole geometry for
/// the static thumbnail. The style URL comes from `MAP_STYLE_URL` so a
/// self-hosted tile server can replace the default without a code change.
///
/// Phase 0 wires the seam and a minimal renderer; the follow/recenter parity,
/// the recorded-track layer for activity detail, and the offline-region
/// downloads land in later phases (see `ideas/offline_map_plan.txt`).
library;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../engine/models.dart';
import 'map_surface.dart';
import 'track_geojson.dart';

class MaplibreMapSurface implements MapSurface {
  const MaplibreMapSurface();

  @override
  Widget build(BuildContext context, MapScene scene) =>
      MaplibreRouteMap(scene: scene);
}

/// The live MapLibre view. Kept public so integration tests can pump it
/// directly; screens go through [MapSurface].
class MaplibreRouteMap extends StatefulWidget {
  const MaplibreRouteMap({super.key, required this.scene});

  final MapScene scene;

  @override
  State<MaplibreRouteMap> createState() => _MaplibreRouteMapState();
}

class _MaplibreRouteMapState extends State<MaplibreRouteMap> {
  static const String _sourceId = 'against-yesterday-route';
  static const String _layerId = 'against-yesterday-route-line';

  /// Matches `AppColors.ghost` (#8593A7); the map layer takes a CSS color.
  static const String _routeColor = '#8593A7';

  /// Default follow zoom; the fitted camera uses bounds instead.
  static const double _followZoom = 16;

  MapLibreMapController? _controller;
  bool _styleLoaded = false;

  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      styleString: kMapStyleUrlDefine,
      initialCameraPosition: CameraPosition(
        target: _center(widget.scene.geometry),
        zoom: _followZoom,
      ),
      onMapCreated: (controller) => _controller = controller,
      onStyleLoadedCallback: _onStyleLoaded,
      attributionButtonPosition: AttributionButtonPosition.bottomLeft,
      myLocationEnabled: false,
    );
  }

  @override
  void didUpdateWidget(MaplibreRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_styleLoaded) {
      _refresh();
    }
  }

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    _styleLoaded = true;
    await controller.addGeoJsonSource(
      _sourceId,
      lineStringFeatureCollection(widget.scene.geometry),
    );
    await controller.addLineLayer(
      _sourceId,
      _layerId,
      const LineLayerProperties(
        lineColor: _routeColor,
        lineWidth: 3,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    await _moveCamera(animate: false);
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) {
      return;
    }
    await controller.setGeoJsonSource(
      _sourceId,
      lineStringFeatureCollection(widget.scene.geometry),
    );
    await _moveCamera(animate: true);
  }

  Future<void> _moveCamera({required bool animate}) async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    final scene = widget.scene;
    if (scene.geometry.isEmpty) {
      return;
    }
    final CameraUpdate update;
    if (!scene.staticView && scene.followsYou) {
      update = CameraUpdate.newLatLngZoom(
        LatLng(scene.you.latitude, scene.you.longitude),
        _followZoom,
      );
    } else {
      update = CameraUpdate.newLatLngBounds(
        _bounds(scene.geometry),
        left: 32,
        top: 32,
        right: 32,
        bottom: 32,
      );
    }
    if (animate) {
      await controller.animateCamera(
        update,
        duration: const Duration(milliseconds: 400),
      );
    } else {
      await controller.moveCamera(update);
    }
  }

  static LatLng _center(List<GeoPoint> geometry) {
    if (geometry.isEmpty) {
      return const LatLng(0, 0);
    }
    var minLat = geometry.first.latitude;
    var maxLat = geometry.first.latitude;
    var minLon = geometry.first.longitude;
    var maxLon = geometry.first.longitude;
    for (final p in geometry) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
  }

  static LatLngBounds _bounds(List<GeoPoint> geometry) {
    var minLat = geometry.first.latitude;
    var maxLat = geometry.first.latitude;
    var minLon = geometry.first.longitude;
    var maxLon = geometry.first.longitude;
    for (final p in geometry) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );
  }
}
