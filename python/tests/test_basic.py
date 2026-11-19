# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

import pytest

import against_yesterday as ay


def sample_gpx() -> str:
    return """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>sample</name><trkseg>
    <trkpt lat="47.37690" lon="8.54170"><time>2024-01-01T10:00:00.000Z</time></trkpt>
    <trkpt lat="47.37710" lon="8.54190"><time>2024-01-01T10:00:20.000Z</time></trkpt>
    <trkpt lat="47.37730" lon="8.54210"><time>2024-01-01T10:00:40.000Z</time></trkpt>
  </trkseg></trk>
</gpx>
"""


def test_parse_gpx_and_stats():
    track = ay.parse_gpx(sample_gpx())
    assert track.point_count == 3
    assert track.distance_m > 0.0
    assert track.duration_s == pytest.approx(40.0)
    assert len(track.coordinates()) == 3


def test_filter_simplify_resample_and_write(tmp_path):
    track = ay.parse_gpx(sample_gpx())
    filtered, report = track.filter()
    assert isinstance(report, ay.ProcessingReport)
    assert report.output_points >= 2

    simplified = filtered.simplify(tolerance_m=5.0)
    assert simplified.point_count >= 2

    resampled = simplified.resample_by_distance(interval_m=5.0)
    assert resampled.point_count >= 2

    xml = resampled.to_gpx()
    assert "<gpx" in xml

    out = tmp_path / "out.gpx"
    resampled.to_gpx_path(str(out))
    assert out.exists()
    roundtrip = ay.Track.from_gpx_path(str(out))
    assert roundtrip.point_count == resampled.point_count
