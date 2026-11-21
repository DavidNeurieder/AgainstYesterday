#!/usr/bin/env python3
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Skeleton wall-time benchmark for the against_yesterday matching APIs.

Run from the repository root after ``make python-develop``::

    python/.venv/bin/python python/benchmarks/benchmark_matching.py

One deterministic reference track and ``--variants`` perturbed variants are
built per size. The script is stdlib-only and assertion-free: it reports wall
time (``time.perf_counter``) and process peak RSS where available. Numbers are
environment-specific; keep the version banner together with any results you
record.
"""

from __future__ import annotations

import argparse
import gc
import math
import platform
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from functools import partial
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
DEFAULT_VARIANTS = 4
DEFAULT_WORKERS = 4

BASE_LAT = 47.3769
BASE_LON = 8.5417
BASE_TIME_MS = 1_700_000_000_000
STEP_MS = 1_000


def build_track(size: int, seed: int = 0) -> ay.Track:
    """Build a deterministic track; ``seed=0`` is the reference, others vary.

    Perturbations are small and bounded so variants remain plausible repeats of
    the same course (within the default matcher's lateral tolerance).
    """
    lat_shift = (seed % 5) * 0.000004
    lon_shift = ((seed // 5) % 5) * 0.000004
    points = []
    for i in range(size):
        points.append(
            ay.TrackPoint(
                BASE_LAT
                + i * 0.00001
                + 0.00002 * math.sin(i / 50.0)
                + lat_shift
                + 0.000002 * math.sin((i + seed) / 37.0),
                BASE_LON
                + i * 0.000015
                + 0.00002 * math.cos(i / 70.0)
                + lon_shift
                + 0.000002 * math.cos((i + seed) / 41.0),
                BASE_TIME_MS + (i + seed) * STEP_MS,
                speed_mps=3.0,
                accuracy_m=5.0,
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

    Returning the last result lets callers chain timed calls without keeping
    extra copies; callers that ignore it release it immediately.
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
        print(f"  {label:<30} ERROR {type(exc).__name__}: {exc}")
        return None
    best_ms = min(elapsed) * 1000.0
    mean_ms = (sum(elapsed) / len(elapsed)) * 1000.0
    print(
        f"  {label:<30} best={best_ms:9.3f} ms  "
        f"mean={mean_ms:9.3f} ms  peak_rss={rss_label()}"
    )
    return last


def compare_pair(pair: tuple[ay.Track, ay.Track], config: ay.MatchConfig) -> ay.MatchScore:
    """Compare one queued track pair; used by the thread-pool case."""
    return ay.compare_tracks(pair[0], pair[1], config)


def concurrent_compares(
    pairs: list[tuple[ay.Track, ay.Track]], config: ay.MatchConfig, workers: int
) -> list:
    """Fan the queued pairs out over ``workers`` threads."""
    compare = partial(compare_pair, config=config)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        return list(executor.map(compare, pairs))


def benchmark_size(size: int, variants: int, repeat: int, workers: int) -> None:
    print(f"== size={size:,} points, variants={variants} ==")
    reference = build_track(size, seed=0)
    perturbed = [build_track(size, seed=index + 1) for index in range(variants)]
    route = ay.Route(reference.coordinates())

    # Attempts are setup for compare_performances, not part of its timed call.
    reference_attempt = ay.Attempt.from_track(reference, route)
    variant_attempt = ay.Attempt.from_track(perturbed[0], route)
    config = ay.MatchConfig()
    print(
        f"  construction:      route={route.length_m:.1f} m  "
        f"peak_rss={rss_label()}"
    )

    target = perturbed[0]
    time_call("compare_tracks", ay.compare_tracks, repeat, reference, target, config)
    time_call(
        "compare_tracks_either_direction",
        ay.compare_tracks_either_direction,
        repeat,
        reference,
        target,
        config,
    )
    time_call("canonicalize_route", ay.canonicalize_route, repeat, [reference] + perturbed)
    time_call(
        "compare_performances",
        ay.compare_performances,
        repeat,
        reference_attempt,
        variant_attempt,
    )

    # Concurrent-track scenario: keep at least one task per worker. The work
    # list is prepared before the timed window.
    pairs = [
        (reference, perturbed[index % variants]) for index in range(max(variants, workers))
    ]
    time_call(
        f"threadpool compare ({workers} workers)",
        concurrent_compares,
        repeat,
        pairs,
        config,
        workers,
    )
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
        "--variants",
        type=int,
        default=DEFAULT_VARIANTS,
        help=f"number of perturbed variants per size (default: {DEFAULT_VARIANTS})",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"thread count for the ThreadPoolExecutor case (default: {DEFAULT_WORKERS})",
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
    if args.variants < 1:
        parser.error("--variants must be at least 1")
    if args.workers < 1:
        parser.error("--workers must be at least 1")

    sizes = parse_sizes(args.sizes, args.include_million)
    print("== configuration ==")
    print(f"  sizes:     {', '.join(f'{n:,}' for n in sizes)}")
    print(f"  variants:  {args.variants}")
    print(f"  workers:   {args.workers}")
    print(f"  repeat:    {args.repeat}")
    print()

    for size in sizes:
        benchmark_size(size, args.variants, args.repeat, args.workers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
