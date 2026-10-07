// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Developer diagnostics screen — M15 Phase 10 (§35 outline).
///
/// Deliberately utilitarian: a live readout of what the app knows right now,
/// so a developer standing outside with a phone can answer "why did the ghost
/// jump?" without guessing. The widget is a pure projection of
/// [diagnosticsSnapshotProvider]; it does not reach into repositories itself.
///
/// Exposed only through the dev-tools gate (`devToolsEnabledProvider`): both
/// the shell entry button and the route itself are gated.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../application/diagnostics_snapshot.dart';
import '../application/fixture_export.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(diagnosticsSnapshotProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _Section(
              title: 'ENGINE',
              rows: [
                _row('Implementation', snapshot.engineDescription),
                _row('Type', snapshot.engineType),
                _row('Run status', snapshot.runStatus),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _Section(
              title: 'GPS',
              rows: [
                _row('Source', snapshot.gpsSourceDescription),
                _row('Latitude', _coordinate(snapshot.latestFix?.latitude)),
                _row('Longitude', _coordinate(snapshot.latestFix?.longitude)),
                _row('Quality', snapshot.gpsQuality),
                _row('Pace', snapshot.paceDescription),
                _row(
                  'Started',
                  snapshot.startedAt?.toLocal().toIso8601String() ?? '—',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _Section(
              title: 'TRACK',
              rows: [
                _row('Elapsed', snapshot.elapsedDescription),
                _row('Distance', snapshot.distanceDescription),
                _row('Raw fixes', '${snapshot.rawFixCount}'),
                _row('Session points', '${snapshot.processedPointCount}'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _Section(
              title: 'ROUTE',
              rows: [
                _row('Name', snapshot.routeName ?? 'new route'),
                _row(
                  'Progress',
                  snapshot.routeName == null
                      ? '—'
                      : '${(snapshot.routeProgress * 100).toStringAsFixed(1)} %',
                ),
                _row('Geometry points', '${snapshot.routeGeometryPoints}'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _Section(title: 'GHOST', rows: _ghostRows(snapshot.ghostGap)),
            const SizedBox(height: AppSpacing.md),
            _Section(
              title: 'PERSISTENCE',
              rows: _persistenceRows(snapshot.recovery),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              key: const ValueKey('export-fixture'),
              onPressed: _copied ? null : _exportFixture,
              icon: const Icon(Icons.copy_rounded),
              label: Text(
                _copied ? 'Fixture JSON copied' : 'Export run as fixture JSON',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              fixturePrivacyWarning,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  String _coordinate(double? value) =>
      value == null ? '—' : value.toStringAsFixed(6);

  List<_Row> _ghostRows(GhostState? gap) {
    if (gap == null) {
      return [_row('Racing', 'no'), _row('Gap', '—')];
    }
    final direction = gap.ahead ? 'ahead' : 'behind';
    return [
      _row('Racing', 'yes'),
      _row('Gap', '${gap.timeDifference.format()} $direction'),
      _row('At distance', gap.distance.format()),
    ];
  }

  List<_Row> _persistenceRows(RunSnapshot? recovery) {
    if (recovery == null) {
      return [_row('Recovery snapshot', 'none')];
    }
    return [
      _row('Status', recovery.status.name),
      _row('Start', recovery.startedAt.toLocal().toIso8601String()),
      _row('Moving', Elapsed.seconds(recovery.movingSeconds).format()),
      _row('Distance', Distance.meters(recovery.distanceMeters).format()),
      _row('Loop', Distance.meters(recovery.loopMeters).format()),
      _row('Route id', recovery.routeId ?? '—'),
      _row('Recovery', 'available'),
    ];
  }

  _Row _row(String label, String value) => _Row(label, value);

  /// Exports the retained raw fixes (live session, else most recent persisted
  /// run) as a fixture and copies it to the clipboard.
  ///
  /// Refuses — with an explicit message — when there is nothing to export or
  /// when the recording has no route geometry; it never substitutes demo
  /// geometry. A privacy confirmation stands between the button and the
  /// clipboard.
  Future<void> _exportFixture() async {
    final messenger = ScaffoldMessenger.of(context);
    final data = ref.read(diagnosticsSnapshotProvider).exportData;
    if (data.fixes.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No track to export yet.')),
      );
      return;
    }
    if (data.route == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text(noRouteGeometryMessage)),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export raw GPS fixture?'),
        content: const Text(fixturePrivacyWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-export'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Copy fixture'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final json = buildFixtureJson(route: data.route!, fixes: data.fixes);
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    messenger.showSnackBar(
      const SnackBar(content: Text('Fixture JSON copied to clipboard.')),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<_Row> rows;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: textTheme.labelMedium?.copyWith(color: AppColors.pb),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final row in rows) ...[
              row,
              if (row != rows.last) const Divider(height: AppSpacing.lg),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 132,
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
