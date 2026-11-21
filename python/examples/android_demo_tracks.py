#!/usr/bin/env python3
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Example: analyze and compare the bundled Android demo GPS tracks.

Uses the example GPX recordings shipped with the app in
`app/assets/examples/` (Cycling Finland, 4 runs of the same course).

GPS data: GeoPrivacy (2023), CC BY 4.0. See
`app/assets/examples/licenses/` and `app/assets/examples/manifest.json` for
attribution details.

Prerequisites:
    Build/install the bindings first, e.g. from the repository root:
        make python-develop
    or:
        cd python && maturin develop
"""

from __future__ import annotations

from pathlib import Path

import against_yesterday as ay


def repo_root() -> Path:
    # python/examples/android_demo_tracks.py -> repo root
    return Path(__file__).resolve().parents[2]


def load_demo_tracks() -> list[tuple[str, ay.Track]]:
    examples_dir = repo_root() / "app" / "assets" / "examples"
    paths = sorted(examples_dir.glob("cycling_finland_*.gpx"))
    if not paths:
        raise SystemExit(f"No demo GPX files found in {examples_dir}")

    tracks: list[tuple[str, ay.Track]] = []
    for path in paths:
        track = ay.Track.from_gpx_path(str(path))
        tracks.append((path.name, track))
    return tracks


def fmt_duration(seconds: float) -> str:
    minutes, secs = divmod(int(round(seconds)), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:d}:{secs:02d}"


def print_track_summaries(tracks: list[tuple[str, ay.Track]]) -> None:
    print("== Demo tracks (app/assets/examples, Cycling Finland) ==")
    print("Attribution: GPS data GeoPrivacy (2023), CC BY 4.0\n")
    for name, track in tracks:
        analytics = track.analytics()
        avg_kmh = (
            analytics.average_speed_mps * 3.6
            if analytics.average_speed_mps is not None
            else track.average_speed_mps * 3.6
        )
        print(f"{name}")
        print(
            f"  points={track.point_count}  "
            f"distance={track.distance_m / 1000:.2f} km  "
            f"duration={fmt_duration(track.duration_s)}  "
            f"avg={avg_kmh:.1f} km/h"
        )
        if analytics.elevation_gain_m is not None:
            print(
                f"  elevation gain={analytics.elevation_gain_m:.1f} m  "
                f"loss={analytics.elevation_loss_m:.1f} m"
            )
    print()


def compare_runs(tracks: list[tuple[str, ay.Track]]) -> None:
    # Use the first recording as the reference route/course.
    ref_name, ref_track = tracks[0]
    route = ay.Route(ref_track.coordinates())
    print(f"== Route/attempt comparison (route from {ref_name}) ==")
    print(f"Route length: {route.length_m / 1000:.2f} km\n")

    attempts: list[tuple[str, ay.Attempt]] = []
    for name, track in tracks:
        attempt = ay.Attempt.from_track(track, route)
        attempts.append((name, attempt))
        pace = (
            attempt.elapsed_time_s / (attempt.distance_m / 1000.0)
            if attempt.distance_m > 0
            else float("nan")
        )
        print(
            f"{name}: matched={attempt.distance_m / 1000:.2f} km in "
            f"{fmt_duration(attempt.elapsed_time_s)} ({pace:.1f} s/km equiv over route distance)"
        )

    # Compare every run against the fastest attempt (ghost/reference).
    fastest_name, fastest = min(attempts, key=lambda item: item[1].elapsed_time_s)
    print(f"\nFastest: {fastest_name} ({fmt_duration(fastest.elapsed_time_s)})")

    for name, attempt in attempts:
        if name == fastest_name:
            continue
        comparison = ay.compare_performances(fastest, attempt)
        ghost = ay.Ghost(fastest, attempt)
        state = ghost.state_at_distance(min(fastest.distance_m, attempt.distance_m))
        delta = comparison.total_time_difference_s
        ahead = "behind" if delta > 0 else "ahead"
        print(
            f"  vs {name}: {abs(delta):.1f}s {ahead} overall"
            + (
                f", {state.time_difference_s:+.1f}s at matched distance"
                if state is not None
                else ""
            )
        )
    print()


def match_and_catalog(tracks: list[tuple[str, ay.Track]]) -> None:
    print("== Route matching / catalog ==")
    if len(tracks) >= 2:
        score = ay.compare_tracks(tracks[0][1], tracks[1][1])
        either = ay.compare_tracks_either_direction(tracks[0][1], tracks[1][1])
        print(
            f"Track 1 vs 2: overall={score.overall_score:.3f} "
            f"overlap={score.spatial_overlap:.3f} "
            f"direction={score.direction_similarity:.3f} "
            f"continuity={score.continuity:.3f} match={score.is_match()}"
        )
        if either is not None:
            print(
                "  either-direction match: "
                f"{either.is_match()} (overall={either.overall_score:.3f})"
            )

    catalog = ay.RouteCatalog()
    for name, track in tracks:
        addition = catalog.add_track(track)
        status = "new route" if addition.is_new else f"matched route {addition.route_id}"
        if addition.matched is not None:
            status += f" (overall={addition.matched.overall_score:.3f})"
        print(f"  {name}: {status}")
    print(f"Discovered routes: {catalog.route_count()}")

    try:
        canonical = ay.canonicalize_route([track for _, track in tracks])
        print(f"Canonicalized route length: {canonical.length_m / 1000:.2f} km")
    except Exception as exc:  # engine may reject if inputs are inconsistent
        print(f"Canonicalization skipped: {exc}")
    print()


def main() -> None:
    tracks = load_demo_tracks()
    print_track_summaries(tracks)
    compare_runs(tracks)
    match_and_catalog(tracks)


if __name__ == "__main__":
    main()
