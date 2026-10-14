"""Even out how loud each sound is, so one volume setting means one loudness."""

from __future__ import annotations

import re
import subprocess
import threading
from collections.abc import Callable
from pathlib import Path

# RMS level that a sound reaches at 100% volume. Quiet files are raised to it
# and loud ones lowered, but never so far that the peak would clip.
TARGET_RMS = 0.38

_PEAK = re.compile(r"Maximum amplitude:\s+([0-9.]+)")
_RMS = re.compile(r"RMS\s+amplitude:\s+([0-9.]+)")


def parse_stat(text: str) -> tuple[float, float] | None:
    """Peak and RMS from the output of sox's stat effect."""
    peak, rms = _PEAK.search(text), _RMS.search(text)
    if not peak or not rms:
        return None
    return float(peak.group(1)), float(rms.group(1))


def measure(path: Path) -> tuple[float, float] | None:
    try:
        result = subprocess.run(
            ["sox", str(path), "-n", "stat"],
            capture_output=True, text=True, timeout=15, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_stat(result.stderr)


class Loudness:
    def __init__(self, measure: Callable[[Path], tuple[float, float] | None] = measure) -> None:
        self._measure = measure
        self._cache: dict[tuple[str, int], float] = {}
        self._lock = threading.Lock()

    def gain(self, path: Path) -> float:
        """The multiplier that brings this file to the target loudness."""
        try:
            key = (str(path), path.stat().st_mtime_ns)
        except OSError:
            return 1.0
        with self._lock:
            if key in self._cache:
                return self._cache[key]
        levels = self._measure(path)
        gain = 1.0
        if levels is not None:
            peak, rms = levels
            if peak > 0 and rms > 0:
                gain = min(TARGET_RMS / rms, 1.0 / peak)
        with self._lock:
            self._cache[key] = gain
        return gain
