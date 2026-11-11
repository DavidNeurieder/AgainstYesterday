// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings (M21, §26) — deliberately boring.
///
/// Groups follow the plan: Race (haptics, countdown), Display (units), Data
/// (export / delete all), About. The app is a dark-only design with a single
/// activity type, so there is no theme or default-activity control yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../../app/app_info.dart';
import '../../../app/dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../core/ui/app_sections.dart';
import '../../../engine/models.dart' as engine;
import '../../../persistence/persistence.dart';
import '../../map/map_settings_section.dart';
import '../../routes/application/example_routes.dart';
import '../application/gpx_export.dart';
import '../application/gpx_import.dart';
import '../application/link_launcher.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import '../application/track_export.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsRepositoryProvider);
    final notifier = ref.read(settingsRepositoryProvider.notifier);
    // The installed artifact's own version (§26), not a hand-kept constant.
    final appVersion = ref.watch(appVersionProvider).value ?? '';
    final hasExamples = ref.watch(hasExampleRoutesProvider);

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
                onChanged: (value) =>
                    notifier.save(settings.copyWith(hapticsEnabled: value)),
              ),
              const Divider(height: 1, color: AppColors.outline),
              SwitchListTile(
                key: const ValueKey('countdown-switch'),
                title: const Text('Countdown'),
                subtitle: const Text('3-2-1-GO before a race starts'),
                value: settings.countdownEnabled,
                onChanged: (value) =>
                    notifier.save(settings.copyWith(countdownEnabled: value)),
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
                    const Text('Theme'),
                    SegmentedButton<AppThemeMode>(
                      segments: [
                        for (final mode in AppThemeMode.values)
                          ButtonSegment(value: mode, label: Text(mode.label)),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (selection) => notifier.save(
                        settings.copyWith(themeMode: selection.first),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.outline),
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
                          ButtonSegment(value: units, label: Text(units.label)),
                      ],
                      selected: {settings.units},
                      onSelectionChanged: (selection) => notifier.save(
                        settings.copyWith(units: selection.first),
                      ),
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
                subtitle: const Text('Save routes and runs to Downloads'),
                onTap: () => _exportGpx(context, ref),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                key: const ValueKey('import-gpx'),
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('Import GPX'),
                subtitle: const Text('Create routes from GPX tracks'),
                onTap: () => _importGpx(context, ref),
              ),
              const Divider(height: 1, color: AppColors.outline),
              if (hasExamples)
                ListTile(
                  key: const ValueKey('remove-examples'),
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove example routes'),
                  subtitle: const Text('Delete the bundled demo routes'),
                  onTap: () async {
                    await removeExampleRoutes(ref.container);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Example routes removed.'),
                          duration: Duration(milliseconds: 600),
                        ),
                      );
                    }
                  },
                )
              else
                ListTile(
                  key: const ValueKey('restore-examples'),
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('Restore example routes'),
                  subtitle: const Text('Re-add the bundled demo routes'),
                  onTap: () async {
                    await installExampleRoutes(ref.container);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Example routes restored.'),
                          duration: Duration(milliseconds: 600),
                        ),
                      );
                    }
                  },
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
          const MapSettingsSection(),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'About'),
          const SizedBox(height: AppSpacing.sm),
          _Card(
            children: [
              ListTile(
                key: const ValueKey('app-version'),
                leading: const Icon(Icons.info_outline),
                title: const Text('Version'),
                trailing: Text(appVersion),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                key: const ValueKey('github-link'),
                leading: const Icon(Icons.code),
                title: const Text('GitHub'),
                subtitle: const Text('Source code and releases'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _openLink(context, ref, kGitHubUrl, 'GitHub'),
              ),
              const Divider(height: 1, color: AppColors.outline),
              ListTile(
                key: const ValueKey('issues-link'),
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('Report an issue'),
                subtitle: const Text('Bugs and feature requests'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () =>
                    _openLink(context, ref, kIssuesUrl, 'the issue tracker'),
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
                  applicationVersion: appVersion,
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
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing to export yet.')),
      );
      return;
    }
    final fileName = gpxFileName(DateTime.now());
    try {
      await ref
          .read(trackExporterProvider)
          .saveToDownloads(fileName: fileName, contents: gpx);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved $fileName to Downloads.')),
      );
    } on TrackExportException catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: ${error.message}')),
      );
    }
  }

  Future<void> _importGpx(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['gpx'],
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    if (!context.mounted) return;
    // Let the user confirm which of the picked files to import.
    final selected = List<bool>.filled(result.files.length, true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Import GPX files'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: result.files.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  value: selected[i],
                  title: Text(result.files[i].name),
                  onChanged: (v) =>
                      setDialogState(() => selected[i] = v ?? false),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) {
      return;
    }
    final filesToImport = [
      for (var i = 0; i < result.files.length; i++)
        if (selected[i]) result.files[i],
    ];
    if (filesToImport.isEmpty) {
      return;
    }
    final routeRepo = ref.read(routeRepositoryProvider.notifier);
    final activityRepo = ref.read(activityRepositoryProvider.notifier);
    final engineService = ref.read(engineServiceProvider);
    // Start from the existing catalog so imported tracks group onto routes
    // that are already saved, not just onto each other.
    final accepted = [...ref.read(routeRepositoryProvider)];
    var importedTracks = 0;
    var newRoutes = 0;
    var grouped = 0;
    var counter = 0;
    for (final file in filesToImport) {
      String? contents;
      if (file.bytes != null) {
        contents = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        try {
          contents = await File(file.path!).readAsString();
        } catch (_) {
          contents = null;
        }
      }
      if (contents == null) continue;
      final details = parseGpxTrackDetails(contents);
      final geometry = details.points;
      if (geometry.length < 2) continue;
      importedTracks++;
      final name = (file.name.isNotEmpty ? file.name : 'Imported track')
          .replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');
      final timestamps = details.timestamps;
      final startedAt =
          timestamps.whereType<DateTime>().cast<DateTime?>().firstWhere(
            (t) => t != null,
            orElse: () => null,
          ) ??
          DateTime.now().toUtc();
      final validTimes = timestamps.whereType<DateTime>().toList();
      final duration = validTimes.length >= 2
          ? validTimes.last.difference(validTimes.first)
          : null;
      final elapsed = duration == null || duration.inMilliseconds <= 0
          ? null
          : Elapsed.seconds(duration.inMilliseconds / 1000.0);
      final trackPoints = [
        for (var i = 0; i < geometry.length; i++)
          engine.TrackPoint(
            position: geometry[i],
            timestamp: timestamps[i] ?? startedAt,
          ),
      ];
      final info = await engineService.routeInfo(points: trackPoints);
      final distance = Distance.meters(info.lengthMeters);
      // Try to find an existing (or already-imported) route that is the same
      // course, so repeated recordings collapse onto one route instead of
      // spawning duplicates.
      String? matchedId;
      final importedTrack = geometryToTrack(geometry);
      for (final route in accepted) {
        final match = await engineService.matchRoutes(
          a: importedTrack,
          b: geometryToTrack(route.geometry),
        );
        if (match.sameRoute) {
          matchedId = route.id;
          break;
        }
      }
      if (matchedId != null) {
        final index = accepted.indexWhere((r) => r.id == matchedId);
        final route = accepted[index];
        accepted[index] = engine.Route(
          id: route.id,
          name: route.name,
          distance: route.distance,
          geometry: route.geometry,
          attemptCount: route.attemptCount + 1,
          personalBest: _bestElapsed(route.personalBest, elapsed),
        );
        await routeRepo.saveRoute(accepted[index]);
        await activityRepo.saveActivity(
          engine.Activity(
            id: 'act-imported-${DateTime.now().microsecondsSinceEpoch}-$counter',
            routeId: route.id,
            startedAt: startedAt,
            duration: elapsed,
            distance: distance,
            performance: elapsed?.format(),
            track: trackPoints,
          ),
        );
        grouped++;
      } else {
        final id = 'imported-${DateTime.now().microsecondsSinceEpoch}-$counter';
        counter++;
        final route = engine.Route(
          id: id,
          name: name,
          distance: distance,
          geometry: geometry,
          attemptCount: 1,
          personalBest: elapsed,
        );
        accepted.add(route);
        await routeRepo.saveRoute(route);
        await activityRepo.saveActivity(
          engine.Activity(
            id: 'act-imported-${DateTime.now().microsecondsSinceEpoch}-$counter',
            routeId: route.id,
            startedAt: startedAt,
            duration: elapsed,
            distance: distance,
            performance: elapsed?.format(),
            track: trackPoints,
          ),
        );
        newRoutes++;
      }
    }
    if (importedTracks == 0) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No usable tracks found in the selected files.'),
        ),
      );
      return;
    }
    final summary = grouped == 0
        ? 'Imported $importedTracks track${importedTracks == 1 ? '' : 's'} '
              'into $newRoutes new route${newRoutes == 1 ? '' : 's'}.'
        : 'Imported $importedTracks track${importedTracks == 1 ? '' : 's'}: '
              '$newRoutes new route${newRoutes == 1 ? '' : 's'}, '
              '$grouped grouped onto existing routes.';
    messenger.showSnackBar(SnackBar(content: Text(summary)));
  }

  Elapsed? _bestElapsed(Elapsed? a, Elapsed? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.seconds <= b.seconds ? a : b;
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.errorFill),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('All data deleted.')));
    }
  }

  Future<void> _deleteAllData(WidgetRef ref) async {
    final store = ref.read(persistenceStoreProvider);
    for (final key in [
      'routes',
      'activities',
      'run_snapshot',
      'settings',
      'offline_regions',
    ]) {
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

  /// Hands a link to the platform's browser; the About card's GitHub and
  /// issue rows are the only outward-facing actions Settings has.
  Future<void> _openLink(
    BuildContext context,
    WidgetRef ref,
    String url,
    String label,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await ref.read(linkLauncherProvider).open(Uri.parse(url));
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $label.')));
    }
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
