// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Serializes a recording to the M15 raw-GPS fixture schema (developer
/// diagnostics, M15 Phase 10 / 12; fixture schema version 1).
///
/// The emitted document is exactly what `rust/gps-engine`'s
/// `Fixture::from_json` parses back:
///
/// ```json
/// {"schema_version":1,
///  "route":[{"lat":..,"lon":..}],
///  "fixes":[{"timestamp_ms":..,"latitude":..,"longitude":..,
///            "accuracy_m":..,"altitude_m":..,"speed_mps":..,"bearing_deg":..}]}
/// ```
///
/// The fixes are raw receiver observations (M15 Phase 12), not a track
/// re-derived from the app's processed samples; every sensor field the device
/// reported is written verbatim and a field it never reported is emitted as an
/// explicit `null`. Nothing is invented — a real trace can be pasted straight
/// into `tests/fixtures/` and replayed as a regression test.
///
/// Exports never silently fall back to fake geometry: when a document cannot
/// be built, [buildFixtureJson] raises a [FixtureExportException] carrying a
/// user-facing message.
library;

import 'dart:convert';

import '../../../engine/models.dart';

/// Fixture schema version emitted by [buildFixtureJson]. Must track
/// `gps_engine::gps::FIXTURE_SCHEMA_VERSION` on the Rust side.
const int fixtureSchemaVersion = 1;

/// Shown to the developer before an export leaves the app: fixtures contain the
/// exact location track and timestamps.
const String fixturePrivacyWarning =
    'This fixture contains your exact GPS track and timestamps. '
    'Treat it as personal data: strip or offset the positions before sharing '
    'it publicly or attaching it to a bug report.';

/// Raised when an export cannot be built. The [message] is user-facing.
class FixtureExportException implements Exception {
  const FixtureExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Shown when there is no geometry to replay a trace against.
const String noRouteGeometryMessage =
    'No route geometry is available for this recording.';

/// Builds a fixture JSON document from [route] geometry and raw [fixes].
///
/// Throws [FixtureExportException] when [route] has no usable geometry
/// ([noRouteGeometryMessage]) — a fixture with no route cannot validate the
/// positions and would silently point at demo data.
String buildFixtureJson({
  required List<GeoPoint> route,
  required List<GpsFix> fixes,
}) {
  if (route.length < 2) {
    throw const FixtureExportException(noRouteGeometryMessage);
  }
  return const JsonEncoder().convert({
    'schema_version': fixtureSchemaVersion,
    'route': [
      for (final p in route) {'lat': p.latitude, 'lon': p.longitude},
    ],
    'fixes': [for (final fix in fixes) _fixJson(fix)],
  });
}

/// One raw fix as a JSON object. All six sensor fields are always present;
/// absent values are explicit `null` (the Rust parser treats null and a missing
/// key identically).
Map<String, Object?> _fixJson(GpsFix fix) => {
  'timestamp_ms': fix.timestamp.millisecondsSinceEpoch,
  'latitude': fix.latitude,
  'longitude': fix.longitude,
  'accuracy_m': fix.accuracyMeters,
  'altitude_m': fix.altitudeMeters,
  'speed_mps': fix.speedMetersPerSecond,
  'bearing_deg': fix.bearingDegrees,
};
