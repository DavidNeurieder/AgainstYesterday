# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Iteration, indexing, and property/method compatibility."""

from __future__ import annotations

from pathlib import Path

import pytest

import against_yesterday as ay


def fixture_gpx() -> Path:
    return (
        Path(__file__).resolve().parents[2]
        / "app"
        / "assets"
        / "examples"
        / "cycling_finland_1.gpx"
    )


def test_track_iteration_and_indexing_from_bundled_fixture():
    track = ay.Track.from_gpx_path(fixture_gpx())
    points = list(track)

    assert len(track) == track.point_count == len(points)
    assert points[0].timestamp_ms == track[0].timestamp_ms
    assert points[-1].timestamp_ms == track[-1].timestamp_ms
    assert [p.timestamp_ms for p in points] == [
        p.timestamp_ms for p in track.points()
    ]
    assert [p.latitude for p in points] == [latitude for latitude, _ in track.coordinates()]

    with pytest.raises(IndexError):
        track[len(track)]
    with pytest.raises(IndexError):
        track[-len(track) - 1]


def test_attempt_iteration_and_indexing():
    samples = [ay.AttemptSample(float(i * 10), float(i)) for i in range(4)]
    attempt = ay.Attempt.from_samples(samples)

    assert len(attempt) == len(samples)
    assert [(s.distance_m, s.elapsed_s) for s in attempt] == [
        (s.distance_m, s.elapsed_s) for s in samples
    ]
    assert attempt[0].elapsed_s == 0.0
    assert attempt[-1].elapsed_s == 3.0

    with pytest.raises(IndexError):
        attempt[4]


def test_route_iteration_coordinates_property_and_indexing():
    coordinates = [(47.0, 8.0), (47.001, 8.001), (47.002, 8.002)]
    route = ay.Route(coordinates)

    assert len(route) == 3
    assert list(route) == route.geometry() == route.coordinates == coordinates
    assert route[0] == coordinates[0]
    assert route[-1] == coordinates[-1]

    with pytest.raises(IndexError):
        route[3]


def test_route_catalog_iteration_and_length():
    track = ay.Track.from_gpx_path(fixture_gpx())
    catalog = ay.RouteCatalog()
    addition = catalog.add_track(track)

    assert addition.route_id == 0
    assert len(catalog) == catalog.route_count() == 1
    assert [(route.id, route.track_count) for route in catalog] == [
        (route.id, route.track_count) for route in catalog.routes()
    ]
    assert catalog.representative(0) is not None


def test_compatibility_callable_properties():
    recorder = ay.LiveRecorder()
    for name in (
        "distance_m",
        "moving_s",
        "pace_mps",
        "loop_length_m",
        "elapsed_for_gap_s",
    ):
        value = getattr(recorder, name)
        assert isinstance(value, float)
        assert value() == value

    ghost = ay.LiveGhost([(0.0, 0.0), (10.0, 5.0)])
    assert ghost.elapsed_time_s == ghost.elapsed_time_s() == 5.0

    fixes = [ay.GpsFix(i * 1000, 47.0 + i * 0.0001, 8.0) for i in range(5)]
    replay = ay.ReplaySession(fixes)

    for name in ("duration_s", "elapsed_s"):
        value = getattr(replay, name)
        assert isinstance(value, float)
        assert value() == value
    assert isinstance(replay.state, ay.ReplayState)
    assert replay.state() == replay.state.value


def test_snapshot_enums_are_typed_members():
    fixes = [ay.GpsFix(i * 1000, 47.0 + i * 0.0001, 8.0) for i in range(5)]
    recorder = ay.LiveRecorder(route=ay.Route([(f.latitude, f.longitude) for f in fixes]))
    recorder.push(fixes[0])

    live = recorder.snapshot()
    assert isinstance(live.match_status, ay.LiveMatchStatus)

    replay = ay.ReplaySession(fixes)
    snapshot = replay.snapshot()
    assert isinstance(snapshot.state, ay.ReplayState)
    assert isinstance(snapshot.match_status, ay.LiveMatchStatus)
