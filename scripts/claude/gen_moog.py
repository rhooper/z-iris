"""Generate the "moog-a" bundled tone: one Minimoog-style eighth note on A4.

The Minimoog is subtractive: raw oscillators through its 24 dB/octave ladder
low-pass filter. Here two slightly detuned sawtooths and a square an octave
down (band-limited with polyBLEP, so no aliasing whine), a four-pole ladder
filter with some resonance whose cutoff sweeps from bright to warm, and a
punchy amp envelope, all driven hard into saturation. A4 (440 Hz), gate
250 ms (an eighth note at 120 bpm), then a short release.

Date: 2026-10-20
Usage: uv run python scripts/claude/gen_moog.py   (from the repo root)
Then: uv run z-iris normalize --dir src/z_iris/sounds --no-backup
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 44100
NOTE_HZ = 440.0
GATE = 0.25  # seconds the key is down
RELEASE = 0.05
DRIVE = 4.0  # into the filter; 1.0 is clean
OUT = Path(__file__).resolve().parents[2] / "src" / "z_iris" / "sounds" / "moog-a.wav"


def blep(t: float, dt: float) -> float:
    """polyBLEP correction near a waveform's jump, for band-limited edges."""
    if t < dt:
        t /= dt
        return t + t - t * t - 1.0
    if t > 1.0 - dt:
        t = (t - 1.0) / dt
        return t * t + t + t + 1.0
    return 0.0


class Oscillator:
    def __init__(self, hz: float, shape: str) -> None:
        self.phase, self.dt, self.shape = 0.0, hz / RATE, shape

    def next(self) -> float:
        p, dt = self.phase, self.dt
        if self.shape == "saw":
            value = 2.0 * p - 1.0 - blep(p, dt)
        else:  # square
            value = (1.0 if p < 0.5 else -1.0) + blep(p, dt) - blep((p + 0.5) % 1.0, dt)
        self.phase = (p + dt) % 1.0
        return value


class Ladder:
    """A four-pole (24 dB/octave) low-pass with resonance, Moog style
    (Stilson/Smith model with a tanh drive for the warmth)."""

    def __init__(self) -> None:
        self.stages = [0.0] * 4

    def next(self, x: float, cutoff_hz: float, resonance: float, drive: float = 1.0) -> float:
        g = 1.0 - math.exp(-2.0 * math.pi * cutoff_hz / RATE)
        # drive pushes the input into the saturating stage, as cranking the
        # Minimoog's oscillator mixer levels overdrives its filter
        x = math.tanh(drive * x - 4.0 * resonance * self.stages[3])
        for i in range(4):
            self.stages[i] += g * (math.tanh(x) - self.stages[i])
            x = self.stages[i]
        return x


def envelope(t: float, attack: float, decay: float, sustain: float, release: float) -> float:
    """ADSR, the key held for GATE seconds."""
    if t < attack:
        level = t / attack
    else:
        level = sustain + (1.0 - sustain) * math.exp(-(t - attack) / decay)
    if t > GATE:
        held = envelope(GATE, attack, decay, sustain, release) if t - GATE > 0 else level
        return held * math.exp(-(t - GATE) / release)
    return level


def main() -> None:
    oscillators = [Oscillator(NOTE_HZ, "saw"), Oscillator(NOTE_HZ * 1.003, "saw"),
                   Oscillator(NOTE_HZ / 2, "square")]
    levels = (0.45, 0.45, 0.3)
    ladder = Ladder()
    track = []
    for n in range(int((GATE + RELEASE) * RATE)):
        t = n / RATE
        mix = sum(level * osc.next() for level, osc in zip(levels, oscillators))
        sweep = envelope(t, 0.002, 0.09, 0.25, 0.04)  # the filter envelope
        cutoff = 350.0 + 4200.0 * sweep
        voice = ladder.next(mix, cutoff, resonance=0.35, drive=DRIVE)
        voice = math.tanh(2.5 * voice)  # and a hot output stage
        track.append(voice * envelope(t, 0.003, 0.2, 0.8, 0.03))
    fade = int(0.01 * RATE)
    for i in range(fade):
        track[-fade + i] *= 1.0 - i / fade
    peak = max(abs(v) for v in track) or 1.0
    with wave.open(str(OUT), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", int(v / peak * 0.708 * 32767)) for v in track))
    print(f"wrote {OUT} ({len(track) / RATE:.2f} s)")


if __name__ == "__main__":
    main()
