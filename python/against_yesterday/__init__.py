# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Python bindings for the Against Yesterday GPS engine."""

from ._native import (
    EngineError,
    FilterConfig,
    GeoError,
    GpxError,
    MovingConfig,
    ProcessingReport,
    SimplifyConfig,
    Track,
    TrackError,
    TrackPoint,
    __version__ as _native_version,
    parse_gpx,
)

__version__ = _native_version

__all__ = [
    "EngineError",
    "FilterConfig",
    "GeoError",
    "GpxError",
    "MovingConfig",
    "ProcessingReport",
    "SimplifyConfig",
    "Track",
    "TrackError",
    "TrackPoint",
    "__version__",
    "parse_gpx",
]
