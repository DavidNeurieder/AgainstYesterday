# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Binding-layer validation and path-like GPX I/O."""

from __future__ import annotations

import math
from pathlib import Path

import pytest

import against_yesterday as ay


def point(timestamp_ms: int, latitude: float = 47.0, longitude: float = 8.0):
    return ay.TrackPoint(latitude, longitude, timestamp_ms)


def gpx(*positions: tuple[float, float, str]) -> str:
    points = "\n".join(
        f'    <trkpt lat="{lat}" lon="{lon}"><time>{time}</time></trkpt>'
        for lat, lon, time in positions
    )
    return (
        '<gpx version="1.1" creator="test" '
        'xmlns="http://www.topografix.com/GPX/1/1">'
        f"<trk><trkseg>\n{points}\n</trkseg></trk></gpx>"
    )


@pytest.mark.parametrize(
    "make_value",
    [
        lambda: ay.TrackPoint(math.nan, 0.0, 0),
        lambda: ay.TrackPoint(91.0, 0.0, 0),
        lambda: ay.TrackPoint(0.0, -181.0, 0),
        lambda: ay.TrackPoint(0.0, 0.0, 0, bearing_deg=math.inf),
        lambda: ay.TrackPoint(0.0, 0.0, 0, bearing_deg=361.0),
        lambda: ay.GpsFix(0, 0.0, math.inf),
        lambda: ay.Route([(math.nan, 0.0), (0.0, 1.0)]),
    ],
)
def test_invalid_coordinates_and_bearings(make_value):
    with pytest.raises(ay.InvalidInputError):
        make_value()


@pytest.mark.parametrize(
    "make_value",
    [
        lambda: ay.TrackPoint(0.0, 0.0, 0, speed_mps=-1.0),
        lambda: ay.TrackPoint(0.0, 0.0, 0, speed_mps=math.nan),
        lambda: ay.TrackPoint(0.0, 0.0, 0, accuracy_m=-1.0),
        lambda: ay.TrackPoint(0.0, 0.0, 0, altitude_m=math.inf),
        lambda: ay.AttemptSample(-1.0, 0.0),
        lambda: ay.AttemptSample(0.0, math.nan),
        lambda: ay.LiveGhost([(-1.0, 0.0)]),
        lambda: ay.LiveGhost([(0.0, math.inf)]),
        lambda: ay.MovingConfig(min_speed_mps=math.nan),
        lambda: ay.FilterConfig(max_accuracy_m=-1.0),
        lambda: ay.FilterConfig(max_speed_kmh=0.0),
        lambda: ay.SimplifyConfig(tolerance_m=math.inf),
        lambda: ay.ComparisonConfig(step_m=0.0),
        lambda: ay.CanonicalizeConfig(step_m=-1.0),
        lambda: ay.LiveConfig(off_route_threshold_m=math.nan),
        lambda: ay.MatchConfig(lateral_tolerance_m=-1.0),
        lambda: ay.MatchConfig(min_spatial_overlap=1.1),
    ],
)
def test_non_finite_negative_and_zero_numeric_args(make_value):
    with pytest.raises(ay.InvalidInputError):
        make_value()


def test_overlapping_ratio_ordering():
    with pytest.raises(ay.InvalidInputError, match="max_distance_ratio"):
        ay.MatchConfig(min_distance_ratio=2.0, max_distance_ratio=1.0)


def test_runtime_distances_durations_and_speeds_are_validated():
    track = ay.Track([point(0), point(1000, 47.001, 8.001)])
    replay = ay.ReplaySession([ay.GpsFix(i * 1000, 47.0, 8.0) for i in range(4)])
    recorder = ay.LiveRecorder()

    with pytest.raises(ay.InvalidInputError):
        track.resample_by_distance(0.0)
    with pytest.raises(ay.InvalidInputError):
        track.resample_by_distance(math.nan)
    with pytest.raises(ay.InvalidInputError):
        recorder.seed(-1.0, 0.0)
    with pytest.raises(ay.InvalidInputError):
        replay.seek(-1.0)
    with pytest.raises(ay.InvalidInputError):
        replay.advance(-1.0)
    with pytest.raises(ay.InvalidInputError):
        replay.set_speed(0.0)


def test_pathlike_gpx_roundtrip(tmp_path: Path):
    source = ay.Track.from_gpx(
        gpx(
            (47.37690, 8.54170, "2024-01-01T10:00:00Z"),
            (47.37710, 8.54190, "2024-01-01T10:00:20Z"),
        )
    )
    target = tmp_path / "roundtrip.gpx"

    source.to_gpx_path(target)
    reloaded = ay.Track.from_gpx_path(target)

    assert reloaded.point_count == source.point_count
    assert reloaded.coordinates() == source.coordinates()


def test_large_coordinate_jump_is_accepted():
    jumped = ay.Track.from_gpx(
        gpx(
            (60.1699, 24.9384, "2024-01-01T00:00:00Z"),
            (-33.8688, 151.2093, "2024-01-01T00:00:01Z"),
        )
    )
    assert jumped.point_count == 2
    assert jumped.distance_m > 1_000_000.0


def test_empty_and_single_point_tracks_are_rejected():
    with pytest.raises(ay.TrackError):
        ay.Track([])
    with pytest.raises(ay.TrackError):
        ay.Track([point(0)])


def test_duplicate_timestamp_sequence_rejects_only_the_regression():
    # Non-decreasing timestamps are the engine invariant, so exact duplicates
    # are valid; a later point moving backwards in time is not.
    duplicated = ay.Track([point(1000), point(1000)])
    assert duplicated.point_count == 2

    with pytest.raises(ay.TrackError, match="monotonic"):
        ay.Track([point(1000), point(1000), point(999)])


def test_non_monotonic_attempt_samples_are_rejected():
    with pytest.raises(ay.AttemptError):
        ay.Attempt.from_samples([])
    with pytest.raises(ay.AttemptError):
        ay.Attempt.from_samples(
            [ay.AttemptSample(10.0, 1.0), ay.AttemptSample(5.0, 2.0)]
        )
    with pytest.raises(ay.AttemptError):
        ay.Attempt.from_samples(
            [ay.AttemptSample(0.0, 10.0), ay.AttemptSample(5.0, 5.0)]
        )
