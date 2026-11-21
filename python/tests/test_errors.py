# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Domain exceptions and string-enum compatibility."""

from __future__ import annotations

from pathlib import Path

import pytest

import against_yesterday as ay
from against_yesterday import enums, errors


def test_exception_hierarchy_and_reexport_identity():
    assert errors.EngineError.__mro__[1:3] == (
        errors.AgainstYesterdayError,
        ValueError,
    )
    assert issubclass(ay.EngineError, ValueError)
    assert issubclass(ay.InvalidInputError, ay.EngineError)
    assert issubclass(ay.ParseError, ay.GpxError)
    assert issubclass(ay.GpxWriteError, ay.GpxError)
    assert issubclass(ay.CanonicalizationError, ay.RouteError)

    for name in errors.__all__:
        assert getattr(ay, name) is getattr(errors, name)


def test_malformed_gpx_raises_parse_error(tmp_path: Path):
    with pytest.raises(ay.ParseError):
        ay.parse_gpx("<gpx><trk>")
    with pytest.raises(ay.ParseError):
        ay.Track.from_gpx_path(tmp_path / "does-not-exist.gpx")


def test_invalid_write_target_raises_gpx_write_error(tmp_path: Path):
    track = ay.Track(
        [
            ay.TrackPoint(47.0, 8.0, 0),
            ay.TrackPoint(47.001, 8.001, 1000),
        ]
    )
    with pytest.raises(ay.GpxWriteError):
        track.to_gpx_path(tmp_path)


@pytest.mark.parametrize(
    "tracks",
    [
        [],
        [
            ay.Track(
                [
                    ay.TrackPoint(47.0, 8.0, 0),
                    ay.TrackPoint(47.0, 8.0, 1000),
                ]
            )
        ],
    ],
)
def test_bad_canonicalize_input_raises_canonicalization_error(tracks):
    with pytest.raises(ay.CanonicalizationError):
        ay.canonicalize_route(tracks)


def test_enum_members_equal_plain_strings():
    assert isinstance(enums.AttemptAxis.CLOCK, str)
    assert enums.AttemptAxis.CLOCK == "clock"
    assert enums.AttemptAxis.MOVING == "moving"
    assert enums.LiveMatchStatus.MATCHED == "matched"
    assert enums.LiveMatchStatus.OFF_ROUTE == "off_route"
    assert enums.ReplayState.PLAYING == "playing"
    assert enums.ReplayState.FINISHED == "finished"


def test_plain_strings_and_enum_members_are_both_accepted_as_axis():
    track = ay.Track(
        [
            ay.TrackPoint(52.5, 13.4, 0),
            ay.TrackPoint(52.5005, 13.4, 10_000),
            ay.TrackPoint(52.501, 13.4, 20_000),
        ]
    )
    route = ay.Route(track.coordinates())

    clock = ay.Attempt.from_track(track, route, axis="clock")
    enum_clock = ay.Attempt.from_track(track, route, axis=enums.AttemptAxis.CLOCK)
    moving = ay.Attempt.from_track(track, route, axis=enums.AttemptAxis.MOVING)

    assert clock.elapsed_time_s == enum_clock.elapsed_time_s
    assert moving.distance_m == pytest.approx(clock.distance_m)
