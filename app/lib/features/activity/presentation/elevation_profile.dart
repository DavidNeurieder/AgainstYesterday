// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../engine/models.dart';

/// A simple elevation profile drawn from a track's altitude samples.
class ElevationProfile extends StatelessWidget {
  const ElevationProfile({super.key, required this.track});

  final List<TrackPoint> track;

  @override
  Widget build(BuildContext context) {
    final altitudes = <double>[];
    for (final p in track) {
      final a = p.altitudeMeters;
      if (a != null) altitudes.add(a);
    }
    if (altitudes.length < 2) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _ElevationPainter(altitudes),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ElevationPainter extends CustomPainter {
  _ElevationPainter(this.altitudes);

  final List<double> altitudes;

  @override
  void paint(Canvas canvas, Size size) {
    final minA = altitudes.reduce((a, b) => a < b ? a : b);
    final maxA = altitudes.reduce((a, b) => a > b ? a : b);
    final range = (maxA - minA).abs() < 1e-9 ? 1.0 : (maxA - minA);
    final path = Path();
    for (var i = 0; i < altitudes.length; i++) {
      final x = size.width * i / (altitudes.length - 1);
      final y = size.height - (altitudes[i] - minA) / range * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final paint = Paint()
      ..color = const Color(0xFF4CAF50)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ElevationPainter oldDelegate) =>
      oldDelegate.altitudes != altitudes;
}