"""Generate the dx-* bundled tones: FM synthesis in the style of the Yamaha DX7.

The DX7 makes sound with "operators": sine oscillators, each with its own
envelope, where a modulator bends a carrier's phase. Most of a patch's
character is the modulation depth (index) changing over the note. These are
small two- and three-operator versions of famous factory presets, short enough
for a notification.

Date: 2026-10-20
Usage: uv run python scripts/claude/gen_dx7_tones.py   (from the repo root)
Then: uv run z-iris normalize --dir src/z_iris/sounds --no-backup
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parents[2] / "src" / "z_iris" / "sounds"


def env(t: float, attack: float, decay: float, sustain: float = 0.0) -> float:
    """A linear attack, then an exponential fall towards sustain."""
    if t < attack:
        return t / attack
    return sustain + (1.0 - sustain) * math.exp(-(t - attack) / decay)


def note(
    freq: float,
    seconds: float,
    *,
    mod_ratio: float,
    index: float,
    index_decay: float,
    amp_decay: float,
    attack: float = 0.002,
    index_floor: float = 0.0,
    index_attack: float = 0.0005,
    carrier_ratio: float = 1.0,
    tine_ratio: float = 0.0,
    tine_index: float = 0.0,
    tine_level: float = 0.0,
    detune: float = 0.0,
    vibrato: float = 0.0,
) -> list[float]:
    """One FM voice: a modulator into a carrier, optionally a second detuned
    carrier (chorus), a vibrato, and a fast-decaying high "tine" pair."""
    samples = []
    for n in range(int(seconds * RATE)):
        t = n / RATE
        wobble = 1.0 + vibrato * math.sin(2 * math.pi * 5.5 * t) * min(t / 0.15, 1.0)
        f = freq * wobble
        depth = index * env(t, index_attack, index_decay, index_floor / index if index else 0)
        mod = math.sin(2 * math.pi * f * mod_ratio * t)
        level = env(t, attack, amp_decay)
        out = math.sin(2 * math.pi * f * carrier_ratio * t + depth * mod)
        if detune:
            out = 0.5 * (out + math.sin(2 * math.pi * (f * carrier_ratio + detune) * t + depth * mod))
        sample = out * level
        if tine_level:
            tine_mod = math.sin(2 * math.pi * f * tine_ratio * t)
            tine_depth = tine_index * math.exp(-t / 0.03)
            sample += tine_level * math.exp(-t / 0.25) * math.sin(2 * math.pi * f * t + tine_depth * tine_mod)
        samples.append(sample)
    return samples


def place(track: list[float], sound: list[float], at: float, gain: float = 1.0) -> None:
    start = int(at * RATE)
    if len(track) < start + len(sound):
        track.extend([0.0] * (start + len(sound) - len(track)))
    for i, value in enumerate(sound):
        track[start + i] += gain * value


def finish(track: list[float], fade: float = 0.02) -> list[float]:
    """Fade the last moments to silence and scale to -3 dBFS peak."""
    count = int(fade * RATE)
    for i in range(count):
        track[-count + i] *= 1.0 - i / count
    peak = max(abs(v) for v in track) or 1.0
    return [v * 0.708 / peak for v in track]


def write(name: str, track: list[float]) -> None:
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in finish(track)))
    print(f"wrote {path}")


def epiano() -> list[float]:
    """E.PIANO 1: a soft 1:1 body plus the 14:1 "tine" ping. E5 then B5."""
    voice = dict(mod_ratio=1.0, index=1.6, index_decay=0.35, index_floor=0.3,
                 amp_decay=0.45, tine_ratio=14.0, tine_index=2.2, tine_level=0.35)
    track: list[float] = []
    place(track, note(659.3, 0.9, **voice), 0.0)
    place(track, note(987.8, 0.9, **voice), 0.16, 0.8)
    return track


def bells() -> list[float]:
    """TUB BELLS: an inharmonic 3.5:1 modulator, a slow index fall, a long ring
    and a slightly detuned second carrier for the beating."""
    track: list[float] = []
    place(track, note(784.0, 1.6, mod_ratio=3.5, index=3.5, index_decay=0.5,
                      amp_decay=0.6, detune=1.5), 0.0)
    return track


def marimba() -> list[float]:
    """A wooden strike: a 4:1 modulator whose depth dies in 40 ms. G5 then C6."""
    voice = dict(mod_ratio=4.0, index=3.0, index_decay=0.04, amp_decay=0.12)
    track: list[float] = []
    place(track, note(784.0, 0.4, **voice), 0.0)
    place(track, note(1046.5, 0.4, **voice), 0.11)
    return track


def bass() -> list[float]:
    """BASS 1: a 1:1 pair with a hard, fast index fall: the pluck. A low E and its
    octave, pitched up enough to carry on laptop speakers."""
    voice = dict(mod_ratio=1.0, index=4.0, index_decay=0.08, index_floor=0.6,
                 amp_decay=0.25)
    track: list[float] = []
    place(track, note(164.8, 0.5, **voice), 0.0)
    place(track, note(329.6, 0.4, **voice), 0.13, 0.7)
    return track


def brass() -> list[float]:
    """BRASS 1: the modulation swells in with the note, so it brightens like a
    horn; a little vibrato. A C major stab (C5 E5 G5)."""
    voice = dict(mod_ratio=1.0, index=2.2, index_decay=0.25, index_floor=1.4,
                 index_attack=0.06, attack=0.04, amp_decay=0.35, detune=0.8,
                 vibrato=0.004)
    track: list[float] = []
    for freq in (523.3, 659.3, 784.0):
        place(track, note(freq, 0.55, **voice), 0.0, 0.33)
    return track


if __name__ == "__main__":
    for name, make in (("dx-epiano", epiano), ("dx-bells", bells), ("dx-marimba", marimba),
                       ("dx-bass", bass), ("dx-brass", brass)):
        write(name, make())
