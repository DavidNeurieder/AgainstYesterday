// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Section and metric building blocks (§27): one section heading and label /
/// value rows so screens stop re-implementing them.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'app_typography.dart';

/// Muted section heading above a group of cards or metrics.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(color: AppColors.textSecondary),
    );
  }
}

/// Label left / value right, values in tabular figures.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: textTheme.bodyMedium),
          Text(
            value,
            style: tabular(
              textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) ??
                  const TextStyle(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase metric label stacked over its value.
class MetricDisplay extends StatelessWidget {
  const MetricDisplay({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style:
              textTheme.labelSmall?.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: tabular(
            textTheme.titleMedium?.copyWith(color: AppColors.textPrimary) ??
                const TextStyle(),
          ),
        ),
      ],
    );
  }
}