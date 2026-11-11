// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bundled example route: a real cycling track from the GeoPrivacy open
/// dataset, exposed as one example course with six real runs so a new user
/// can explore route details, history, statistics and ghost racing without
/// recording anything.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../settings/application/gpx_import.dart';

const String _manifestAsset = 'assets/examples/manifest.json';

/// Attribution shown for the bundled example route.
const String kExampleAttribution =
    'GPS data: GeoPrivacy (2023) | CC BY 4.0 (adapted)';

/// Loads the bundled example route (and its runs) from assets. Returns an
/// empty list when the manifest or GPX is missing, so a build without the
/// assets still runs.
final exampleRoutesProvider = FutureProvider<List<Route>>((ref) async {
  final engine = ref.read(engineServiceProvider);
  try {
    final raw = await rootBundle.loadString(_manifestAsset);
    final entry = jsonDecode(raw) as Map<String, dynamic>;
    final routeGpx = await rootBundle.loadString(
      'assets/examples/${entry['routeGpx']}',
    );
    final details = parseGpxTrackDetails(routeGpx);
    if (details.points.length < 2) return const [];
    final trackPoints = _toTrackPoints(details);
    final info = await engine.routeInfo(points: trackPoints);
    return [
      Route(
        id: entry['id'] as String,
        name: entry['name'] as String,
        distance: Distance.meters(info.lengthMeters),
        geometry: details.points,
        isExample: true,
      ),
    ];
  } catch (e) {
    debugPrint('exampleRoutesProvider failed: $e');
    rethrow;
  }
});

/// Loads the bundled example runs (activities) for the example route.
final exampleActivitiesProvider = FutureProvider<List<Activity>>((ref) async {
  try {
    final raw = await rootBundle.loadString(_manifestAsset);
    final entry = jsonDecode(raw) as Map<String, dynamic>;
    final routeId = entry['id'] as String;
    final runs = <Activity>[];
    final runFiles = (entry['runGpx'] as List).cast<String>();
    var index = 0;
    for (final file in runFiles) {
      index++;
      String gpx;
      try {
        gpx = await rootBundle.loadString('assets/examples/$file');
      } catch (_) {
        continue;
      }
      final details = parseGpxTrackDetails(gpx);
      if (details.points.length < 2) continue;
      final trackPoints = _toTrackPoints(details);
      final timestamps = details.timestamps.whereType<DateTime>().toList();
      final startedAt = timestamps.isNotEmpty
          ? timestamps.first.toUtc()
          : DateTime.now().toUtc();
      final durationSeconds = timestamps.length >= 2
          ? timestamps.last.difference(timestamps.first).inMilliseconds / 1000.0
          : 0.0;
      runs.add(Activity(
        id: 'example-run-$index',
        routeId: routeId,
        startedAt: startedAt,
        duration: durationSeconds > 0
            ? Elapsed.seconds(durationSeconds)
            : null,
        track: trackPoints,
        isExample: true,
      ));
    }
    return runs;
  } catch (e) {
    debugPrint('exampleActivitiesProvider failed: $e');
    rethrow;
  }
});

List<TrackPoint> _toTrackPoints(GpxTrack details) {
  final n = details.points.length;
  final timestamps = details.timestamps;
  // Preserve real timestamps; interpolate gaps only between two known
  // samples. When no timestamp is available at all, fall back to a fixed,
  // monotonic base so the run is still timed consistently — but never mix
  // DateTime.now() into a track, which would distort ghost comparisons.
  final known = <int, DateTime>{};
  for (var i = 0; i < n; i++) {
    final t = timestamps[i];
    if (t != null) known[i] = t.toUtc();
  }
  final result = <TrackPoint>[];
  for (var i = 0; i < n; i++) {
    DateTime ts;
    final direct = timestamps[i];
    if (direct != null) {
      ts = direct.toUtc();
    } else if (known.isNotEmpty) {
      // Find surrounding known samples.
      int? prev, next;
      for (var j = i - 1; j >= 0; j--) {
        if (known.containsKey(j)) {
          prev = j;
          break;
        }
      }
      for (var j = i + 1; j < n; j++) {
        if (known.containsKey(j)) {
          next = j;
          break;
        }
      }
      if (prev != null && next != null) {
        final span = next - prev;
        final frac = (i - prev) / span;
        final ms = known[prev]!.millisecondsSinceEpoch +
            ((known[next]!.millisecondsSinceEpoch -
                    known[prev]!.millisecondsSinceEpoch) *
                frac)
                .round();
        ts = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      } else if (prev != null) {
        ts = known[prev]!.add(Duration(seconds: i - prev));
      } else if (next != null) {
        ts = known[next]!.subtract(Duration(seconds: next - i));
      } else {
        ts = DateTime.utc(2023, 1, 1).add(Duration(seconds: i));
      }
    } else {
      ts = DateTime.utc(2023, 1, 1).add(Duration(seconds: i));
    }
    result.add(TrackPoint(position: details.points[i], timestamp: ts));
  }
  return result;
}

/// Whether any example route is currently installed in the library.
final hasExampleRoutesProvider = Provider<bool>((ref) {
  final routes = ref.watch(routeRepositoryProvider);
  return routes.any((r) => r.isExample);
});

/// Installs the bundled example route and its runs (idempotent).
Future<void> installExampleRoutes(ProviderContainer container) async {
  final examples = await container.read(exampleRoutesProvider.future);
  final runs = await container.read(exampleActivitiesProvider.future);
  final routeRepo = container.read(routeRepositoryProvider.notifier);
  final activityRepo = container.read(activityRepositoryProvider.notifier);
  for (final route in examples) {
    await routeRepo.saveRoute(route);
  }
  // Seed the route's personal best from the fastest run.
  if (examples.isNotEmpty && runs.isNotEmpty) {
    final fastest = runs
        .where((a) => a.duration != null)
        .reduce((a, b) =>
            a.duration!.seconds < b.duration!.seconds ? a : b);
    final updated = examples.first.copyWith(
      personalBest: fastest.duration,
      attemptCount: runs.length,
    );
    await routeRepo.saveRoute(updated);
  }
  for (final run in runs) {
    await activityRepo.saveActivity(run);
  }
}

/// Removes every example route and its runs, keeping personal data.
Future<void> removeExampleRoutes(ProviderContainer container) async {
  final routeRepo = container.read(routeRepositoryProvider.notifier);
  final activityRepo = container.read(activityRepositoryProvider.notifier);
  final keptRoutes = [
    for (final r in container.read(routeRepositoryProvider))
      if (!r.isExample) r,
  ];
  await routeRepo.setRoutes(keptRoutes);
  for (final a in container.read(activityRepositoryProvider)) {
    if (a.isExample) {
      await activityRepo.deleteActivity(a.id);
    }
  }
}
