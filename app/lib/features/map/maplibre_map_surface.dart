// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The offline MapLibre renderer behind [MapSurface].
///
/// Draws the scene as GeoJSON line layers over a vector style — the full route
/// faint, the travelled portion in a track green that contrasts with the light
/// map style — plus circle markers for YOU and the PB ghost. The camera
/// follows YOU on a live run until the user pans,
/// when a recenter button re-attaches it; a static thumbnail fits the whole
/// geometry instead. The style URL comes from `MAP_STYLE_URL` so a self-hosted
/// tile server can replace the default without a code change.
library;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/theme/app_colors.dart';
import '../../engine/models.dart';
import 'map_surface.dart';
import 'track_geojson.dart';

class MaplibreMapSurface implements MapSurface {
  const MaplibreMapSurface();

  @override
  Widget build(BuildContext context, MapScene scene) =>
      MaplibreRouteMap(scene: scene);
}

/// The live MapLibre view. Kept public so an integration test can pump it
/// directly; screens go through [MapSurface].
class MaplibreRouteMap extends StatefulWidget {
  const MaplibreRouteMap({super.key, required this.scene, this.onReady});

  final MapScene scene;

  /// Invoked once after the style has loaded and the first scene was drawn —
  /// the on-device map smoke test waits on it so it knows the native map
  /// really initialised, instead of asserting on a widget that may never
  /// have touched MapLibre Native.
  final VoidCallback? onReady;

  @override
  State<MaplibreRouteMap> createState() => _MaplibreRouteMapState();
}

class _MaplibreRouteMapState extends State<MaplibreRouteMap> {
  static const String _routeSourceId = 'against-yesterday-route';
  static const String _routeLayerId = 'against-yesterday-route-line';
  static const String _traveledSourceId = 'against-yesterday-traveled';
  static const String _traveledLayerId = 'against-yesterday-traveled-line';

  /// `AppColors.ghost` (#8593A7); map layers take CSS color strings.
  static const String _routeColor = '#8593A7';

  /// `AppColors.track` (#34C77B): the travelled GPS path, kept green so it
  /// stands out over the light OpenFreeMap style.
  static const String _traveledColor = '#34C77B';

  /// `AppColors.you` (#F2F4F8) and `AppColors.background` (#0E1116).
  static const String _youColor = '#F2F4F8';
  static const String _strokeColor = '#0E1116';

  static const double _followZoom = 16;

  MapLibreMapController? _controller;
  bool _styleLoaded = false;

  /// Camera follows YOU until the user pans (live run only).
  bool _follow = true;

  /// Suppresses [_onCameraMove] while the camera moves on our behalf.
  bool _programmatic = false;

  Circle? _youCircle;
  Circle? _ghostCircle;

  @override
  void initState() {
    super.initState();
    _follow = !widget.scene.staticView;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MapLibreMap(
          styleString: kMapStyleUrlDefine,
          initialCameraPosition: CameraPosition(
            target: _center(widget.scene.geometry),
            zoom: _followZoom,
          ),
          onMapCreated: (controller) => _controller = controller,
          onStyleLoadedCallback: _onStyleLoaded,
          onCameraMove: _onCameraMove,
          trackCameraPosition: true,
          attributionButtonPosition: AttributionButtonPosition.bottomLeft,
          myLocationEnabled: false,
        ),
        if (!widget.scene.staticView && !_follow)
          Positioned(
            right: 10,
            top: 10,
            child: _RecenterButton(onPressed: _recenter),
          ),
      ],
    );
  }

  @override
  void didUpdateWidget(MaplibreRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_styleLoaded) {
      _sync(animate: true);
    }
  }

  void _onCameraMove(CameraPosition position) {
    if (_programmatic || widget.scene.staticView || !_follow) {
      return;
    }
    setState(() => _follow = false);
  }

  void _recenter() {
    setState(() => _follow = true);
    _animateToYou();
  }

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    _styleLoaded = true;
    await controller.addGeoJsonSource(
      _routeSourceId,
      lineStringFeatureCollection(widget.scene.geometry),
    );
    await controller.addLineLayer(
      _routeSourceId,
      _routeLayerId,
      const LineLayerProperties(
        lineColor: _routeColor,
        lineOpacity: 0.35,
        lineWidth: 4,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    await controller.addGeoJsonSource(
      _traveledSourceId,
      lineStringFeatureCollection(
        traveledGeometry(widget.scene.geometry, widget.scene.youProgress),
      ),
    );
    await controller.addLineLayer(
      _traveledSourceId,
      _traveledLayerId,
      const LineLayerProperties(
        lineColor: _traveledColor,
        lineWidth: 4,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    await _sync(animate: false);
    widget.onReady?.call();
  }

  Future<void> _sync({required bool animate}) async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) {
      return;
    }
    final scene = widget.scene;
    await controller.setGeoJsonSource(
      _routeSourceId,
      lineStringFeatureCollection(scene.geometry),
    );
    await controller.setGeoJsonSource(
      _traveledSourceId,
      lineStringFeatureCollection(
        traveledGeometry(scene.geometry, scene.youProgress),
      ),
    );
    await _syncMarker(controller, you: true, position: scene.you);
    await _syncMarker(controller, you: false, position: scene.ghost);

    if (scene.staticView) {
      await _fitGeometry(animate: animate);
    } else if (_follow) {
      await _animateToYou(animate: animate);
    }
  }

  Future<void> _syncMarker(
    MapLibreMapController controller, {
    required bool you,
    required GeoPoint? position,
  }) async {
    final existing = you ? _youCircle : _ghostCircle;
    if (position == null) {
      if (existing != null) {
        await controller.removeCircle(existing);
        if (you) {
          _youCircle = null;
        } else {
          _ghostCircle = null;
        }
      }
      return;
    }
    final target = LatLng(position.latitude, position.longitude);
    if (existing == null) {
      final circle = await controller.addCircle(
        CircleOptions(
          geometry: target,
          circleRadius: you ? 8 : 6,
          circleColor: you ? _youColor : _routeColor,
          circleStrokeWidth: 2,
          circleStrokeColor: _strokeColor,
        ),
      );
      if (you) {
        _youCircle = circle;
      } else {
        _ghostCircle = circle;
      }
      return;
    }
    await controller.updateCircle(existing, CircleOptions(geometry: target));
  }

  Future<void> _animateToYou({bool animate = true}) async {
    final controller = _controller;
    final geometry = widget.scene.geometry;
    if (controller == null || geometry.isEmpty) {
      return;
    }
    final you = widget.scene.you;
    final update = CameraUpdate.newLatLngZoom(
      LatLng(you.latitude, you.longitude),
      _followZoom,
    );
    await _run(controller, update, animate: animate);
  }

  Future<void> _fitGeometry({required bool animate}) async {
    final controller = _controller;
    final geometry = widget.scene.geometry;
    if (controller == null || geometry.isEmpty) {
      return;
    }
    final update = CameraUpdate.newLatLngBounds(
      _bounds(geometry),
      left: 32,
      top: 32,
      right: 32,
      bottom: 32,
    );
    await _run(controller, update, animate: animate);
  }

  Future<void> _run(
    MapLibreMapController controller,
    CameraUpdate update, {
    required bool animate,
  }) async {
    _programmatic = true;
    try {
      if (animate) {
        await controller.animateCamera(
          update,
          duration: const Duration(milliseconds: 400),
        );
      } else {
        await controller.moveCamera(update);
      }
    } finally {
      _programmatic = false;
    }
  }

  static LatLng _center(List<GeoPoint> geometry) {
    if (geometry.isEmpty) {
      return const LatLng(0, 0);
    }
    final bounds = _bounds(geometry);
    return LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );
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

/// Re-attaches the camera to YOU after the user has panned (§16).
class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: const Tooltip(
          message: 'Recenter',
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Icon(
              Icons.my_location,
              size: 18,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
