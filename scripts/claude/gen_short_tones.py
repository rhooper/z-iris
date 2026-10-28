"""Generate short, middle-pitched bundled tones on many instruments: under
0.35 s, with a spectral centroid in the sound browser's middle band (420 to
650 Hz), so there are plenty of quick, unobtrusive notifications to choose
between. Each is one note, named instrument-note.

  guitar-a4      a plucked string (Karplus-Strong)
  harp-c5        a softer plucked string, longer-lived
  pizz-b4        a pizzicato violin: a short, damped pluck
  kalimba-d5     a thumb piano: a tine with its inharmonic overtone
  marimba-a4     a wooden bar: a strong fourth harmonic that dies at once
  vibes-c5       a vibraphone bar, metal, a little ring
  celesta-a4     struck metal plates, soft and bell-like
  musicbox-c5    a music-box comb tooth
  steelpan-b4    a steel pan note
  glass-a4       a struck wine glass
  woodblock-c5   a pitched woodblock
  ocarina-b4     a short, breathy toot
  fmbell-c5      a short two-operator FM bell
  synthpluck-a4  a subtractive synth pluck

Date: 2026-10-28
Usage: python3 scripts/claude/gen_short_tones.py [name ...]   (from the repo root)
Then: scripts/claude/level_sounds.sh
"""

from __future__ import annotations

import math
import struct
import sys
import wave

from gen_synths import OUT, RATE, SVF, additive, finish, fm, hz, noise, subtractive

LENGTH = 0.3  # seconds; the browser calls under 0.35 s short


def karplus(f: float, seconds: float, damping: float, brightness: float, seed: int) -> list[float]:
    """Karplus-Strong: a burst of noise in a delay line one period long,
    averaged a little each pass, rings like a plucked string."""
    period = RATE / f
    size = int(period)
    frac = period - size
    source = noise(seed)
    line = [next(source) for _ in range(size + 1)]
    smooth = SVF()
    line = [smooth.next(v, f * brightness, 0.7)[0] for v in line]  # how hard the pluck is
    out, pos, body = [], 0, SVF()
    for _ in range(int(seconds * RATE)):
        a = line[pos % len(line)]
        b = line[(pos + 1) % len(line)]
        value = a * (1 - frac) + b * frac
        line[pos % len(line)] = damping * 0.5 * (a + b)
        out.append(body.next(value, f * 3, 0.7)[0])  # the instrument's body softens the top
        pos += 1
    return out


def warm(track: list[float], drive: float = 2.0) -> list[float]:
    """A touch of saturation: it rounds the attack's spike, so a quick note
    carries the same loudness as the rest without clipping."""
    peak = max(abs(v) for v in track) or 1.0
    return [math.tanh(drive * v / peak) for v in track]


def fade_out(track: list[float], tail: float = 0.05) -> list[float]:
    """Close the note gently by LENGTH, so every tone is short."""
    count = int(tail * RATE)
    start = len(track) - count
    return [v * (1.0 if n < start else (len(track) - n) / count) for n, v in enumerate(track)]


TONES = {
    "guitar-a4": lambda: karplus(hz("A4"), LENGTH, 0.996, 2.5, 1),
    "harp-c5": lambda: karplus(hz("C5"), LENGTH, 0.998, 1.5, 2),
    "pizz-b4": lambda: warm([v * math.exp(-n / RATE / 0.13) for n, v in enumerate(karplus(hz("B4"), LENGTH, 0.99, 2.0, 3))]),
    "kalimba-d5": lambda: additive(hz("D5"), LENGTH, ((1, 1.0, 0.18), (5.4, 0.25, 0.03))),
    "marimba-a4": lambda: additive(hz("A4"), LENGTH, ((1, 1.0, 0.12), (4, 0.35, 0.02), (10, 0.08, 0.008))),
    "vibes-c5": lambda: additive(hz("C5"), LENGTH, ((1, 1.0, 0.25), (4, 0.3, 0.05), (10, 0.06, 0.01))),
    "celesta-a4": lambda: additive(hz("A4"), LENGTH, ((1, 1.0, 0.2), (2, 0.3, 0.08), (3, 0.12, 0.05))),
    "musicbox-c5": lambda: additive(hz("C5"), LENGTH, ((1, 1.0, 0.22), (3, 0.2, 0.06), (5.8, 0.12, 0.03))),
    "steelpan-b4": lambda: fm(hz("B4"), LENGTH, ratio=3.5, index=1.2, index_tau=0.05, amp_tau=0.15),
    "glass-a4": lambda: additive(hz("A4"), LENGTH, ((1, 1.0, 0.3), (2.32, 0.25, 0.12), (4.25, 0.1, 0.06))),
    "woodblock-c5": lambda: warm(additive(hz("C5"), LENGTH, ((1, 1.0, 0.08), (2.9, 0.4, 0.025), (5.1, 0.15, 0.01))), 2.5),
    "ocarina-b4": lambda: ocarina(hz("B4")),
    "fmbell-c5": lambda: fm(hz("C5"), LENGTH, ratio=1.4, index=2.0, index_tau=0.06, amp_tau=0.14),
    "synthpluck-a4": lambda: warm(subtractive([hz("A4")], LENGTH, gate=0.08, amp=(0.002, 0.15, 0.3, 0.1),
                                         cutoff=450, sweep=900, fenv=(0.002, 0.05, 0.0, 0.05), resonance=0.25,
                                         detune=0.005)),
}


def ocarina(f: float) -> list[float]:
    breath, air, out = noise(9), SVF(), []
    for n in range(int(LENGTH * RATE)):
        t = n / RATE
        tone = math.sin(2 * math.pi * f * t) + 0.08 * math.sin(4 * math.pi * f * t)
        hiss = air.next(next(breath), f * 2, 2.0)[1]
        envelope = min(t / 0.02, 1.0) * math.exp(-t / 0.2)
        out.append((tone + 0.25 * hiss) * envelope)
    return out


def main() -> None:
    for name in sys.argv[1:] or TONES:
        track = finish(fade_out(TONES[name]()), fade=0.005)
        path = OUT / f"{name}.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in track))
        print(f"wrote {path} ({len(track) / RATE:.2f} s)")


if __name__ == "__main__":
    main()
