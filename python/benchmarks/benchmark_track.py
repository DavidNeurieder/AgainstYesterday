#!/usr/bin/env python3
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Skeleton wall-time benchmark for the against_yesterday track pipeline.

Run from the repository root after ``make python-develop``::

    python/.venv/bin/python python/benchmarks/benchmark_track.py

Stdlib-only and assertion-free: deterministic synthetic tracks are generated,
each operation is timed with ``time.perf_counter``, and wall time plus the
process peak RSS (where available) are printed. Numbers are environment-specific;
keep the version banner together with any results you record.
"""

from __future__ import annotations

import argparse
import gc
import math
import platform
import sys
import time
from pathlib import Path

try:  # ``resource`` is POSIX-only; the script still runs where it is missing.
    import resource
except ImportError:  # pragma: no cover - non-POSIX hosts
    resource = None  # type: ignore[assignment]

# Allow the in-tree package (which holds the compiled extension) to be imported
# even when maturin's editable install is not on sys.path.
_PYTHON_DIR = Path(__file__).resolve().parents[1]
if str(_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(_PYTHON_DIR))

try:
    import against_yesterday as ay
except ImportError as exc:  # pragma: no cover - depends on environment setup
    raise SystemExit(
        "Cannot import against_yesterday; run 'make python-develop' from the "
        "repository root first."
    ) from exc


DEFAULT_SIZES = (100, 10_000, 100_000)
MILLION = 1_000_000

BASE_LAT = 47.3769
BASE_LON = 8.5417
BASE_TIME_MS = 1_700_000_000_000
STEP_MS = 1_000
RESAMPLE_INTERVAL_M = 10.0
SIMPLIFY_TOLERANCE_M = 2.0


def build_track(size: int) -> ay.Track:
    """Create ``size`` deterministic points and hand them to ``ay.Track``.

    Points are generated straight into the single list the constructor needs;
    no second copy (for example a GPX string or a snapshot list) is kept.
    """
    points = []
    for i in range(size):
        points.append(
            ay.TrackPoint(
                BASE_LAT + i * 0.00001 + 0.00002 * math.sin(i / 50.0),
                BASE_LON + i * 0.000015 + 0.00002 * math.cos(i / 70.0),
                BASE_TIME_MS + i * STEP_MS,
                altitude_m=400.0 + 3.0 * math.sin(i / 300.0),
                speed_mps=3.0,
                accuracy_m=5.0,
                bearing_deg=45.0,
            )
        )
    track = ay.Track(points)
    del points
    return track


def peak_rss_mib() -> float | None:
    """Process-wide peak RSS, or ``None`` when the platform cannot report it."""
    if resource is None:
        return None
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":  # macOS reports bytes, Linux reports KiB.
        return rss / (1024 * 1024)
    return rss / 1024


def rss_label() -> str:
    rss = peak_rss_mib()
    return "n/a" if rss is None else f"{rss:8.1f} MiB"


def print_versions() -> None:
    print("== toolchain ==")
    print(f"  against_yesterday: {getattr(ay, '__version__', 'unknown')}")
    print(f"  python:            {platform.python_version()} ({sys.executable})")
    print(f"  implementation:    {platform.python_implementation()}")
    print(f"  platform:          {platform.platform()}")
    print(f"  machine:           {platform.machine()}")
    print(
        "  peak RSS source:   "
        + ("none (no resource module)" if resource is None else "resource.getrusage(RUSAGE_SELF)")
    )
    print()


def time_call(label: str, fn, repeat: int, *args):
    """Time ``fn(*args)`` ``repeat`` times and return the last result.

    Returning the last result lets a caller time a producer (``to_gpx``) and
    feed its output into the next timed call (``parse_gpx``) without holding two
    copies. Callers that ignore the return value release it immediately.
    """
    elapsed = []
    last = None
    try:
        for _ in range(repeat):
            gc.collect()  # outside the timed window, to reduce noise
            start = time.perf_counter()
            last = fn(*args)
            elapsed.append(time.perf_counter() - start)
    except Exception as exc:  # keep the other cases running
        print(f"  {label:<22} ERROR {type(exc).__name__}: {exc}")
        return None
    best_ms = min(elapsed) * 1000.0
    mean_ms = (sum(elapsed) / len(elapsed)) * 1000.0
    print(
        f"  {label:<22} best={best_ms:9.3f} ms  "
        f"mean={mean_ms:9.3f} ms  peak_rss={rss_label()}"
    )
    return last


def iterate_track(track: ay.Track) -> float:
    """Stream through the native iterator; avoids materialising ``points()``."""
    total = 0.0
    for point in track:
        total += point.latitude
    return total


def benchmark_size(size: int, repeat: int) -> None:
    print(f"== size={size:,} points ==")
    track = build_track(size)
    print(
        f"  construction:      points={track.point_count:,} "
        f"distance={track.distance_m:.1f} m  peak_rss={rss_label()}"
    )

    time_call("filter", ay.Track.filter, repeat, track)
    time_call("simplify", ay.Track.simplify, repeat, track, SIMPLIFY_TOLERANCE_M)
    time_call(
        "resample_by_distance",
        ay.Track.resample_by_distance,
        repeat,
        track,
        RESAMPLE_INTERVAL_M,
    )
    time_call("analytics", ay.Track.analytics, repeat, track)

    # Time the writer, then reuse its last result for the parse case so only
    # one GPX string is alive at a time.
    gpx = time_call("to_gpx", ay.Track.to_gpx, repeat, track)
    if gpx is not None:
        time_call("parse_gpx", ay.parse_gpx, repeat, gpx)
        gpx = None

    time_call("track iteration", iterate_track, repeat, track)
    print()
    # Local temporaries are released when this function returns.


def parse_sizes(groups: list[str] | None, include_million: bool) -> list[int]:
    raw = ",".join(groups) if groups else ""
    sizes: list[int] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            value = int(part)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"invalid size: {part!r}") from exc
        if value <= 0:
            raise argparse.ArgumentTypeError(f"sizes must be positive, got {value}")
        sizes.append(value)
    if include_million and MILLION not in sizes:
        sizes.append(MILLION)
    # Preserve the order given, de-duplicated; fall back to the defaults.
    result = list(dict.fromkeys(sizes))
    return sorted(result) if result else sorted(DEFAULT_SIZES)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--sizes",
        action="append",
        metavar="N[,N...]",
        help="comma-separated sample counts per track (repeatable); "
        f"default {','.join(str(n) for n in DEFAULT_SIZES)}",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=3,
        help="timed repetitions per case (default: 3)",
    )
    parser.add_argument(
        "--include-million",
        action="store_true",
        help=f"also run the {MILLION:,}-sample case (skipped by default)",
    )
    parser.add_argument(
        "--versions",
        action="store_true",
        help="print toolchain versions and exit",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    print_versions()
    if args.versions:
        return 0
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")

    sizes = parse_sizes(args.sizes, args.include_million)
    print("== configuration ==")
    print(f"  sizes:     {', '.join(f'{n:,}' for n in sizes)}")
    print(f"  repeat:    {args.repeat}")
    print(f"  interval:  {RESAMPLE_INTERVAL_M:g} m, tolerance: {SIMPLIFY_TOLERANCE_M:g} m")
    print()

    for size in sizes:
        benchmark_size(size, args.repeat)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
