// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Distance & geometry invariants (test plan Phases 3 and 4).
///
/// The fake engine's haversine/polyline helpers are the only geometry the
/// Dart/render layer sees; these tests pin the mathematical invariants so the
/// fake can be swapped for the real Rust engine (M9) without breaking the UI.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/engine/models.dart';

void main() {
  const a = GeoPoint(latitude: 52.52, longitude: 13.405);
  const b = GeoPoint(latitude: 52.53, longitude: 13.395);

  group('haversine distance invariants', () {
    test('distance is symmetric', () {
      expect(
        haversineMeters(a, b),
        closeTo(haversineMeters(b, a), 1e-9),
      );
    });

    test('distance is non-negative and positive between distinct points', () {
      expect(haversineMeters(a, b), greaterThan(0));
      expect(haversineMeters(a, a), 0);
    });

    test('a known separation: 1° of latitude ≈ 111.19 km', () {
      const equator = GeoPoint(latitude: 0, longitude: 0);
      const north = GeoPoint(latitude: 1, longitude: 0);
      expect(haversineMeters(equator, north), closeTo(111195, 50));
    });

    test('tiny movement is small but positive', () {
      const p = GeoPoint(latitude: 52.0, longitude: 13.0);
      const q = GeoPoint(latitude: 52.00000001, longitude: 13.0);
      final d = haversineMeters(p, q);
      expect(d, greaterThan(0));
      expect(d, closeTo(0.0011, 0.0005));
    });

    test('crossing the equator and prime meridian stays consistent', () {
      const north = GeoPoint(latitude: 0.5, longitude: 0.5);
      const south = GeoPoint(latitude: -0.5, longitude: -0.5);
      final d = haversineMeters(north, south);
      expect(d, greaterThan(0));
      expect(d, closeTo(haversineMeters(south, north), 1e-9));
    });

    test('antimeridian: ±180° longitudes coincide', () {
      const east = GeoPoint(latitude: 0, longitude: 180);
      const west = GeoPoint(latitude: 0, longitude: -180);
      expect(haversineMeters(east, west), closeTo(0, 10));

      const justEast = GeoPoint(latitude: 0, longitude: 179.9999);
      const justWest = GeoPoint(latitude: 0, longitude: -179.9999);
      expect(haversineMeters(justEast, justWest), lessThan(50));
    });

    test('pole to pole is one half great circle (~π·R)', () {
      const north = GeoPoint(latitude: 90, longitude: 0);
      const south = GeoPoint(latitude: -90, longitude: 0);
      const expected = 3.141592653589793 * 6371000.0;
      expect(haversineMeters(north, south), closeTo(expected, 1000));
    });
  });

  group('pointAlongPolyline boundaries', () {
    const geometry = <GeoPoint>[
      GeoPoint(latitude: 0, longitude: 0),
      GeoPoint(latitude: 0, longitude: 1),
      GeoPoint(latitude: 1, longitude: 1),
    ];

    test('zero meters returns the first point', () {
      expect(pointAlongPolyline(geometry, 0), geometry.first);
    });

    test('the full length returns the last point', () {
      final total = polylineMeters(geometry);
      expect(pointAlongPolyline(geometry, total), geometry.last);
    });

    test('beyond the full length still returns the last point', () {
      final total = polylineMeters(geometry);
      expect(pointAlongPolyline(geometry, total + 1000), geometry.last);
    });

    test('distance beyond the *segment* midpoint is possible (linear lerp)', () {
      // Exactly half the first segment: longitude interpolates to 0.5.
      const firstSegment = GeoPoint(latitude: 0, longitude: 1);
      final half = haversineMeters(geometry[0], firstSegment) / 2;
      final p = pointAlongPolyline(geometry, half);
      expect(p!.longitude, closeTo(0.5, 0.01));
      expect(p.latitude, closeTo(0, 0.01));
    });

    test('negative distance returns null', () {
      expect(pointAlongPolyline(geometry, -1), isNull);
    });

    test('empty geometry returns null', () {
      expect(pointAlongPolyline(const [], 0), isNull);
    });
  });

  group('polyline monotonicity', () {
    const base = <GeoPoint>[
      GeoPoint(latitude: 0, longitude: 0),
      GeoPoint(latitude: 0, longitude: 1),
    ];

    test('appending a point never decreases the total length', () {
      final extended = <GeoPoint>[
        ...base,
        const GeoPoint(latitude: 0.5, longitude: 1),
      ];
      expect(polylineMeters(extended), greaterThanOrEqualTo(polylineMeters(base)));
    });

    test('appending an identical point adds no distance', () {
      final withDup = <GeoPoint>[...base, base.last];
      expect(polylineMeters(withDup), closeTo(polylineMeters(base), 1e-9));
    });

    test('splitting a segment at its midpoint preserves length', () {
      const split = <GeoPoint>[
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.5),
        GeoPoint(latitude: 0, longitude: 1),
      ];
      expect(polylineMeters(split), closeTo(polylineMeters(base), 1e-9));
    });

    test('a trailing doubled segment doubles only itself', () {
      const geometry = <GeoPoint>[
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 1),
        GeoPoint(latitude: 1, longitude: 1),
        GeoPoint(latitude: 2, longitude: 1),
      ];
      expect(
        polylineMeters(geometry),
        closeTo(
          polylineMeters(const <GeoPoint>[
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 1),
            GeoPoint(latitude: 1, longitude: 1),
          ]) +
              haversineMeters(
                const GeoPoint(latitude: 1, longitude: 1),
                const GeoPoint(latitude: 2, longitude: 1),
              ),
          1e-9,
        ),
      );
    });
  });
}