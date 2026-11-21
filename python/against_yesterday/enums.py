# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""String enums accepted by the compiled extension.

Every member is a :class:`str` subclass, so existing call sites that pass plain
strings such as ``"clock"`` continue to work unchanged.
"""

from __future__ import annotations

from enum import Enum

from ._compat import CallableStr


class AttemptAxis(CallableStr, Enum):
    """Elapsed-time axis used when projecting a track onto a route."""

    CLOCK = "clock"
    MOVING = "moving"


class LiveMatchStatus(CallableStr, Enum):
    """Route-match state reported by live snapshots."""

    NONE = "none"
    INITIALIZING = "initializing"
    MATCHED = "matched"
    UNCERTAIN = "uncertain"
    OFF_ROUTE = "off_route"
    REACQUIRING = "reacquiring"


class ReplayState(CallableStr, Enum):
    """Playback state of :class:`~against_yesterday.ReplaySession`."""

    PLAYING = "playing"
    PAUSED = "paused"
    FINISHED = "finished"


__all__ = ["AttemptAxis", "LiveMatchStatus", "ReplayState"]
