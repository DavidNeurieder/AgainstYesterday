// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Per-route personal-best progression (M30): the chronological list of
/// attempts that set a new PB, with the time gained/lost against the previous
/// best.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';

class PbProgressionSection extends ConsumerStatefulWidget {
  const PbProgressionSection({
    super.key,
    required this.route,
    required this.attempts,
  });

  final Route route;
  final List<Activity> attempts;

  @override
  ConsumerState<PbProgressionSection> createState() => _PbProgressionSectionState();
}

class _PbProgressionSectionState extends ConsumerState<PbProgressionSection> {
  Future<List<RouteProgressionEvent>>? _future;
  String _key = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant PbProgressionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh();
  }

  void _refresh() {
    final ids = widget.attempts.map((a) => a.id).join(',');
    final key = '${widget.route.id}:${widget.route.personalBest?.seconds}:$ids';
    if (key == _key) return;
    _key = key;
    _future = ref.read(engineServiceProvider).computeRouteProgression(
          route: widget.route,
          attempts: widget.attempts,
        );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return FutureBuilder<List<RouteProgressionEvent>>(
      future: _future,
      builder: (context, snapshot) {
        final events = snapshot.data ?? const <RouteProgressionEvent>[];
        if (snapshot.connectionState != ConnectionState.done && events.isEmpty) {
          return Text(
            'Loading progression…',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          );
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
                        e.activity.duration?.format() ?? '—',
                        style: textTheme.bodyMedium,
                      ),
                    ),
                    if (e.previous != null && e.activity.duration != null)
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
      },
    );
  }
}