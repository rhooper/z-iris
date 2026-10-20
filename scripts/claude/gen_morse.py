"""Generate the "sos" bundled tone: SOS as a 1910s spark-gap wireless operator
sent it.

SOS is a prosign: ...---... run together, without the gaps between letters.
Standard Morse timing: a dash is three dots, a one-dot gap inside the sign, a
seven-dot gap between repeats. About 18 words per minute.

A spark transmitter's note was not a clean beep: the receiver heard the spark
rate (here 600 a second) as a raspy, buzzy tone, each spark a short ringing
burst, slightly irregular, with a little crackle.

Date: 2026-10-20
Usage: uv run python scripts/claude/gen_morse.py   (from the repo root)
Then: uv run z-iris normalize --dir src/z_iris/sounds --no-backup
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
WPM = 18
DOT = 1.2 / WPM  # seconds, the PARIS standard
SPARKS_PER_SECOND = 600
RING_HZ = 1800  # each spark rings briefly at this pitch
RING_DECAY = 0.0006  # seconds
RAMP = 0.004  # soft keying edges, so the key does not click
OUT = Path(__file__).resolve().parents[2] / "src" / "z_iris" / "sounds" / "sos.wav"


def keying(pattern: str, repeats: int) -> list[tuple[float, float]]:
    """(start, length) of each mark for the prosign, repeated."""
    marks, t = [], 0.0
    for r in range(repeats):
        for i, symbol in enumerate(pattern):
            length = DOT if symbol == "." else 3 * DOT
            marks.append((t, length))
            t += length + (DOT if i < len(pattern) - 1 else 0)
        if r < repeats - 1:
            t += 7 * DOT
    return marks


def spark(seconds: float, rng: random.Random) -> list[float]:
    """The buzzy spark note: a train of damped ringing bursts."""
    out = [0.0] * int(seconds * RATE)
    t = 0.0
    while t < seconds:
        start = int(t * RATE)
        strength = 0.8 + 0.4 * rng.random()
        for n in range(int(6 * RING_DECAY * RATE)):
            if start + n >= len(out):
                break
            x = n / RATE
            out[start + n] += strength * math.exp(-x / RING_DECAY) * math.sin(2 * math.pi * RING_HZ * x)
        t += (1 + 0.08 * (rng.random() - 0.5)) / SPARKS_PER_SECOND  # slightly irregular
    return [v + 0.06 * (rng.random() - 0.5) for v in out]  # crackle


def main() -> None:
    rng = random.Random(1912)  # the same file every time
    marks = keying("...---...", repeats=2)
    total = marks[-1][0] + marks[-1][1] + 0.05
    track = [0.0] * int(total * RATE)
    for start, length in marks:
        note = spark(length, rng)
        ramp = int(RAMP * RATE)
        for i, value in enumerate(note):
            gain = min(1.0, i / ramp, (len(note) - 1 - i) / ramp)
            track[int(start * RATE) + i] += value * gain
    peak = max(abs(v) for v in track) or 1.0
    with wave.open(str(OUT), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", int(v / peak * 0.708 * 32767)) for v in track))
    print(f"wrote {OUT} ({total:.2f} s)")


if __name__ == "__main__":
    main()
