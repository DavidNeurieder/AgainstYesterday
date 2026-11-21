# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Expensive pure computations stay deterministic when run across threads."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import against_yesterday as ay


def make_track(offset: int) -> ay.Track:
    return ay.Track(
        [
            ay.TrackPoint(
                47.0 + offset * 0.001 + i * 0.0001,
                8.0 + i * 0.00005,
                i * 1000,
            )
            for i in range(6)
        ]
    )


def compute(index: int):
    track = make_track(index)
    score = ay.compare_tracks(track, track)
    analytics = track.analytics()
    return (
        index,
        track.distance_m,
        score.overall_score,
        analytics.distance_m,
        analytics.quality.accepted_samples,
        analytics.to_json(),
    )


def test_thread_pool_results_match_sequential_results():
    indices = list(range(8))
    expected = [compute(index) for index in indices]

    with ThreadPoolExecutor(max_workers=4) as executor:
        concurrent = list(executor.map(compute, indices))

    assert concurrent == expected
