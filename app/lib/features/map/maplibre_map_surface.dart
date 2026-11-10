// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The offline MapLibre renderer behind [MapSurface].
///
/// Draws the scene as GeoJSON line layers over a vector style — the full route
/// faint, the travelled portion in a track green that contrasts with the light
/// map style — plus circle markers for YOU and the PB ghost. The camera
/// follows YOU on a live run until the user pans, when a recenter button
/// re-attaches it; replay locks the follow so playback always stays centred.
/// A static thumbnail fits the whole geometry instead. The style URL comes from
/// `MAP_STYLE_URL` so a self-hosted tile server can replace the default without
/// a code change.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
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
  const MaplibreRouteMap({
    super.key,
    required this.scene,
    this.onReady,
    this.onMapCreated,
    this.styleUrl,
  });

  final MapScene scene;

  /// Invoked once after the style has loaded and the first scene was drawn —
  /// the on-device map smoke test waits on it so it knows the native map
  /// really initialised, instead of asserting on a widget that may never
  /// have touched MapLibre Native.
  final VoidCallback? onReady;

  /// Invoked with the native controller once the platform view exists.
  ///
  /// The on-device smoke test uses it to assert the camera actually follows
  /// YOU as new fixes arrive; screens never pass it.
  final ValueChanged<MapLibreMapController>? onMapCreated;

  /// The style document, defaulting to the `MAP_STYLE_URL` build define. The
  /// smoke test points it at an unreachable document to prove a failed style
  /// load degrades quietly instead of taking the screen down.
  final String? styleUrl;

  /// The GeoJSON source holding the whole geometry, faint under the track.
  ///
  /// Public so the on-device smoke test can query the native source and assert
  /// it carries the route, rather than only that a map widget exists.
  static const String routeSourceId = 'against-yesterday-route';

  /// The GeoJSON source holding the travelled fraction of the geometry.
  static const String traveledSourceId = 'against-yesterday-traveled';

  /// The GeoJSON source holding the actual recorded GPS track.
  static const String trackSourceId = 'against-yesterday-track';

  @override
  State<MaplibreRouteMap> createState() => _MaplibreRouteMapState();
}

class _MaplibreRouteMapState extends State<MaplibreRouteMap> {
  static const String _routeSourceId = MaplibreRouteMap.routeSourceId;
  static const String _routeLayerId = 'against-yesterday-route-line';
  static const String _traveledSourceId = MaplibreRouteMap.traveledSourceId;
  static const String _traveledLayerId = 'against-yesterday-traveled-line';
  static const String _trackSourceId = MaplibreRouteMap.trackSourceId;
  static const String _trackLayerId = 'against-yesterday-track-line';

  /// The default course backdrop (`AppColors.ghost`, #8593A7) used when the
  /// scene does not ask for a visible course colour. Map layers take CSS
  /// colour strings.
  static const String _routeColor = '#8593A7';

  /// `AppColors.track` (#34C77B): the travelled GPS path, kept green so it
  /// stands out over the light OpenFreeMap style.
  static const String _traveledColor = '#34C77B';

  /// `AppColors.you` (#F2F4F8) and `AppColors.background` (#0E1116).
  static const String _youColor = '#F2F4F8';
  static const String _strokeColor = '#0E1116';

  /// CSS hex (`#rrggbb`) for a scene colour; alpha is carried separately by
  /// `lineOpacity`.
  static String _cssHex(Color color) {
    final argb = color.toARGB32();
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  static const double _followZoom = 16;

  MapLibreMapController? _controller;
  bool _styleLoaded = false;

  /// Camera follows YOU until the user pans (live run only).
  bool _follow = true;

  /// True once the scene's camera has been applied for the current style.
  ///
  /// Until then, camera events belong to the platform's own setup (it restores
  /// the camera the view was constructed with) and must not be mistaken for the
  /// user panning away — that would detach the follow before it ever ran.
  bool _cameraSettled = false;

  /// Suppresses [_onCameraMove] while the camera moves on our behalf.
  bool _programmatic = false;

  /// Whether a finger is on the map right now.
  ///
  /// The platform reports a camera move without saying whether a gesture caused
  /// it, and the app's own follow moves plus the native view's camera restore
  /// look identical to a drag once the call has returned. Only a real pointer
  /// detaches the follow; everything else is re-asserted.
  bool _touching = false;

  /// When the map last received a pointer down/up.
  ///
  /// Native camera events arrive over the channel behind the touch that caused
  /// them, so the detach decision also covers a short grace window after the
  /// finger lifts (fling inertia lands there too).
  DateTime _lastPointer = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _gestureGrace = Duration(milliseconds: 600);

  /// Whether the camera is moving because the user is touching the map.
  bool get _userGesture =>
      _touching || DateTime.now().difference(_lastPointer) < _gestureGrace;

  /// Bounds the re-asserts so a native camera that refuses to stay on YOU
  /// cannot start a feedback loop of move events and corrections.
  int _cameraReasserts = 0;
  static const int _maxCameraReasserts = 8;

  Timer? _cameraWatchdog;

  Circle? _youCircle;
  Circle? _ghostCircle;

  /// A scene update is being applied. Playback can enqueue one per frame, and
  /// the native calls are asynchronous — letting two updates overlap lets an
  /// older camera move land after a newer one, which reads as jitter and a map
  /// that never catches up. Newer scenes coalesce into one follow-up pass.
  bool _syncing = false;
  bool _syncPending = false;

  /// What the native map currently holds, so unchanged sources are not
  /// re-sent every frame.
  List<GeoPoint>? _syncedGeometry;
  List<GeoPoint>? _syncedTrack;
  double? _syncedProgress;
  GeoPoint? _syncedYou;
  GeoPoint? _syncedGhost;

  /// The geometry sources are heavy (a growing line serialised to GeoJSON on
  /// the UI isolate). At 32× replay they change every frame, so they are
  /// updated at most this often while the camera and the YOU marker keep
  /// following every frame.
  static const Duration _dataInterval = Duration(milliseconds: 100);

  /// When the geometry sources were last sent.
  DateTime _lastDataSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// Trailing update so the last frame of a burst still reaches the sources
  /// instead of leaving the line one step behind.
  Timer? _dataTimer;

  @override
  void dispose() {
    _dataTimer?.cancel();
    _cameraWatchdog?.cancel();
    super.dispose();
  }

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
        // Pointer tracking is the only reliable "the user did this" signal the
        // platform gives us (camera events do not carry their cause), so the
        // map itself is wrapped rather than trusting the camera target to tell
        // a pan apart from a native restore.
        Listener(
          onPointerDown: (_) => _onPointer(down: true),
          onPointerUp: (_) => _onPointer(down: false),
          onPointerCancel: (_) => _onPointer(down: false),
          child: MapLibreMap(
            styleString: widget.styleUrl ?? kMapStyleUrlDefine,
            initialCameraPosition: CameraPosition(
              target: _initialTarget(widget.scene),
              zoom: _followZoom,
            ),
            onMapCreated: (controller) {
              _controller = controller;
              widget.onMapCreated?.call(controller);
            },
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraMove: _onCameraMove,
            trackCameraPosition: true,
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
            myLocationEnabled: false,
          ),
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
    if (!_styleLoaded) {
      return;
    }
    final scene = widget.scene;
    final previous = oldWidget.scene;
    if (scene.you == previous.you &&
        scene.ghost == previous.ghost &&
        scene.youProgress == previous.youProgress &&
        scene.staticView == previous.staticView &&
        listEquals(scene.geometry, previous.geometry) &&
        listEquals(scene.track, previous.track)) {
      return;
    }
    _scheduleSync();
  }

  /// Applies the latest scene, coalescing bursts (replay sends one per frame).
  ///
  /// Scene updates never animate: playback moves YOU a few metres each frame,
  /// so an immediate camera move is both centred and smooth, while a 400 ms
  /// animation restarted per frame can never catch up — at 32× it trails the
  /// replay by hundreds of metres.
  void _scheduleSync() {
    if (_syncing) {
      _syncPending = true;
      return;
    }
    unawaited(_drainSync());
  }

  Future<void> _drainSync() async {
    _syncing = true;
    try {
      do {
        _syncPending = false;
        await _sync(animate: false);
      } while (_syncPending && mounted);
    } finally {
      _syncing = false;
    }
  }

  /// Records a pointer on the map so [_onCameraMove] can tell a gesture from a
  /// native/programmatic move.
  void _onPointer({required bool down}) {
    _touching = down;
    _lastPointer = DateTime.now();
  }

  void _onCameraMove(CameraPosition position) {
    if (_programmatic ||
        !_cameraSettled ||
        widget.scene.staticView ||
        !_follow) {
      return;
    }
    if (_sameSpot(position.target, widget.scene.you)) {
      return;
    }
    if (_userGesture && !widget.scene.followLocked) {
      // A real drag: the user is looking somewhere else, so the follow stops
      // and the recenter button appears (§16). A replay owns the camera, so
      // even a gesture there must not stop the playback follow.
      setState(() => _follow = false);
      return;
    }
    // Not the user. The platform re-applies the camera the view was
    // constructed with once the view finishes setting up, and that can land
    // after [_settleFirstCamera] has stopped waiting. Verified on device: the
    // map then sat on the scene's starting ground while YOU kept moving, which
    // reads as "the map is stuck on the last run". Put the camera back instead
    // of silently detaching the follow.
    if (_cameraReasserts >= _maxCameraReasserts) {
      return;
    }
    _cameraReasserts++;
    _scheduleSync();
  }

  void _recenter() {
    _cameraReasserts = 0;
    setState(() => _follow = true);
    _animateToYou();
    _watchFirstCamera();
  }

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    _cameraSettled = false;
    _cameraReasserts = 0;
    await controller.addGeoJsonSource(
      _routeSourceId,
      lineStringFeatureCollection(widget.scene.geometry),
    );
    await controller.addGeoJsonSource(
      _trackSourceId,
      lineStringFeatureCollection(widget.scene.track),
    );
    await controller.addLineLayer(
      _trackSourceId,
      _trackLayerId,
      const LineLayerProperties(
        lineColor: _traveledColor,
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
    final course = widget.scene.courseColor;
    await controller.addLineLayer(
      _routeSourceId,
      _routeLayerId,
      LineLayerProperties(
        lineColor: course == null ? _routeColor : _cssHex(course),
        lineOpacity: course == null ? 0.35 : 1.0,
        lineWidth: 4,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    // Scene updates may only start once the style is fully prepared: an
    // `addGeoJsonSource`/`setGeoJsonSource` pair racing on the channel is a
    // native error. Frames that arrived meanwhile are picked up by `_sync`.
    _styleLoaded = true;
    await _sync(animate: false);
    await _settleFirstCamera();
    _watchFirstCamera();
    widget.onReady?.call();
  }

  /// Number of times the first camera application is checked/retried.
  static const int _cameraAttempts = 4;

  /// Gap between those attempts: long enough for the platform view to finish
  /// the setup pass that was overwriting the move.
  static const Duration _cameraRetryDelay = Duration(milliseconds: 150);

  /// Cancels the effect of a native camera restore on the first frame.
  ///
  /// MapLibre re-applies the camera the view was *constructed* with when the
  /// platform view finishes setting up, which lands after a move issued from
  /// the style-loaded callback and silently undoes it (verified on device: the
  /// map stayed on the geometry's bounding-box centre at the follow zoom
  /// instead of moving onto YOU, leaving a route-detail thumbnail unfitted and
  /// a live run half a screen off until the next fix). Ask the native camera
  /// where it actually is and re-apply until the scene is framed.
  Future<void> _settleFirstCamera() async {
    try {
      for (var attempt = 0; attempt < _cameraAttempts; attempt++) {
        if (!mounted || await _cameraIsOnScene()) {
          return;
        }
        await _applySceneCamera(animate: false);
        await Future<void>.delayed(_cameraRetryDelay);
      }
    } finally {
      // From here on a camera that is not looking at YOU is either the user
      // panning away or the platform's own setup; [_onCameraMove] sorts that
      // out by whether a finger is on the map.
      _cameraSettled = true;
    }
  }

  /// A native camera restore can land even later than [_settleFirstCamera]
  /// waits, and standing still produces no scene update to sync the camera
  /// back. Re-check a few times with growing gaps (a fresh camera event also
  /// re-asserts). Best-effort: a map that refuses to report its camera is
  /// left alone rather than throwing.
  void _watchFirstCamera([int index = 0]) {
    _cameraWatchdog?.cancel();
    if (index >= _cameraChecks.length) return;
    _cameraWatchdog = Timer(_cameraChecks[index], () async {
      if (!mounted || widget.scene.staticView || !_follow || _userGesture) {
        return;
      }
      if (!await _cameraIsOnScene()) {
        await _applySceneCamera(animate: false);
      }
      _watchFirstCamera(index + 1);
    });
  }

  /// When the first-camera checks run again after the style pass.
  static const List<Duration> _cameraChecks = [
    Duration(milliseconds: 600),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 3000),
  ];

  /// [_cameraInPlace] for callers that must not throw on a map that is not
  /// ready to answer yet.
  Future<bool> _cameraIsOnScene() async {
    try {
      return await _cameraInPlace();
    } catch (_) {
      return false;
    }
  }

  /// Whether the native camera already frames the current scene.
  Future<bool> _cameraInPlace() async {
    final controller = _controller;
    final scene = widget.scene;
    if (controller == null) {
      return true;
    }
    if (!scene.staticView && !_follow) {
      // The user panned away mid-setup: do not fight them.
      return true;
    }
    if (_userGesture) {
      // A finger is on the map (or just lifted): never fight a gesture.
      return true;
    }
    final region = await controller.getVisibleRegion();
    if (scene.geometry.isEmpty) {
      if (scene.staticView) {
        return true;
      }
      return _sameSpot(_centreOf(region), scene.you);
    }
    if (scene.staticView) {
      // A fitted thumbnail shows the whole geometry.
      return scene.geometry.every((p) => _contains(region, p));
    }
    return _sameSpot(_centreOf(region), scene.you);
  }

  Future<void> _sync({required bool animate}) async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) {
      return;
    }
    final scene = widget.scene;
    // Camera first: it is what the eye tracks, and letting the heavier source
    // updates land first would hand the camera a stale position each frame.
    await _applySceneCamera(animate: animate);

    final geometryChanged = !listEquals(scene.geometry, _syncedGeometry);
    final trackChanged = !listEquals(scene.track, _syncedTrack);
    final traveledChanged =
        geometryChanged || scene.youProgress != _syncedProgress;
    final dataChanged = geometryChanged || trackChanged || traveledChanged;
    final dataDue =
        DateTime.now().difference(_lastDataSync) >= _dataInterval;

    // Markers stay per-frame: they are a single point each, and the eye is on
    // YOU. The line sources are throttled to [_dataInterval] so 32× playback
    // does not serialise a growing route every frame.
    if (dataChanged && !dataDue) {
      _dataTimer ??= Timer(_dataInterval, () {
        _dataTimer = null;
        if (mounted && _styleLoaded) {
          _scheduleSync();
        }
      });
    }
    if (dataDue) {
      _lastDataSync = DateTime.now();
      if (geometryChanged) {
        _syncedGeometry = scene.geometry;
        await controller.setGeoJsonSource(
          _routeSourceId,
          lineStringFeatureCollection(scene.geometry),
        );
      }
      if (traveledChanged) {
        _syncedProgress = scene.youProgress;
        await controller.setGeoJsonSource(
          _traveledSourceId,
          lineStringFeatureCollection(
            traveledGeometry(scene.geometry, scene.youProgress),
          ),
        );
      }
      if (trackChanged) {
        _syncedTrack = scene.track;
        await controller.setGeoJsonSource(
          _trackSourceId,
          lineStringFeatureCollection(scene.track),
        );
      }
    }
    if (scene.you != _syncedYou) {
      _syncedYou = scene.you;
      await _syncMarker(controller, you: true, position: scene.you);
    }
    if (scene.ghost != _syncedGhost) {
      _syncedGhost = scene.ghost;
      await _syncMarker(controller, you: false, position: scene.ghost);
    }
  }

  /// Frames the scene: the whole geometry for a thumbnail, YOU for a live run.
  Future<void> _applySceneCamera({required bool animate}) async {
    final scene = widget.scene;
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
    if (controller == null) {
      return;
    }
    final you = widget.scene.you;
    // Keep whatever zoom the user chose: re-applying the follow zoom every
    // frame made a pinch feel like it was fighting the camera.
    final update = CameraUpdate.newLatLng(LatLng(you.latitude, you.longitude));
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

  static LatLng _initialTarget(MapScene scene) {
    // A following scene opens on YOU, not on the geometry's centre. At the
    // follow zoom the centre framed nothing useful, and it is also the camera
    // the platform view restores on setup — so starting on YOU means even a
    // restore that never gets corrected shows the current position.
    if (!scene.staticView) {
      return LatLng(scene.you.latitude, scene.you.longitude);
    }
    if (scene.geometry.isNotEmpty) {
      return _center(scene.geometry);
    }
    return LatLng(scene.you.latitude, scene.you.longitude);
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

  /// How close the camera centre must be to YOU to count as "on YOU".
  ///
  /// ~110 m: at the follow zoom a real offset is plainly visible, while the
  /// projection round trip through the platform channel stays well inside this.
  static const double _cameraTolerance = 1e-3;

  static bool _sameSpot(LatLng camera, GeoPoint target) =>
      (camera.latitude - target.latitude).abs() < _cameraTolerance &&
      (camera.longitude - target.longitude).abs() < _cameraTolerance;

  static LatLng _centreOf(LatLngBounds bounds) => LatLng(
    (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
    (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
  );

  static bool _contains(LatLngBounds bounds, GeoPoint point) =>
      point.latitude >= bounds.southwest.latitude &&
      point.latitude <= bounds.northeast.latitude &&
      point.longitude >= bounds.southwest.longitude &&
      point.longitude <= bounds.northeast.longitude;

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
