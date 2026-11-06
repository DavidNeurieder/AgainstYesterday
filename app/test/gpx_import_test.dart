// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:against_yesterday/features/settings/application/gpx_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings → Import GPX: the geometry reader is lenient about attribute order
/// and quote style, and skips points it cannot parse instead of the whole file.
void main() {
  test('reads every track point in document order', () {
    const contents = '''
<?xml version="1.0"?>
<gpx version="1.1">
  <trk>
    <name>River Loop</name>
    <trkseg>
      <trkpt lat="52.5" lon="13.4"><ele>34</ele></trkpt>
      <trkpt lat="52.5005" lon="13.4005"/>
    </trkseg>
  </trk>
</gpx>
''';
    final points = parseGpxTrack(contents);
    expect(points, hasLength(2));
    expect(points.first.latitude, 52.5);
    expect(points.first.longitude, 13.4);
    expect(points.last.latitude, 52.5005);
    expect(points.last.longitude, 13.4005);
  });

  test('accepts lon before lat and single-quoted values', () {
    final points = parseGpxTrack("<trkpt lon='13.4' lat='52.5'></trkpt>");
    expect(points.single.latitude, 52.5);
    expect(points.single.longitude, 13.4);
  });

  test('skips malformed points and keeps the rest', () {
    final points = parseGpxTrack(
      '<trkpt lat="nope" lon="13.4"/><trkpt lat="52.5" lon="13.4"/>',
    );
    expect(points, hasLength(1));
    expect(points.single.latitude, 52.5);
  });

  test('an empty or point-free document yields no geometry', () {
    expect(parseGpxTrack(''), isEmpty);
    expect(parseGpxTrack('<gpx><trk><name>Empty</name></trk></gpx>'), isEmpty);
  });
}
