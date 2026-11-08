// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The [MapSurface] fallback: the existing self-contained `RouteMap` painter.
///
/// This is what host tests are forced onto, and what device builds get unless
/// `MAP_VIEW=true` selects MapLibre. Routing the painter through the seam keeps
/// a single map call site in the screens, so switching renderers is a build
/// flag rather than a rewrite.
library;

import 'package:flutter/widgets.dart';

import '../../widgets/route_map.dart';
import 'map_surface.dart';

class PainterMapSurface implements MapSurface {
  const PainterMapSurface();

  @override
  Widget build(BuildContext context, MapScene scene) => RouteMap(
        geometry: scene.geometry,
        track: scene.track,
        you: scene.you,
        youProgress: scene.youProgress,
        ghost: scene.ghost,
        name: scene.name,
        courseColor: scene.courseColor,
        staticView: scene.staticView,
      );
}
