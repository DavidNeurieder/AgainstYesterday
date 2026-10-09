// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings → Map: offline regions and map attribution.
///
/// Lists every downloaded region with a progress bar while it downloads and a
/// delete affordance (with confirmation) once it exists. The disclosure next
/// to the list states the personal-use limits, and the attribution line keeps
/// the OSM/ODbL obligation visible outside the map itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sections.dart';
import 'offline_region_repository.dart';
import 'offline_regions.dart';

class MapSettingsSection extends ConsumerWidget {
  const MapSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regions = ref.watch(offlineRegionRepositoryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Map'),
        const SizedBox(height: AppSpacing.sm),
        Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Text(
                  'Offline regions let you browse a route without a connection. '
                  'Each download covers one route, is capped in size and is for '
                  'personal use subject to the tile provider terms.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              if (regions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Text(
                    'No offline regions downloaded yet. Open any route and '
                    'choose Download offline map.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                )
              else
                for (final region in regions) _RegionRow(region: region),
              const Divider(height: 1, color: AppColors.outline),
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Text(
                  'Map data © OpenStreetMap contributors (ODbL) · '
                  'Tiles © OpenFreeMap / OpenMapTiles',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RegionRow extends ConsumerWidget {
  const _RegionRow({required this.region});

  final OfflineRegion region;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final subtitle = switch (region.status) {
      OfflineRegionStatus.downloading =>
        'Downloading ${(region.progress * 100).round()}% · zoom ${region.zoom}',
      OfflineRegionStatus.ready => 'Ready · zoom ${region.zoom}',
      OfflineRegionStatus.failed =>
        region.errorText ?? 'Download failed',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.map_outlined),
          title: Text(region.name),
          subtitle: Text(subtitle, style: textTheme.bodySmall),
          trailing: IconButton(
            key: ValueKey('delete-offline-${region.routeId}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete offline region',
            onPressed: () =>
                _confirmDelete(context, ref, region.routeId, region.name),
          ),
        ),
        if (region.status == OfflineRegionStatus.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: LinearProgressIndicator(
              key: ValueKey('offline-progress-${region.routeId}'),
              value: region.progress,
              color: AppColors.you,
              backgroundColor: AppColors.outline,
              minHeight: 4,
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String routeId,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this region?'),
        content: Text(
          '$name will stop working offline and its tiles will be removed '
          'from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-offline'),
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
    await ref
        .read(offlineRegionRepositoryProvider.notifier)
        .deleteRegion(routeId);
  }
}