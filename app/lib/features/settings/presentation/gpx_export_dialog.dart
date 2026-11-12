// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The Settings → Export GPX chooser (§26): a window listing every exportable
/// route and run, so the user picks the tracks instead of always writing the
/// whole catalog into one file.
///
/// The list is built by `exportableTracks` and the chosen entries are written
/// by `buildGpxTracks`, so this dialog only owns the selection.
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_sections.dart';
import '../application/gpx_export.dart';

/// Shows the export chooser and returns the selected tracks in catalog order,
/// or `null` when the user cancels or dismisses the dialog.
Future<List<GpxExportTrack>?> showGpxExportDialog(
  BuildContext context, {
  required List<GpxExportTrack> tracks,
}) {
  return showDialog<List<GpxExportTrack>>(
    context: context,
    builder: (context) => GpxExportDialog(tracks: tracks),
  );
}

/// The chooser itself: every track starts selected, so confirming without
/// touching the list exports everything — but the user can narrow it down.
class GpxExportDialog extends StatefulWidget {
  const GpxExportDialog({super.key, required this.tracks});

  /// Every exportable track, in catalog order (routes first, then runs).
  final List<GpxExportTrack> tracks;

  @override
  State<GpxExportDialog> createState() => _GpxExportDialogState();
}

class _GpxExportDialogState extends State<GpxExportDialog> {
  late final Set<String> _selected = {
    for (final track in widget.tracks) track.id,
  };

  @override
  Widget build(BuildContext context) {
    final kinds = [
      for (final kind in GpxExportKind.values)
        if (widget.tracks.any((track) => track.kind == kind)) kind,
    ];
    return AlertDialog(
      key: const ValueKey('gpx-export-dialog'),
      title: const Text('Export GPX'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose the tracks to save to Downloads. '
              'They are written to one GPX file.',
            ),
            const SizedBox(height: AppSpacing.sm),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final kind in kinds) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.sm,
                        bottom: AppSpacing.xs,
                      ),
                      child: SectionHeader(title: kind.label),
                    ),
                    for (final track
                        in widget.tracks.where((track) => track.kind == kind))
                      CheckboxListTile(
                        key: ValueKey('gpx-export-${track.id}'),
                        value: _selected.contains(track.id),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: Text(track.name),
                        onChanged: (value) => setState(() {
                          if (value ?? false) {
                            _selected.add(track.id);
                          } else {
                            _selected.remove(track.id);
                          }
                        }),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('gpx-export-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('gpx-export-confirm'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop([
                    for (final track in widget.tracks)
                      if (_selected.contains(track.id)) track,
                  ]),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
