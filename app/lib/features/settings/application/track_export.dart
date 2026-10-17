// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where the GPX exports put their file (Settings → Export GPX, M21 §26;
/// History's per-run export, §33).
///
/// The GPX document itself is built by `gpx_export.dart`; this layer only
/// owns *where it lands*. On Android the public Downloads folder is written
/// through a `MediaStore` platform channel (`MainActivity`), so no storage
/// permission is needed on API 29+ and only the legacy `WRITE_EXTERNAL_STORAGE`
/// grant is requested below that. Elsewhere — desktop dev runs and the
/// hermetic test suites — the platform's Download directory from
/// `path_provider` stands in, or the exporter is replaced with a fake.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../engine/models.dart';

/// The channel `MainActivity` registers to write files into Downloads.
const MethodChannel trackFilesChannel =
    MethodChannel('dev.neurieder.against_yesterday/files');

/// A failed export, carrying a message safe to show the user.
class TrackExportException implements Exception {
  const TrackExportException(this.message);

  /// What went wrong, phrased for a snackbar.
  final String message;

  @override
  String toString() => 'TrackExportException: $message';
}

/// Saves a text track document somewhere the user can find it again.
abstract interface class TrackExporter {
  /// Writes [contents] as [fileName] into the platform's Downloads location
  /// and returns a human-readable location on success. Throws
  /// [TrackExportException] when the write (or a needed permission) fails.
  Future<String> saveToDownloads({
    required String fileName,
    required String contents,
  });
}

/// The real exporter: a `MediaStore` write on Android, `path_provider`
/// elsewhere.
class PlatformTrackExporter implements TrackExporter {
  const PlatformTrackExporter();

  @override
  Future<String> saveToDownloads({
    required String fileName,
    required String contents,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _saveOnAndroid(fileName, contents);
    }
    return _saveElsewhere(fileName, contents);
  }

  Future<String> _saveOnAndroid(String fileName, String contents) async {
    try {
      final location = await trackFilesChannel.invokeMethod<String>(
        'saveToDownloads',
        <String, Object?>{'name': fileName, 'contents': contents},
      );
      if (location == null || location.isEmpty) {
        throw const TrackExportException('Downloads is not writable.');
      }
      return location;
    } on PlatformException catch (error) {
      throw TrackExportException(error.message ?? 'Downloads is not writable.');
    } on MissingPluginException {
      throw const TrackExportException('This build cannot write to Downloads.');
    }
  }

  Future<String> _saveElsewhere(String fileName, String contents) async {
    Directory? directory;
    try {
      directory = await getDownloadsDirectory();
    } on MissingPluginException {
      directory = null;
    } on UnsupportedError {
      directory = null;
    }
    directory ??= await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$fileName');
    await file.writeAsString(contents);
    return file.path;
  }
}

/// The exporter the app uses; tests override it with a recording fake.
final trackExporterProvider = Provider<TrackExporter>(
  (_) => const PlatformTrackExporter(),
);

/// A collision-free GPX name derived from [now], so repeated exports never
/// clobber each other: `against-yesterday-2026-10-09-141530.gpx`.
String gpxFileName(DateTime now) =>
    'against-yesterday-${_stamp(now)}.gpx';

/// The file name for a single run's export: the route slug plus the run's own
/// start, so the file says what it holds rather than when it was written —
/// `against-yesterday-river-loop-2026-01-02-030405.gpx`.
///
/// Falls back to the stored route id when no [routeName] is known, and to the
/// bare stamp when there is neither. Re-exporting the same run lands on the
/// same name; Android's `MediaStore` de-duplicates it.
String gpxActivityFileName({
  required Activity activity,
  String? routeName,
}) {
  final slug = _slug(routeName ?? activity.routeId ?? '');
  final stamp = _stamp(activity.startedAt);
  return slug.isEmpty
      ? 'against-yesterday-$stamp.gpx'
      : 'against-yesterday-$slug-$stamp.gpx';
}

String _stamp(DateTime when) {
  final local = when.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}${two(local.second)}';
}

/// Folds the accented letters the route names in this app actually use, so a
/// German route keeps its spelling in ASCII.
const _foldings = {
  'ä': 'a',
  'ö': 'o',
  'ü': 'u',
  'ß': 'ss',
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'é': 'e',
  'è': 'e',
  'ç': 'c',
  'ñ': 'n',
};

/// Lowercases [value] and folds everything that is not a plain ASCII letter or
/// digit into single dashes, so `Hügelrunde (North)` becomes `hugelrunde-north`.
String _slug(String value) {
  final folded = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    folded.write(_foldings[char] ?? char);
  }
  return folded
      .toString()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
