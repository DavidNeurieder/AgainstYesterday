// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Gap-to-PB performance graph (§23, M26) — the result screen's curve of
/// seconds ahead of / behind the personal best over the covered distance.
///
/// The line turns green above the zero rule and amber below it, but the
/// AHEAD/BEHIND gutter words and the semantics label carry the same
/// meaning as text (§32).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../application/gap_curve.dart';

class GapChart extends StatelessWidget {
  const GapChart({super.key, required this.curve, required this.units});

  /// Samples from [computeGapCurve]; at least two points.
  final List<GapPoint> curve;

  final Units units;

  String get _summary {
    if (curve.length < 2) {
      return 'Gap to your best: no data.';
    }
    final last = curve.last;
    final secs = last.aheadSeconds.abs().roundToDouble();
    if (secs == 0) {
      return 'Gap to your best: even with your best at the finish.';
    }
    final dir = last.aheadSeconds > 0 ? 'ahead' : 'behind';
    return 'Gap to your best: $dir ${Elapsed.seconds(secs).format()} at the '
        'finish.';
  }

  @override
  Widget build(BuildContext context) {
    if (curve.length < 2) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'GAP TO YOUR BEST',
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          label: _summary,
          child: SizedBox(
            height: 184,
            child: CustomPaint(
              painter: _GapPainter(
                curve: curve,
                units: units,
                tickStyle: (textTheme.labelSmall ?? const TextStyle())
                    .copyWith(color: AppColors.textMuted),
                wordStyle: (textTheme.labelSmall ?? const TextStyle())
                    .copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GapPainter extends CustomPainter {
  _GapPainter({
    required this.curve,
    required this.units,
    required this.tickStyle,
    required this.wordStyle,
  });

  final List<GapPoint> curve;
  final Units units;
  final TextStyle tickStyle;
  final TextStyle wordStyle;

  static const double _gutter = 52;
  static const double _padRight = 12;
  static const double _padTop = 22;
  static const double _padBottom = 40;

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.length < 2) {
      return;
    }
    final plotLeft = _gutter;
    final plotW = size.width - _gutter - _padRight;
    final plotTop = _padTop;
    final plotH = size.height - _padTop - _padBottom;
    if (plotW <= 8 || plotH <= 8) {
      return;
    }

    var maxAbs = 0.0;
    for (final p in curve) {
      maxAbs = math.max(maxAbs, p.aheadSeconds.abs());
    }
    // Round the y range out to whole tens of seconds (at least ±10 s).
    final yMax = math.max(10.0, (maxAbs / 10).ceil() * 10.0);
    final span = curve.last.distanceMeters;
    double xOf(double d) => plotLeft + (span <= 0 ? 0.0 : d / span) * plotW;
    double yOf(double v) => plotTop + plotH / 2 * (1 - v / yMax);
    final zeroY = yOf(0);

    // The zero rule, dashed so it reads as the axis rather than the data.
    final zero = Paint()
      ..color = AppColors.outline
      ..strokeWidth = 1;
    var dx = plotLeft;
    while (dx < plotLeft + plotW) {
      final end = math.min(dx + 4, plotLeft + plotW);
      canvas.drawLine(Offset(dx, zeroY), Offset(end, zeroY), zero);
      dx += 8;
    }

    // The curve: green above the rule, amber below.
    final line = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < curve.length; i++) {
      final a = curve[i - 1];
      final b = curve[i];
      line.color = (a.aheadSeconds + b.aheadSeconds) / 2 >= 0
          ? AppColors.ahead
          : AppColors.behind;
      canvas.drawLine(
        Offset(xOf(a.distanceMeters), yOf(a.aheadSeconds)),
        Offset(xOf(b.distanceMeters), yOf(b.aheadSeconds)),
        line,
      );
    }

    // Gutter: direction words at the ends, three y ticks in between.
    _text(
      canvas,
      size,
      'AHEAD',
      wordStyle.copyWith(color: AppColors.ahead),
      left: 0,
      top: 2,
      maxWidth: _gutter - 6,
      align: TextAlign.right,
    );
    _text(
      canvas,
      size,
      'BEHIND',
      wordStyle.copyWith(color: AppColors.behind),
      left: 0,
      top: plotTop + plotH + 8,
      maxWidth: _gutter - 6,
      align: TextAlign.right,
    );
    for (final v in [yMax, 0.0, -yMax]) {
      final label = v > 0 ? '+${v.toInt()}s' : v < 0 ? '-${v.toInt()}s' : '0';
      _text(
        canvas,
        size,
        label,
        tickStyle,
        left: 0,
        top: yOf(v) - 7,
        maxWidth: _gutter - 6,
        align: TextAlign.right,
      );
    }

    // x-axis: unit ticks along the bottom, unit word on the last label.
    final step = units == Units.kilometers ? 1000.0 : 1609.3444;
    final unit = units == Units.kilometers ? 'km' : 'mi';
    final labelTop = plotTop + plotH + 8;
    final lastK = (span / step).floor();
    _text(canvas, size, '0', tickStyle, left: xOf(0), top: labelTop,
        center: true);
    if (lastK == 0) {
      // Not even a whole unit: label the end with a fraction instead.
      final frac = (span / step).toStringAsFixed(1);
      _text(canvas, size, '$frac $unit', tickStyle, left: xOf(span),
          top: labelTop, center: true);
    } else {
      for (var k = 1; k <= lastK; k++) {
        _text(
          canvas,
          size,
          k == lastK ? '$k $unit' : '$k',
          tickStyle,
          left: xOf(k * step),
          top: labelTop,
          center: true,
        );
      }
    }
  }

  void _text(
    Canvas canvas,
    Size size,
    String text,
    TextStyle style, {
    required double left,
    required double top,
    double? maxWidth,
    TextAlign align = TextAlign.left,
    bool center = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    var x = center ? left - tp.width / 2 : left;
    if (x < 0) {
      x = 0;
    }
    if (x + tp.width > size.width) {
      x = math.max(0, size.width - tp.width);
    }
    tp.paint(canvas, Offset(x, top));
  }

  @override
  bool shouldRepaint(_GapPainter oldDelegate) =>
      oldDelegate.curve != curve || oldDelegate.units != units;
}
