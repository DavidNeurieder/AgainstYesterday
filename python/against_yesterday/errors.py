# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Python-facing exception hierarchy for :mod:`against_yesterday`.

The native extension maps Rust errors onto these types.  ``EngineError`` keeps
the historical ``ValueError`` base so existing ``except ValueError`` handlers
continue to work.
"""

from __future__ import annotations


class AgainstYesterdayError(Exception):
    """Base class for every exception raised by this package."""


class EngineError(AgainstYesterdayError, ValueError):
    """Base class for engine/domain errors (also a ``ValueError``).

    This class preserves the historical exception behavior of the bindings,
    where ``EngineError`` derived directly from :class:`ValueError`.
    """


class InvalidInputError(EngineError):
    """An argument failed binding-layer validation."""


class GeoError(EngineError):
    """A geographic value (coordinate, bearing, ...) is invalid."""


class TrackError(EngineError):
    """A track failed engine validation or processing."""


class GpxError(EngineError):
    """Base class for GPX read/write failures."""


class ParseError(GpxError):
    """A GPX document could not be parsed."""


class GpxWriteError(GpxError):
    """A track could not be serialized to GPX."""


class RouteError(EngineError):
    """A route could not be constructed or processed."""


class CanonicalizationError(RouteError):
    """A set of tracks could not be canonicalized into a route."""


class AttemptError(EngineError):
    """An attempt could not be constructed or queried."""


class ProcessingError(EngineError):
    """An engine operation failed for a reason other than invalid input."""


__all__ = [
    "AgainstYesterdayError",
    "EngineError",
    "InvalidInputError",
    "GeoError",
    "TrackError",
    "GpxError",
    "ParseError",
    "GpxWriteError",
    "RouteError",
    "CanonicalizationError",
    "AttemptError",
    "ProcessingError",
]
