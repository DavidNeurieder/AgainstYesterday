// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Tiny route silhouette for library cards (§22).
///
/// A static polyline fitted to the box — cheaper and clearer than a map
/// thumbnail. Pure rendering, no interaction.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../engine/models.dart';

class RouteSilhouette extends StatelessWidget {
  const RouteSilhouette({
    super.key,
    required this.geometry,
    this.size = const Size(56, 44),
  });

  final List<GeoPoint> geometry;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _SilhouettePainter(geometry),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  _SilhouettePainter(this.geometry);

  final List<GeoPoint> geometry;

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.length < 2) {
      return;
    }

    final points = _fit(size);

    final paint = Paint()
      ..color = AppColors.pb.withValues(alpha: 0.75)
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  /// Projects geometry into [size] with a small inset (mirrors `_WorldFit`).
  List<Offset> _fit(Size size) {
    const padding = 4.0;
    var minLon = geometry.first.longitude;
    var maxLon = geometry.first.longitude;
    var minLat = geometry.first.latitude;
    var maxLat = geometry.first.latitude;
    for (final g in geometry) {
      minLon = math.min(minLon, g.longitude);
      maxLon = math.max(maxLon, g.longitude);
      minLat = math.min(minLat, g.latitude);
      maxLat = math.max(maxLat, g.latitude);
    }

    final latMid = (minLat + maxLat) / 2;
    final spanW = (maxLon - minLon) * math.cos(latMid * math.pi / 180);
    final spanH = maxLat - minLat;
    final avail = Size(
      math.max(size.width - 2 * padding, 1),
      math.max(size.height - 2 * padding, 1),
    );
    final sx = spanW > 0 ? avail.width / spanW : 0;
    final sy = spanH > 0 ? avail.height / spanH : 0;
    final scale = math.max(math.min(sx, sy), 1e-9).toDouble();
    final fitted = Size(spanW * scale, spanH * scale);
    final origin = Offset(
      (size.width - fitted.width) / 2,
      (size.height - fitted.height) / 2,
    );

    return [
      for (final g in geometry)
        origin +
            Offset(
              (g.longitude - minLon) * math.cos(latMid * math.pi / 180) * scale,
              (maxLat - g.latitude) * scale,
            ),
    ];
  }

  @override
  bool shouldRepaint(_SilhouettePainter old) => old.geometry != geometry;
}