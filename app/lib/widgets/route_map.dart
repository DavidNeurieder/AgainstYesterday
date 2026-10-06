// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Minimal route map (§15, §16) — self-contained painter, no map SDK.
///
/// Renders only what a run needs: the route, the travelled portion, the YOU
/// marker and the PB ghost marker (§14). The camera follows YOU until the
/// user pans, when a `[Recenter]` button re-attaches it (§16).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../engine/models.dart';

/// Map padding inside the viewport, in logical pixels.
const double _kMapPadding = 22;

class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.geometry,
    required this.you,
    required this.youProgress,
    this.ghost,
    this.name,
    this.staticView = false,
  });

  final List<GeoPoint> geometry;

  /// Current live position (YOU).
  final GeoPoint you;

  /// Fraction of the route completed (0..1), for the travelled line.
  final double youProgress;

  /// PB ghost position (§14), when racing a ghost.
  final GeoPoint? ghost;

  /// Route name shown as a corner label.
  final String? name;

  /// Renders the whole route fitted to the viewport with no markers,
  /// no follow and no panning — the route-detail thumbnail (§23).
  final bool staticView;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  bool _follow = true;
  Offset _pan = Offset.zero;

  void _onPanStart() {
    setState(() => _follow = false);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _pan += details.delta);
  }

  void _recenter() {
    setState(() {
      _follow = true;
      _pan = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      final world = _WorldFit(geometry: widget.geometry, viewport: viewport);
      final follow = widget.staticView ? false : _follow;
      final shift = follow ? Offset.zero : _pan;

      if (widget.staticView) {
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: CustomPaint(
              painter: _MapPainter(
                world: world,
                shift: Offset.zero,
                follow: false,
                followAt: widget.you,
                geometry: widget.geometry,
                youProgress: widget.youProgress,
              ),
            ),
          ),
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _onPanStart(),
        onPanUpdate: _onPanUpdate,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // M14: isolate the map layer so live-tick repaints don't bleed
            // into siblings (and don't repaint on unrelated rebuilds).
            RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CustomPaint(
                  painter: _MapPainter(
                    world: world,
                    shift: shift,
                    follow: _follow,
                    followAt: widget.you,
                    geometry: widget.geometry,
                    youProgress: widget.youProgress,
                  ),
                ),
              ),
            ),
            if (widget.name case final name?)
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
            if (!_follow)
              Positioned(
                right: 10,
                top: 10,
                child: _MiniButton(
                  icon: Icons.my_location,
                  onPressed: _recenter,
                  tooltip: 'Recenter',
                ),
              ),
            _AnimatedMarker(
              key: const ValueKey('ghost-marker'),
              world: world,
              shift: shift,
              follow: _follow,
              followAt: widget.you,
              position: widget.ghost,
              child: Semantics(
                label: 'PB ghost position',
                child: ExcludeSemantics(child: _GhostDot()),
              ),
            ),
            _AnimatedMarker(
              key: const ValueKey('you-marker'),
              world: world,
              shift: shift,
              follow: _follow,
              followAt: widget.you,
              position: widget.you,
              child: Semantics(
                label: 'Your position',
                child: ExcludeSemantics(child: _YouDot()),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// Animated marker for a map feature; slides to its new spot in 400 ms (§14).
class _AnimatedMarker extends StatelessWidget {
  const _AnimatedMarker({
    super.key,
    required this.world,
    required this.shift,
    required this.follow,
    required this.followAt,
    required this.position,
    required this.child,
  });

  final _WorldFit world;
  final Offset shift;
  final bool follow;
  final GeoPoint followAt;
  final GeoPoint? position;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = position;
    if (p == null) {
      // Keep the slot mounted (never swap subtrees) to avoid a relayout under
      // an in-flight semantics update as markers slide between frames.
      return const Positioned(
        left: 0,
        top: 0,
        child: SizedBox(width: 1, height: 1),
      );
    }
    final px = world.project(
      p,
      shift: shift,
      follow: follow,
      followAt: followAt,
    );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      left: px.dx - 14,
      top: px.dy - 14,
      child: child,
    );
  }
}

class _GhostDot extends StatelessWidget {
  const _GhostDot();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: AppColors.ghost,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.background, width: 2),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'PB',
            style: TextStyle(color: AppColors.ghost, fontSize: 9, height: 1.3),
          ),
        ),
      ],
    );
  }
}

class _YouDot extends StatelessWidget {
  const _YouDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: AppColors.you,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.background, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 6),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 18, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Projects ([longitude], [latitude]) into the viewport so the route fits
/// with padding, north-up. Longitudes are corrected by cos(midLatitude) so
/// routes aren't stretched east–west.
class _WorldFit {
  _WorldFit({required this.geometry, required this.viewport}) {
    _computeRanges();
    _latMid = geometry.isEmpty ? 0 : (_minLat + _maxLat) / 2;
    _computeScaleAndOrigin();
  }

  final List<GeoPoint> geometry;
  final Size viewport;

  double _minLon = 0, _maxLon = 0;
  double _minLat = 0, _maxLat = 0;
  late double _latMid;
  double _scale = 1;
  Offset _origin = Offset.zero;

  void _computeRanges() {
    if (geometry.isEmpty) {
      return;
    }
    _minLon = _maxLon = geometry.first.longitude;
    _minLat = _maxLat = geometry.first.latitude;
    for (final g in geometry) {
      _minLon = math.min(_minLon, g.longitude);
      _maxLon = math.max(_maxLon, g.longitude);
      _minLat = math.min(_minLat, g.latitude);
      _maxLat = math.max(_maxLat, g.latitude);
    }
  }

  void _computeScaleAndOrigin() {
    final spanW = (_maxLon - _minLon) * math.cos(_latMid * math.pi / 180);
    final spanH = _maxLat - _minLat;
    final avail = Size(
      math.max(viewport.width - 2 * _kMapPadding, 1),
      math.max(viewport.height - 2 * _kMapPadding, 1),
    );
    final sx = spanW > 0 ? avail.width / spanW : 0;
    final sy = spanH > 0 ? avail.height / spanH : 0;
    _scale = math.max(math.min(sx, sy), 1e-9).toDouble();
    final fitted = Size(spanW * _scale, spanH * _scale);
    _origin = Offset(
      (viewport.width - fitted.width) / 2,
      (viewport.height - fitted.height) / 2,
    );
  }

  /// [p] in "degree-correction" world space → viewport pixels.
  Offset project(
    GeoPoint p, {
    required Offset shift,
    required bool follow,
    required GeoPoint followAt,
  }) {
    var px = _raw(p) + shift;
    if (follow) {
      final here = _raw(followAt);
      px += Offset(viewport.width / 2 - here.dx, viewport.height / 2 - here.dy);
    }
    return px;
  }

  Offset _raw(GeoPoint p) {
    final x = (p.longitude - _minLon) * math.cos(_latMid * math.pi / 180);
    final y = _maxLat - p.latitude;
    return _origin + Offset(x * _scale, y * _scale);
  }
}

/// Paints the route (faint full trace) and the travelled portion (§15).
class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.world,
    required this.shift,
    required this.follow,
    required this.followAt,
    required this.geometry,
    required this.youProgress,
  });

  final _WorldFit world;
  final Offset shift;
  final bool follow;
  final GeoPoint followAt;
  final List<GeoPoint> geometry;
  final double youProgress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.surface,
    );

    if (geometry.isEmpty) {
      return;
    }

    final full = <Offset>[
      for (final g in geometry)
        world.project(g, shift: shift, follow: follow, followAt: followAt),
    ];

    final trace = Paint()
      ..color = AppColors.ghost.withValues(alpha: 0.35)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(_path(full), trace);

    final traveled = _traveledPath(full, youProgress.clamp(0.0, 1.0));
    if (traveled.length >= 2) {
      final youLine = Paint()
        ..color = AppColors.you
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(_path(traveled), youLine);
    }
  }

  Path _path(List<Offset> points) {
    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  /// Cuts the polyline at [fraction] of its arc length.
  List<Offset> _traveledPath(List<Offset> points, double fraction) {
    if (points.isEmpty) {
      return const [];
    }
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += (points[i] - points[i - 1]).distance;
    }
    if (total <= 0) {
      return const [];
    }
    final result = <Offset>[points.first];
    final target = total * fraction;
    var acc = 0.0;
    for (var i = 1; i < points.length; i++) {
      final seg = (points[i] - points[i - 1]).distance;
      if (acc + seg >= target) {
        final t = seg <= 0 ? 0.0 : (target - acc) / seg;
        final cut = Offset.lerp(points[i - 1], points[i], t)!;
        result.add(cut);
        return result;
      }
      acc += seg;
      result.add(points[i]);
    }
    return result;
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.geometry != geometry ||
      old.youProgress != youProgress ||
      old.shift != shift ||
      old.follow != follow ||
      old.followAt != followAt;
}