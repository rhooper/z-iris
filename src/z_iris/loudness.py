"""Store every sound at the same loudness, so one volume means one loudness."""

from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
from pathlib import Path

from z_iris.sounds import SUFFIXES

# RMS level a stored sound has at 100% volume. Quiet files are raised to it and
# loud ones lowered, but never so far that the peak would clip.
TARGET_RMS = 0.38
# Files already this close to the target are left alone, so running it twice
# changes nothing.
TOLERANCE_DB = 0.5

_PEAK = re.compile(r"Maximum amplitude:\s+([0-9.]+)")
_RMS = re.compile(r"RMS\s+amplitude:\s+([0-9.]+)")


def parse_stat(text: str) -> tuple[float, float] | None:
    """Peak and RMS from the output of sox's stat effect."""
    peak, rms = _PEAK.search(text), _RMS.search(text)
    if not peak or not rms:
        return None
    return float(peak.group(1)), float(rms.group(1))


def levels(path: Path) -> tuple[float, float] | None:
    try:
        result = subprocess.run(
            ["sox", str(path), "-n", "stat"],
            capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_stat(result.stderr)


def gain_for(peak: float, rms: float) -> float:
    if peak <= 0 or rms <= 0:
        return 1.0
    return min(TARGET_RMS / rms, 1.0 / peak)


def write_normalized(source: Path, destination: Path) -> float:
    """Write source to destination as a 16-bit wav at the target loudness."""
    measured = levels(source)
    gain = gain_for(*measured) if measured else 1.0
    result = subprocess.run(
        ["sox", str(source), "-b", "16", str(destination), "vol", f"{gain:.6f}"],
        capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        raise RuntimeError(f"sox could not convert {source.name}: {result.stderr.strip()}")
    return gain


def normalize_file(path: Path, originals: Path | None) -> tuple[Path, bool]:
    """Replace a sound with a normalized wav. Returns (file now, whether it changed).

    The original is moved into originals (when given) before it is replaced. A
    file already at the target loudness is left untouched.
    """
    measured = levels(path)
    if measured is None:
        return path, False
    gain = gain_for(*measured)
    if path.suffix.lower() == ".wav" and abs(20 * math.log10(gain)) < TOLERANCE_DB:
        return path, False
    temporary = path.with_name(f".normalize-{path.stem}.wav")
    try:
        write_normalized(path, temporary)
        if originals is not None:
            originals.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, originals / path.name)
        final = path.with_suffix(".wav")
        if path != final:
            path.unlink()
        os.replace(temporary, final)
    finally:
        if temporary.exists():
            temporary.unlink()
    return final, True


def normalize_directory(
    directory: Path, keep_originals: bool = True
) -> list[tuple[Path, Path]]:
    """Normalize every sound in a folder. Returns (before, after) for changed ones."""
    changed = []
    if not directory.is_dir():
        return changed
    originals = directory / "originals" if keep_originals else None
    for path in sorted(directory.iterdir()):
        if not path.is_file() or path.suffix.lower() not in SUFFIXES:
            continue
        final, did_change = normalize_file(path, originals)
        if did_change:
            changed.append((path, final))
    return changed
