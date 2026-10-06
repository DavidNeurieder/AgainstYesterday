// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/engine/models.dart';
import 'package:gps_app/features/dev/application/fixture_export.dart';

/// M15.10: the exporter's schema contract, independent of any widget.
void main() {
  const route = <GeoPoint>[
    GeoPoint(latitude: 52.5, longitude: 13.4),
    GeoPoint(latitude: 52.5, longitude: 13.4005),
    GeoPoint(latitude: 52.5, longitude: 13.401),
  ];

  GpsFix fix(
    int ms,
    double lat,
    double lon, {
    double? accuracy,
    double? altitude,
    double? speed,
    double? bearing,
  }) => GpsFix(
    timestamp: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    latitude: lat,
    longitude: lon,
    accuracyMeters: accuracy,
    altitudeMeters: altitude,
    speedMetersPerSecond: speed,
    bearingDegrees: bearing,
  );

  Map<String, Object?> decode(String json) =>
      jsonDecode(json) as Map<String, Object?>;

  test('emits the current schema version even for an empty trace', () {
    final doc = decode(buildFixtureJson(route: route, fixes: const []));
    expect(doc['schema_version'], fixtureSchemaVersion);
    expect(fixtureSchemaVersion, 1);
    expect(doc['fixes'], isEmpty);
    expect(doc['route'], hasLength(3));
  });

  test('rejects a recording with no usable route geometry', () {
    expect(
      () => buildFixtureJson(
        route: const [GeoPoint(latitude: 1, longitude: 2)],
        fixes: [fix(0, 1, 2)],
      ),
      throwsA(
        isA<FixtureExportException>().having(
          (e) => e.message,
          'message',
          noRouteGeometryMessage,
        ),
      ),
    );
  });

  test('a single fix keeps every sensor field, unknown ones as null', () {
    final doc = decode(
      buildFixtureJson(
        route: route,
        fixes: [fix(1000, 52.5, 13.4, accuracy: 5, altitude: 60)],
      ),
    );
    final first = (doc['fixes']! as List).single as Map;
    expect(first['timestamp_ms'], 1000);
    expect(first['latitude'], 52.5);
    expect(first['longitude'], 13.4);
    expect(first['accuracy_m'], 5);
    expect(first['altitude_m'], 60);
    expect(first.containsKey('speed_mps'), isTrue);
    expect(first['speed_mps'], isNull, reason: 'no predecessor, no speed');
    expect(first.containsKey('bearing_deg'), isTrue);
    expect(first['bearing_deg'], isNull);
  });

  test(
    'missing device values are explicit null, never fabricated defaults',
    () {
      final doc = decode(
        buildFixtureJson(
          route: route,
          fixes: [fix(0, 52.5, 13.4), fix(1000, 52.5, 13.4005)],
        ),
      );
      for (final raw in doc['fixes']! as List) {
        final map = raw as Map;
        for (final field in [
          'accuracy_m',
          'altitude_m',
          'speed_mps',
          'bearing_deg',
        ]) {
          expect(
            map.containsKey(field),
            isTrue,
            reason: '$field is always emitted',
          );
          expect(map[field], isNull, reason: '$field was not reported');
        }
      }
    },
  );

  test('preserves a poor reported accuracy verbatim', () {
    final doc = decode(
      buildFixtureJson(
        route: route,
        fixes: [fix(0, 52.5, 13.4, accuracy: 47.5)],
      ),
    );
    final first = (doc['fixes']! as List).single as Map;
    expect(first['accuracy_m'], 47.5);
    expect(first['accuracy_m'], isNot(5.0));
  });

  test('multiple fixes keep arrival order and exact timestamps', () {
    final doc = decode(
      buildFixtureJson(
        route: route,
        fixes: [
          fix(0, 52.5, 13.4, speed: 3.1, bearing: 10),
          fix(2000, 52.5, 13.4005, speed: 3.4, bearing: 90),
          fix(4000, 52.5, 13.401, speed: 3.2, bearing: 95),
        ],
      ),
    );
    final fixes = (doc['fixes']! as List).cast<Map>();
    expect(fixes, hasLength(3));
    expect(fixes.map((f) => f['timestamp_ms']), [0, 2000, 4000]);
    expect(fixes[1]['speed_mps'], 3.4);
    expect(fixes[2]['bearing_deg'], 95);
  });

  test('GPS dropout/jump/out-of-order fixes are exported in raw order', () {
    // The exporter is deliberately dumb: it preserves the observations the
    // receiver produced, in the order it produced them. The Rust pipeline
    // normalizes (sorts, dedups) and filters — that is not the exporter's job.
    final doc = decode(
      buildFixtureJson(
        route: route,
        fixes: [
          fix(2000, 52.5, 13.4005),
          fix(0, 52.5, 13.4),
          fix(1000, 52.9, 13.9), // a 60 km jump, still a raw observation
        ],
      ),
    );
    final fixes = (doc['fixes']! as List).cast<Map>();
    expect(fixes.map((f) => f['timestamp_ms']), [2000, 0, 1000]);
    expect(fixes[2]['latitude'], 52.9);
  });

  test('a large trace round-trips through JSON', () {
    final fixes = [
      for (var i = 0; i < 5000; i++)
        fix(i * 1000, 52.5 + i * 1e-6, 13.4, speed: 3.0, bearing: 45),
    ];
    final doc = decode(buildFixtureJson(route: route, fixes: fixes));
    expect(doc['fixes'], hasLength(5000));
    expect(((doc['fixes']! as List).last as Map)['timestamp_ms'], 4_999_000);
  });
}
