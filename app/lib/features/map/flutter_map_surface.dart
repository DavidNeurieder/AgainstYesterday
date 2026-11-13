// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A desktop map renderer built on `flutter_map` (raster OSM tiles).
///
/// MapLibre Native has no Linux desktop target, so desktop builds use this
/// surface instead. It is deliberately simpler than the MapLibre one: it draws
/// the route, the travelled portion and YOU/the ghost over OSM tiles, and the
/// camera follows YOU on a live run until the user pans (a recenter button
/// re-attaches it). A static view fits the whole geometry instead.
///
/// Map data is OpenStreetMap (ODbL) and is attributed on the map. Point
/// `MAP_TILE_URL` at a self-hosted tile server for anything beyond light use:
/// the public OSM tile servers are not a free CDN.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import '../../engine/models.dart';
import 'cached_raster_tile_provider.dart';
import 'map_surface.dart';

/// The raster tile template. Overridable at build time (`MAP_TILE_URL`) so a
/// self-hosted or commercial tile server can replace the OSM default without a
/// code change.
const String kMapTileUrlDefine = String.fromEnvironment(
  'MAP_TILE_URL',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);

class FlutterMapSurface implements MapSurface {
  const FlutterMapSurface({this.cacheRoot});

  /// When set, raster tiles are served from this on-disk cache before the
  /// network, so saved route regions work offline.
  final Directory? cacheRoot;

  @override
  Widget build(BuildContext context, MapScene scene, {bool fullscreen = true}) {
    final map = FlutterMapRouteMap(scene: scene, cacheRoot: cacheRoot);
    if (!fullscreen) return map;
    return Stack(
      children: [
        map,
        Positioned(
          right: 8,
          bottom: 8,
          child: FloatingActionButton.small(
            heroTag: null,
            onPressed: () => showFullscreenMap(context, scene, this),
            child: const Icon(Icons.fullscreen),
          ),
        ),
      ],
    );
  }
}

/// The desktop map view. Kept public so a widget test can pump it directly;
/// screens go through [MapSurface].
class FlutterMapRouteMap extends StatefulWidget {
  const FlutterMapRouteMap({
    super.key,
    required this.scene,
    this.tileUrl,
    this.cacheRoot,
  });

  final MapScene scene;

  /// Tile template override, defaulting to [kMapTileUrlDefine].
  final String? tileUrl;

  /// On-disk raster tile cache root; when set, cached tiles are preferred.
  final Directory? cacheRoot;

  @override
  State<FlutterMapRouteMap> createState() => _FlutterMapRouteMapState();
}

class _FlutterMapRouteMapState extends State<FlutterMapRouteMap> {
  static const double _followZoom = 16;

  final MapController _controller = MapController();

  /// Camera follows YOU until the user pans (live run only).
  bool _follow = true;

  /// False until the map has been built once: the controller is only attached
  /// to the map after that, so camera calls before then would throw.
  bool _ready = false;

  /// Whether a static view has already been fitted (the geometry is fixed).
  bool _fitted = false;

  LatLng? _lastYou;

  @override
  void initState() {
    super.initState();
    _follow = !widget.scene.staticView;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ready = true;
      _applyCamera();
    });
  }

  @override
  void didUpdateWidget(covariant FlutterMapRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene.geometry != widget.scene.geometry) {
      _fitted = false;
    }
    if (!_ready) {
      return;
    }
    final you = _toLatLng(widget.scene.you);
    final moved =
        _lastYou == null ||
        _lastYou!.latitude != you.latitude ||
        _lastYou!.longitude != you.longitude;
    if (widget.scene.staticView) {
      _applyCamera();
    } else if (_follow && moved) {
      _applyCamera();
    }
  }

  /// Frames the scene: the whole geometry for a thumbnail, YOU for a live run.
  void _applyCamera() {
    final scene = widget.scene;
    if (scene.staticView) {
      if (_fitted || scene.geometry.isEmpty) {
        return;
      }
      _fitted = true;
      _controller.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(
            scene.geometry.map(_toLatLng).toList(),
          ),
          padding: const EdgeInsets.all(32),
        ),
      );
      return;
    }
    final you = _toLatLng(scene.you);
    _lastYou = you;
    _controller.move(you, _controller.camera.zoom);
  }

  void _recenter() {
    setState(() => _follow = true);
    _applyCamera();
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final geometry = scene.geometry.map(_toLatLng).toList();
    final traveledCount = (geometry.length * scene.youProgress).round().clamp(
      0,
      geometry.length,
    );
    final traveled = geometry.take(traveledCount).toList();

    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: geometry.isNotEmpty
                ? geometry.first
                : _toLatLng(scene.you),
            initialZoom: _followZoom,
            backgroundColor: AppColors.background,
            onPositionChanged: (position, hasGesture) {
              if (hasGesture && !scene.staticView && _follow) {
                setState(() => _follow = false);
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: widget.tileUrl ?? kMapTileUrlDefine,
              userAgentPackageName: 'app.against_yesterday',
              maxNativeZoom: 19,
              tileProvider: widget.cacheRoot == null
                  ? null
                  : CachedRasterTileProvider(cacheRoot: widget.cacheRoot!),
            ),
            if (scene.track.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: scene.track.map(_toLatLng).toList(),
                    strokeWidth: 4,
                    color: AppColors.track,
                  ),
                ],
              ),
            if (traveled.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: traveled,
                    strokeWidth: 4,
                    color: AppColors.track,
                  ),
                ],
              ),
            if (geometry.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: geometry,
                    strokeWidth: 4,
                    color: scene.courseColor ??
                        AppColors.ghost.withValues(alpha: 0.35),
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (scene.ghost != null)
                  Marker(
                    point: _toLatLng(scene.ghost!),
                    width: 14,
                    height: 14,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: AppColors.ghost,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Marker(
                  point: _toLatLng(scene.you),
                  width: 16,
                  height: 16,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.you,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.background, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            _MapAttribution(tileUrl: widget.tileUrl ?? kMapTileUrlDefine),
          ],
        ),
        if (scene.name case final name?)
          Positioned(
            left: 14,
            top: 8,
            child: IgnorePointer(
              child: Text(
                name,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (!scene.staticView && !_follow)
          Positioned(
            right: 10,
            top: 10,
            child: _RecenterButton(onPressed: _recenter),
          ),
      ],
    );
  }
}

/// A compact, non-interactive attribution line.
///
/// `flutter_map`'s own attribution widget builds an unconstrained `Row` that
/// overflows small map panes, so this keeps it to a single small line. OSM data
/// (ODbL) must be attributed wherever it is shown.
class _MapAttribution extends StatelessWidget {
  const _MapAttribution({required this.tileUrl});

  final String tileUrl;

  @override
  Widget build(BuildContext context) {
    final isOsm =
        tileUrl.contains('openstreetmap.org') ||
        tileUrl.contains('tile.osm.org');
    if (!isOsm) {
      return const SizedBox.shrink();
    }
    return Positioned(
      right: 6,
      bottom: 4,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              '© OpenStreetMap contributors',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(
                fontSize: 9,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(
            Icons.my_location,
            size: 18,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

LatLng _toLatLng(GeoPoint point) => LatLng(point.latitude, point.longitude);
