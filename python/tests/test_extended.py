# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

import json

import pytest

import against_yesterday as ay


def sample_gpx() -> str:
    return """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>sample</name><trkseg>
    <trkpt lat="52.50000" lon="13.40000"><time>2024-01-01T10:00:00.000Z</time></trkpt>
    <trkpt lat="52.50050" lon="13.40000"><time>2024-01-01T10:00:10.000Z</time></trkpt>
    <trkpt lat="52.50100" lon="13.40000"><time>2024-01-01T10:00:20.000Z</time></trkpt>
    <trkpt lat="52.50150" lon="13.40000"><time>2024-01-01T10:00:30.000Z</time></trkpt>
  </trkseg></trk>
</gpx>
"""


def outlier_gpx() -> str:
    points = "\n".join(
        '<trkpt lat="{lat:.8f}" lon="13.40000">'
        "<time>2024-01-01T10:{minute:02d}:{second:02d}.000Z</time>"
        "</trkpt>".format(
            lat=52.5 + (index * 2.0 + (500.0 if index == 40 else 0.0)) / 111195.0,
            minute=index // 60,
            second=index % 60,
        )
        for index in range(80)
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>outlier</name><trkseg>
{points}
  </trkseg></trk>
</gpx>
"""


def noisy_altitude_gpx() -> str:
    altitudes = [
        0, 2, 0, 2, 0, 2, 0, 2, 10, 20, 30, 40,
        40, 40, 30, 20, 10, 0, 0, 0,
    ]
    points = "\n".join(
        '<trkpt lat="{lat:.5f}" lon="13.40000">'
        "<ele>{alt}</ele>"
        "<time>2024-01-01T10:{minute:02d}:{second:02d}.000Z</time>"
        "</trkpt>".format(
            lat=52.5 + index * 0.00001,
            alt=alt,
            minute=index // 60,
            second=index % 60,
        )
        for index, alt in enumerate(altitudes)
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>altitude</name><trkseg>
{points}
  </trkseg></trk>
</gpx>
"""


def test_route_attempt_and_performance():
    track = ay.parse_gpx(sample_gpx())
    route = ay.Route(track.coordinates())
    assert route.length_m > 0

    attempt = ay.Attempt.from_track(track, route)
    assert attempt.distance_m > 0
    assert attempt.elapsed_time_s == pytest.approx(30.0)
    assert attempt.time_at(0.0) == pytest.approx(0.0)

    slower = ay.Attempt.from_samples([
        ay.AttemptSample(0.0, 0.0),
        ay.AttemptSample(attempt.distance_m, attempt.elapsed_time_s + 10.0),
    ])
    cmp = ay.compare_performances(attempt, slower)
    assert cmp.total_time_difference_s == pytest.approx(10.0)

    ghost = ay.Ghost(attempt, slower)
    state = ghost.state_at_distance(attempt.distance_m)
    assert state is not None
    assert state.time_difference_s == pytest.approx(10.0)
    assert state.ahead is False


def test_matching_and_catalog():
    track = ay.parse_gpx(sample_gpx())
    score = ay.compare_tracks(track, track)
    assert score.is_match() is True
    assert ay.compare_tracks_either_direction(track, track) is not None

    catalog = ay.RouteCatalog()
    add = catalog.add_track(track)
    assert add.route_id == 0
    assert catalog.route_count() == 1


def test_analytics():
    track = ay.parse_gpx(sample_gpx())
    analytics = track.analytics()
    assert analytics.distance_m > 0
    assert isinstance(analytics.to_json(), str)
    assert analytics.quality.accepted_samples == track.point_count


def test_analytics_exposes_rolling_best_pace_additively():
    analytics = ay.parse_gpx(outlier_gpx()).analytics()
    legacy = analytics.best_pace_ms_per_km
    rolling = analytics.rolling_best_pace_ms_per_km
    assert legacy is not None and rolling is not None
    assert legacy * 10 < rolling
    assert 490_000 <= rolling <= 510_000
    payload = json.loads(analytics.to_json())
    assert payload["rolling_best_pace_ms_per_km"] == rolling


def test_analytics_reports_robust_elevation():
    analytics = ay.parse_gpx(noisy_altitude_gpx()).analytics()
    assert analytics.elevation_gain_m > analytics.robust_elevation_gain_m
    assert analytics.robust_elevation_gain_m > 0
    assert analytics.robust_elevation_loss_m > 0
    payload = json.loads(analytics.to_json())
    assert "robust_elevation_gain_m" in payload
    assert "robust_elevation_loss_m" in payload


def test_live_recorder_and_replay():
    base_ms = 1_700_000_000_000
    fixes = [
        ay.GpsFix(base_ms + i * 1000, 52.5 + i * 0.00005, 13.4)
        for i in range(10)
    ]
    ghost = ay.LiveGhost([(i * 5.0, float(i)) for i in range(20)])
    route = ay.Route([(f.latitude, f.longitude) for f in fixes])

    rec = ay.LiveRecorder(route=route)
    rec.set_ghost(ghost)
    for f in fixes:
        rec.push(f)
    snap = rec.snapshot()
    assert snap.distance_m >= 0.0
    assert rec.ghost_snapshot() is not None

    replay = ay.ReplaySession(fixes, route=route, ghost=ghost)
    replay.play()
    rs = replay.advance(5.0)
    assert rs.applied_fixes >= 0
    assert rs.state in ("playing", "finished", "paused")
