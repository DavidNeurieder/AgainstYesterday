// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Per-route personal-best progression (M30): the chronological list of
/// attempts that set a new PB, with the time gained/lost against the previous
/// best.
library;

import 'package:flutter/material.dart' hide Route;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';

class PbProgressionSection extends StatelessWidget {
  const PbProgressionSection({
    super.key,
    required this.route,
    required this.attempts,
  });

  final Route route;
  final List<Activity> attempts;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final timed = [
      for (final a in attempts) if (a.duration != null) a,
    ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    final events = <({Activity activity, Elapsed? previous})>[];
    Elapsed? best;
    for (final a in timed) {
      if (best == null || a.duration!.seconds < best.seconds) {
        events.add((activity: a, previous: best));
        best = a.duration;
      }
    }

    if (events.isEmpty) {
      return Text(
        'No personal bests yet.',
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('PB progression', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final e in events)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.emoji_events, size: 16, color: AppColors.pb),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    e.activity.duration!.format(),
                    style: textTheme.bodyMedium,
                  ),
                ),
                if (e.previous != null)
                  Text(
                    '-${Elapsed.seconds(e.previous!.seconds - e.activity.duration!.seconds).format()}',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.ahead,
                    ),
                  )
                else
                  Text(
                    'First',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${e.activity.startedAt.toLocal().day}/${e.activity.startedAt.toLocal().month}/${e.activity.startedAt.toLocal().year}',
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}