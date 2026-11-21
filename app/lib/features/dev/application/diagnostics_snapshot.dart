// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Aggregated diagnostic readout (M15 Phase 10 / 12).
///
/// The diagnostics screen is a pure projection of a single
/// [diagnosticsSnapshotProvider]: all the "investigation" — reading the engine,
/// the live session, the raw-fix buffer, the route catalog and persistence —
/// happens here, not in the widget. That keeps the screen testable and makes
/// the developer-facing data flow explicit.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../recording/application/recording_controller.dart';

/// The raw fixes and route geometry the diagnostics screen could export right
/// now. [route] is `null` when the recording has no geometry to replay against
/// (e.g. a run started without a route and never matched).
class ExportData {
  const ExportData({required this.fixes, this.route});

  final List<GpsFix> fixes;
  final List<GeoPoint>? route;

  /// Whether [buildFixtureJson] can produce a document from this data.
  bool get canExport => fixes.isNotEmpty && route != null;
}

/// Everything the diagnostics screen renders, in one immutable value.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.engineDescription,
    required this.engineType,
    required this.gpsSourceDescription,
    required this.runStatus,
    required this.gpsQuality,
    required this.latestFix,
    required this.paceDescription,
    required this.startedAt,
    required this.elapsedDescription,
    required this.distanceDescription,
    required this.rawFixCount,
    required this.processedPointCount,
    required this.backgroundProtectionDescription,
    required this.routeName,
    required this.routeProgress,
    required this.routeGeometryPoints,
    required this.ghostGap,
    required this.matchStatus,
    required this.matchConfidence,
    required this.recovery,
    required this.exportData,
  });

  final String engineDescription;
  final String engineType;

  /// Where the live run gets its fixes: `device GPS`, or the deterministic
  /// scenario timeline when no device source is wired in.
  final String gpsSourceDescription;
  final String runStatus;
  final String gpsQuality;

  /// Most recent raw observation, when a session has produced one.
  final GpsFix? latestFix;
  final String paceDescription;
  final DateTime? startedAt;
  final String elapsedDescription;
  final String distanceDescription;

  /// Raw fixes retained for the live session (M15 Phase 12).
  final int rawFixCount;

  /// Processed points the run would be persisted with.
  final int processedPointCount;

  /// Foreground-service protection state, in words a developer can trust.
  final String backgroundProtectionDescription;

  /// `null` means "new route" (no route recognised).
  final String? routeName;
  final double routeProgress;
  final int routeGeometryPoints;

  final GhostState? ghostGap;

  /// Live route-match state (initializing/matched/uncertain/off-route/
  /// reacquiring) surfaced by the engine.
  final String matchStatus;
  final double matchConfidence;

  /// The recoverable in-progress run snapshot, when one exists.
  final RunSnapshot? recovery;

  final ExportData exportData;
}

/// Builds the diagnostics readout from the engine, live session, raw-fix
/// buffer, route catalog and persistence providers.
final diagnosticsSnapshotProvider = Provider.autoDispose<DiagnosticsSnapshot>((
  ref,
) {
  final engine = ref.watch(engineServiceProvider);
  final live = ref.watch(recordingControllerProvider);
  final recovery = ref.watch(runSnapshotProvider);
  final activities = ref.watch(activityRepositoryProvider);
  final routes = ref.watch(routeRepositoryProvider);
  final gpsSource = ref.watch(deviceGpsProvider);
  final controller = ref.read(recordingControllerProvider.notifier);

  final liveFixes = controller.currentFixes();
  final processed = controller.currentTrack();

  final snapshot = _ExportSource(
    liveFixes: liveFixes,
    liveRoute: live?.route?.geometry,
    activities: activities,
    routes: routes,
  );

  return DiagnosticsSnapshot(
    engineDescription: engine.engineDescription,
    engineType: engine.runtimeType.toString(),
    gpsSourceDescription: gpsSource?.description ?? 'scenario (demo timeline)',
    runStatus: live?.status.name ?? '—',
    gpsQuality: live?.gpsQuality ?? '—',
    latestFix: (liveFixes != null && liveFixes.isNotEmpty)
        ? liveFixes.last
        : null,
    paceDescription: live?.pace.formatPace() ?? '—',
    startedAt: live?.startedAt,
    elapsedDescription: live?.elapsed.format() ?? '—',
    distanceDescription: live?.distance.format() ?? '—',
    rawFixCount: liveFixes?.length ?? 0,
    processedPointCount: processed?.length ?? 0,
    backgroundProtectionDescription: switch (live?.backgroundProtection) {
      BackgroundProtection.active =>
        'active — screen-off recording protected',
      BackgroundProtection.starting => 'starting',
      BackgroundProtection.unavailable =>
        'unavailable — screen-off recording not protected',
      BackgroundProtection.inactive => 'inactive — no device stream',
      null => '—',
    },
    routeName: live?.route?.name,
    routeProgress: live?.routeProgress ?? 0,
    routeGeometryPoints: live?.route?.geometry.length ?? 0,
    ghostGap: live?.ghostGap,
    matchStatus: _matchStatusName(live?.matchStatus ?? 0),
    matchConfidence: live?.matchConfidence ?? 0,
    recovery: recovery,
    exportData: snapshot.exportData,
  );
});

/// Resolves which raw fixes and route geometry an export should use: the live
/// session when it has fixes, otherwise the most recent persisted activity that
/// retained raw fixes. Never borrows demo geometry — [ExportData.route] stays
/// `null` when the recording has none.
class _ExportSource {
  _ExportSource({
    required List<GpsFix>? liveFixes,
    required List<GeoPoint>? liveRoute,
    required List<Activity> activities,
    required List<Route> routes,
  }) {
    if (liveFixes != null && liveFixes.isNotEmpty) {
      exportData = ExportData(fixes: liveFixes, route: liveRoute);
      return;
    }
    for (final activity in activities) {
      // Bundled examples now carry raw fixes too, but diagnostics exports must
      // describe the user's receiver — never a demo trace.
      if (activity.isExample) continue;
      final raw = activity.rawFixes;
      if (raw == null || raw.isEmpty) {
        continue;
      }
      final geometry = activity.routeId == null
          ? null
          : routes
                .where((r) => r.id == activity.routeId)
                .map((r) => r.geometry)
                .firstOrNull;
      exportData = ExportData(fixes: raw, route: geometry);
      return;
    }
    exportData = const ExportData(fixes: [], route: null);
  }

  late final ExportData exportData;
}

/// Converts a match-status code to a human-readable name.
String _matchStatusName(int code) {
  return switch (code) {
    0 => 'none',
    1 => 'initializing',
    2 => 'matched',
    3 => 'uncertain',
    4 => 'off-route',
    5 => 'reacquiring',
    _ => 'unknown',
  };
}
