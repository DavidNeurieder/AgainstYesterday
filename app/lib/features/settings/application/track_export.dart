// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where Settings → Export GPX puts its file (M21, §26).
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
String gpxFileName(DateTime now) {
  final local = now.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'against-yesterday-'
      '${local.year}-${two(local.month)}-${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}${two(local.second)}.gpx';
}
