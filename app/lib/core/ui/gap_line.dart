// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The one-line "how did the run compare to the PB" readout shared by the
/// run-complete and result screens (§20–§21).
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../../engine/models.dart';
import '../units.dart';

class GapLine extends StatelessWidget {
  const GapLine({super.key, required this.gap});

  final GhostState? gap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final gap = this.gap;
    if (gap == null) {
      return Text(
        'First time on this route',
        textAlign: TextAlign.center,
        style: textTheme.bodyMedium,
      );
    }
    final delta = gap.timeDifference.seconds.abs();
    final offset = Elapsed.seconds(delta).format();
    final ahead = gap.ahead;
    final color = ahead ? AppColors.ahead : AppColors.behind;
    final wording = ahead ? 'ahead of PB' : 'behind PB';
    return Text(
      delta == 0 ? 'Tied with PB' : '$offset $wording',
      textAlign: TextAlign.center,
      style: textTheme.titleLarge?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}