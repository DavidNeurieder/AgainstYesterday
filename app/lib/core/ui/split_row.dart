// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Per-kilometre split delta row, shared by the result and activity screens.
library;

import 'package:flutter/material.dart';

import '../../features/result/application/splits.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../units.dart';

class SplitRow extends StatelessWidget {
  const SplitRow({super.key, required this.split});

  final SplitDelta split;

  @override
  Widget build(BuildContext context) {
    final ahead = split.deltaSeconds <= 0;
    final color = ahead ? AppColors.ahead : AppColors.behind;
    final sign = ahead ? '-' : '+';
    final delta = Elapsed.seconds(split.deltaSeconds.abs()).format();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              '${split.kilometer} km',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            sign + delta,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ],
      ),
    );
  }
}