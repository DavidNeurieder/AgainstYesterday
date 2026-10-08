// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Deliberate entrance motion (§30): a fade with a small rise, staggered by
/// [delay] so a screen's stats can arrive in sequence without animating
/// everything.
///
/// One-shot by construction — the tween ends at 1 and never repeats — so
/// `pumpAndSettle` stays finite in tests, and the whole reveal collapses to
/// an instant render when the platform reports disabled animations (§32).
library;

import 'package:flutter/material.dart';

class StaggeredIn extends StatelessWidget {
  const StaggeredIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 260),
    this.slide = 12,
  });

  /// What fades in.
  final Widget child;

  /// How long after the first frame the reveal begins.
  final Duration delay;

  /// The reveal itself, after [delay].
  final Duration duration;

  /// Rise distance in logical pixels (starts [slide] below, lands at 0).
  final double slide;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final total = delay + duration;
    final start =
        total == Duration.zero ? 0.0 : delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, slide * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
