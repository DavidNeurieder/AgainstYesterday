// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The map seam.
///
/// Every screen that shows route or track geometry goes through a [MapSurface]
/// instead of a concrete map widget, exactly as the app reaches the engine only
/// through `EngineService`. The concrete renderer is chosen at build time from
/// `MAP_VIEW`, with one host exception:
///
///  * desktop (Linux) — [FlutterMapSurface], raster OSM tiles via `flutter_map`.
///    MapLibre Native has no Linux target, so this is the renderer desktop
///    gets regardless of `MAP_VIEW`.
///  * widget tests — [PainterMapSurface]. The test runner runs on the desktop
///    host, but tests must stay hermetic (no tile downloads, no oversized
///    layouts in tiny test viewports), so the painter is used there.
///  * unset / `false` — [PainterMapSurface], the self-contained `RouteMap`
///    painter.
///  * `true` — [MaplibreMapSurface], the offline MapLibre renderer used on
///    device builds.
///
/// The tri-state is deliberately conservative: unlike the Rust engine there is
/// no runtime "did the native library load" probe for MapLibre, so the fallback
/// is the default and device artifacts opt in explicitly.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/models.dart';
import '../settings/application/settings_controller.dart';
import 'flutter_map_surface.dart';
import 'maplibre_map_surface.dart';
import 'offline_region_downloader.dart';
import 'painter_map_surface.dart';

/// Which renderer the build asked for.
enum MapRenderer {
  /// The self-contained painter (`widgets/route_map.dart`).
  painter,

  /// MapLibre Native: vector tiles, GeoJSON layers, offline regions.
  maplibre,
}

/// The `MAP_VIEW` build-time switch (a `--dart-define`, not an environment
/// variable). Only the exact string `true` selects MapLibre.
const String kMapViewDefine = String.fromEnvironment('MAP_VIEW');

/// The MapLibre style document. Overridable at build time (`MAP_STYLE_URL`) so a
/// self-hosted tile server can be dropped in without a code change. Defaults to
/// OpenFreeMap's Liberty style (free, no key; attribution is shown on the map).
const String kMapStyleUrlDefine = String.fromEnvironment(
  'MAP_STYLE_URL',
  defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
);

/// Resolves the raw `MAP_VIEW` value into a renderer a test can assert on.
MapRenderer mapRendererFromDefine(String raw) =>
    raw == 'true' ? MapRenderer.maplibre : MapRenderer.painter;

/// The renderer this build selected.
MapRenderer get selectedMapRenderer => mapRendererFromDefine(kMapViewDefine);

/// Everything a [MapSurface] needs to draw one scene. A plain value object so
/// the same scene can be driven through either renderer.
class MapScene {
  const MapScene({
    required this.geometry,
    this.track = const [],
    this.trackColors,
    required this.you,
    required this.youProgress,
    this.ghost,
    this.name,
    this.courseColor,
    this.staticView = false,
    this.followLocked = false,
  });

  /// The route (or recorded track) to draw.
  final List<GeoPoint> geometry;

  /// The actual recorded GPS path, drawn on top of [geometry] so a run that
  /// diverges from the planned course is still visible. Empty when there is
  /// no separate track (thumbnails, activity detail which uses [geometry]).
  final List<GeoPoint> track;

  /// Optional per-segment colours for [track] (length == track.length - 1).
  /// Used for pace colouring; renderers that cannot honour it fall back to a
  /// single colour.
  final List<Color>? trackColors;

  /// Current live position (YOU).
  final GeoPoint you;

  /// Fraction of the route completed (0..1).
  final double youProgress;

  /// PB ghost position, when racing a ghost.
  final GeoPoint? ghost;

  /// Route name shown as a corner label.
  final String? name;

  /// Colour for the whole course when it must stand out from the travelled
  /// track (record and replay). `null` keeps the faint backdrop that
  /// thumbnails use, so the recorded path stays the focus there.
  final Color? courseColor;

  /// Fits the whole geometry with no follow or panning (route-detail
  /// thumbnail).
  final bool staticView;

  /// Keeps the camera pinned to [you] even when a renderer would otherwise
  /// treat a camera move as the user panning away.
  ///
  /// Replay owns the camera: playback must stay centred on the replayed
  /// position, and the per-frame scene updates (plus seeks) must not detach
  /// the follow the way a deliberate pan on the live run does.
  final bool followLocked;
}

/// Renders a [MapScene]. Implemented by the painter fallback and by MapLibre.
abstract interface class MapSurface {
  Widget build(BuildContext context, MapScene scene);
}

/// The renderer for this build. Tests override it with a recording fake to
/// assert the scene a screen produced without touching a native map.
///
/// "Use maps" off wins over the build-time renderer: the painter needs no
/// network, so the app stays fully offline.
final mapSurfaceProvider = Provider<MapSurface>((ref) {
  return resolveMapSurface(
    isDesktop: Platform.isLinux,
    isTest: isFlutterTest,
    renderer: selectedMapRenderer,
    mapsEnabled: ref.watch(mapsEnabledProvider),
    rasterTileCacheRoot: ref.watch(mapTileCacheDirectoryProvider),
  );
});

/// Whether this process is the widget-test runner.
///
/// `flutter test` sets `FLUTTER_TEST=true` in the tester's environment; the
/// check is read at runtime because it is not a compile-time define.
bool get isFlutterTest => Platform.environment['FLUTTER_TEST'] == 'true';

/// Picks the surface for a host. Pure so the mapping can be tested without
/// depending on the host the test happens to run on.
///
/// [mapsEnabled] is the user's "Use maps" switch: off always returns the
/// painter, regardless of host or build flag, so no tile or style request can
/// leave the device.
MapSurface resolveMapSurface({
  required bool isDesktop,
  required bool isTest,
  required MapRenderer renderer,
  bool mapsEnabled = true,
  Directory? rasterTileCacheRoot,
}) {
  if (!mapsEnabled) {
    return const PainterMapSurface();
  }
  if (isTest) {
    return const PainterMapSurface();
  }
  if (isDesktop) {
    return FlutterMapSurface(cacheRoot: rasterTileCacheRoot);
  }
  return switch (renderer) {
    MapRenderer.maplibre => const MaplibreMapSurface(),
    MapRenderer.painter => const PainterMapSurface(),
  };
}
