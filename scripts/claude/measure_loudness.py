"""Report each sound's momentary loudness (ITU-R BS.1770: K-weighted, loudest
400 ms) and peak, independently of z-iris's own measure, as a check on it.

Date: 2026-10-28
Usage: uv run --with numpy --with scipy --with soundfile scripts/claude/measure_loudness.py DIR [TARGET_LUFS]
Prints one line per WAV; marks a sound more than 0.5 dB short of the target
(a peak at full scale means it was held back from clipping).
"""

from __future__ import annotations

import glob
import math
import sys

import numpy as np
import soundfile
from scipy.signal import lfilter


def k_weighting(rate: float):
    """libebur128's formulas, which give BS.1770's 48 kHz coefficients."""
    f0, q = 1681.974450955533, 0.7071752369554196
    k = math.tan(math.pi * f0 / rate)
    vh = 10 ** (3.999843853973347 / 20)
    vb = vh ** 0.4996667741545416
    a0 = 1 + k / q + k * k
    shelf = ([(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
             [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    f0, q = 38.13547087602444, 0.5003270373238773
    k = math.tan(math.pi * f0 / rate)
    a0 = 1 + k / q + k * k
    high_pass = ([1, -2, 1], [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    return shelf, high_pass


def loudness(path: str) -> tuple[float, float, float]:
    data, rate = soundfile.read(path, always_2d=True)
    channels = data.T
    length = channels.shape[1]
    energy = np.zeros(length + 1)
    for channel in channels:
        weighted = channel
        for b, a in k_weighting(rate):
            weighted = lfilter(b, a, weighted)
        energy[1:] += np.cumsum(weighted * weighted)
    window, hop = int(0.4 * rate), int(0.01 * rate)
    loudest, start = 0.0, 0
    while True:
        end = min(start + window, length)
        loudest = max(loudest, (energy[end] - energy[start]) / window)
        start += hop
        if start + window > length:
            break
    lufs = -0.691 + 10 * math.log10(loudest) if loudest > 0 else -math.inf
    return lufs, float(np.abs(channels).max()), length / rate


def main() -> None:
    target = float(sys.argv[2]) if len(sys.argv) > 2 else -13.0
    short = 0
    for path in sorted(glob.glob(sys.argv[1].rstrip("/") + "/*.wav")):
        lufs, peak, seconds = loudness(path)
        mark = ""
        if lufs < target - 0.5:
            short += 1
            mark = "  short (peak-limited)" if peak > 0.97 else "  SHORT"
        name = path.rsplit("/", 1)[-1][:-4]
        print(f"{name:20s} {lufs:7.2f} LUFS  peak {peak:.3f}  {seconds:.2f} s{mark}")
    print(f"{short} short of {target} LUFS")


if __name__ == "__main__":
    main()
