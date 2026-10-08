// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings (M21, §26) — deliberately boring.
///
/// Groups follow the plan: Race (haptics, countdown), Display (units), Data
/// (export / delete all), About. The app is a dark-only design with a single
/// activity type, so there is no theme or default-activity control yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../core/ui/app_sections.dart';
import '../../../persistence/persistence.dart';
import '../application/gpx_export.dart';
import '../application/settings_controller.dart';

/// Shown in About and kept in step with `pubspec.yaml`.
const String kAppVersion = '1.0.0';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsRepositoryProvider);
    final notifier = ref.read(settingsRepositoryProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const SectionHeader(title: 'Race'),
          const SizedBox(height: AppSpacing.sm),
          _Card(
            children: [
              SwitchListTile(
                key: const ValueKey('haptics-switch'),
                title: const Text('Haptics'),
                subtitle: const Text('Vibrate on buttons and milestones'),
                value: settings.hapticsEnabled,
                onChanged: (value) => notifier.save(
                  settings.copyWith(hapticsEnabled: value),
                ),
              ),
              const Divider(height: 1, color: AppColors.outline),
              SwitchListTile(
                key: const ValueKey('countdown-switch'),
                title: const Text('Countdown'),
                subtitle: const Text('3-2-1-GO before a race starts'),
                value: settings.countdownEnabled,
                onChanged: (value) => notifier.save(
                  settings.copyWith(countdownEnabled: value),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Display'),
          const SizedBox(height: AppSpacing.sm),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                // §31: wraps the control onto its own line on narrow phones
                // instead of overflowing (the segment labels are wide).
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Units'),
                    SegmentedButton<Units>(
                      key: const ValueKey('units-segment'),
                      segments: [
                        for (final units in Units.values)
                          ButtonSegment(
                            value: units,
                            label: Text(units.label),
                          ),
                      ],
                      selected: {settings.units},
                      onSelectionChanged: (selection) =>
                          notifier.save(settings.copyWith(units: selection.first)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Data'),
          const SizedBox(height: AppSpacing.sm),
          _Card(
            children: [
              ListTile(
                key: const ValueKey('export-gpx'),
                leading: const Icon(Icons.ios_share_outlined),
                title: const Text('Export GPX'),
                subtitle: const Text('Copy routes and runs as GPX'),
                onTap: () => _exportGpx(context, ref),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                key: const ValueKey('delete-all'),
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete all data'),
                subtitle: const Text('Routes, history and settings'),
                onTap: () => _confirmDeleteAll(context, ref),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'About'),
          const SizedBox(height: AppSpacing.sm),
          _Card(
            children: [
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Version'),
                trailing: Text(kAppVersion),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacy'),
                onTap: () => _showPrivacy(context),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Open source licenses'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Against Yesterday',
                  applicationVersion: kAppVersion,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _exportGpx(BuildContext context, WidgetRef ref) async {
    final routes = ref.read(routeRepositoryProvider);
    final activities = ref.read(activityRepositoryProvider);
    final gpx = buildGpx(routes, activities);
    final messenger = ScaffoldMessenger.of(context);
    if (gpx == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Nothing to export yet.')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: gpx));
    final tracks = routes.length +
        activities.where((a) => a.track?.isNotEmpty ?? false).length;
    messenger.showSnackBar(
      SnackBar(content: Text('Copied $tracks tracks as GPX.')),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all data?'),
        content: const Text(
          'This permanently removes every route, every recorded run, and '
          'resets your settings. There is no undo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-all'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.errorFill,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _deleteAllData(ref);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All data deleted.')),
      );
    }
  }

  Future<void> _deleteAllData(WidgetRef ref) async {
    final store = ref.read(persistenceStoreProvider);
    for (final key in ['routes', 'activities', 'run_snapshot', 'settings']) {
      try {
        store.remove(key);
      } catch (_) {
        // Degraded storage: the in-memory clears below still apply.
      }
    }
    ref.read(routeRepositoryProvider.notifier).clear();
    ref.read(activityRepositoryProvider.notifier).clear();
    await ref.read(runSnapshotProvider.notifier).save(null);
    await ref.read(settingsRepositoryProvider.notifier).resetToDefaults();
  }

  void _showPrivacy(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Privacy'),
        content: const Text(
          'Against Yesterday works offline. Routes, runs and settings stay on '
          'this device — there are no accounts, no analytics and nothing leaves '
          'the phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// A rounded card holding a vertical list of settings rows.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}