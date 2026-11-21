# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Small compatibility helpers used by the compiled extension.

Simple accessors are properties in the public API.  Returning these ``float``
and ``str`` subclasses from the binding keeps the pre-property method-call form
working for one release: ``recorder.distance_m`` and ``recorder.distance_m()``
both produce the same number.
"""

from __future__ import annotations


class CallableFloat(float):
    """A ``float`` that can also be called like the old accessor method."""

    def __call__(self) -> float:
        return float(self)


class CallableStr(str):
    """A ``str`` that can also be called like the old accessor method."""

    def __call__(self) -> str:
        return str.__str__(self)


__all__ = ["CallableFloat", "CallableStr"]
