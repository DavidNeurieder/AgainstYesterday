// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route comparison (R6): side-by-side engine-backed statistics for two routes.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/settings_controller.dart';
import '../application/route_stats.dart';
import '../application/route_stats_provider.dart';

class RouteComparisonScreen extends ConsumerStatefulWidget {
  const RouteComparisonScreen({super.key});

  @override
  ConsumerState<RouteComparisonScreen> createState() =>
      _RouteComparisonScreenState();
}

class _RouteComparisonScreenState extends ConsumerState<RouteComparisonScreen> {
  String? _leftId;
  String? _rightId;

  @override
  Widget build(BuildContext context) {
    final routes = [
      for (final r in ref.watch(routeRepositoryProvider))
        if (!r.isExample) r,
    ];
    if (routes.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('Compare routes')),
        body: const Center(child: Text('Need at least two routes to compare.')),
      );
    }
    _leftId ??= routes[0].id;
    _rightId ??= routes.length > 1 ? routes[1].id : routes[0].id;
    final left = routes.firstWhere((r) => r.id == _leftId, orElse: () => routes[0]);
    final right = routes.firstWhere((r) => r.id == _rightId, orElse: () => routes[1]);
    final units = ref.watch(displayUnitProvider);
    final statsIndex = ref.watch(routeStatsIndexProvider);
    final leftStats = statsFor(statsIndex, left.id) ?? fallbackRouteStats(left);
    final rightStats = statsFor(statsIndex, right.id) ?? fallbackRouteStats(right);

    return Scaffold(
      appBar: AppBar(title: const Text('Compare routes')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              Expanded(child: _picker(routes, left.id, (v) => setState(() => _leftId = v))),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _picker(routes, right.id, (v) => setState(() => _rightId = v))),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _row('Distance', left.distance.formatWith(units), right.distance.formatWith(units)),
          _row('Runs', '${leftStats.runs}', '${rightStats.runs}'),
          _row('PB', leftStats.pb?.format() ?? '—', rightStats.pb?.format() ?? '—'),
          _row('Average', leftStats.average?.format() ?? '—', rightStats.average?.format() ?? '—'),
          _row('Median', leftStats.median?.format() ?? '—', rightStats.median?.format() ?? '—'),
          _row('Best pace', _pace(leftStats.bestPaceSecondsPerKm), _pace(rightStats.bestPaceSecondsPerKm)),
          _row('Avg pace', _pace(leftStats.averagePaceSecondsPerKm), _pace(rightStats.averagePaceSecondsPerKm)),
          _row('Total distance', _km(leftStats.totalDistanceMeters), _km(rightStats.totalDistanceMeters)),
          _row('Total time', leftStats.totalTimeSeconds > 0 ? Elapsed.seconds(leftStats.totalTimeSeconds).format() : '—',
              rightStats.totalTimeSeconds > 0 ? Elapsed.seconds(rightStats.totalTimeSeconds).format() : '—'),
          _row('Improvement', _delta(leftStats.improvementSeconds), _delta(rightStats.improvementSeconds)),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Comparison uses engine-backed route statistics (eligible attempts only). Pace/distance/time may be unavailable for routes without sufficient data.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _picker(List<Route> routes, String value, ValueChanged<String?> onChanged) {
    return DropdownButton<String>(
      value: value,
      isExpanded: true,
      items: [for (final r in routes) DropdownMenuItem(value: r.id, child: Text(r.name, overflow: TextOverflow.ellipsis))],
      onChanged: onChanged,
    );
  }

  Widget _row(String label, String a, String b) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(a, style: style)),
          Expanded(child: Text(label, textAlign: TextAlign.center, style: style?.copyWith(color: AppColors.textSecondary))),
          Expanded(child: Text(b, textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }

  String _pace(double? sPerKm) {
    if (sPerKm == null || sPerKm <= 0) return '—';
    final t = sPerKm.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')} /km';
  }

  String _km(double m) => m <= 0 ? '—' : '${(m / 1000).toStringAsFixed(2)} km';

  String _delta(double? s) {
    if (s == null) return '—';
    final sign = s >= 0 ? '-' : '+';
    return '$sign${Elapsed.seconds(s.abs()).format()}';
  }
}
