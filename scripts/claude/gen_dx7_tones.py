"""Generate the dx-* bundled tones: FM synthesis in the style of the Yamaha DX7.

The DX7 makes sound with "operators": sine oscillators, each with its own
envelope, where a modulator bends a carrier's phase. Most of a patch's
character is the modulation depth (index) changing over the note. These are
small two- and three-operator versions of famous factory presets, short enough
for a notification.

Date: 2026-10-20
Usage: python3 scripts/claude/gen_dx7_tones.py [name ...]   (from the repo root)
Then: (cd swift && swift run z-iris normalize --dir Resources/sounds --no-backup)
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parents[2] / "swift" / "Resources" / "sounds"


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
    tremolo: float = 0.0,
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
        if tremolo:  # the vibraphone's spinning fans
            level *= 1.0 - tremolo * (0.5 + 0.5 * math.sin(2 * math.pi * 5.5 * t))
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


def piano_c() -> list[float]:
    """E.PIANO 1, one short middle C (C4). A little more index and tine than the
    motif, so the low note still has its bell-like edge."""
    track: list[float] = []
    place(track, note(261.63, 0.6, mod_ratio=1.0, index=2.0, index_decay=0.3,
                      index_floor=0.4, amp_decay=0.3, tine_ratio=14.0, tine_index=2.6,
                      tine_level=0.45), 0.0)
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


def vibe() -> list[float]:
    """VIBE 1: a bright 4:1 strike with a quick index fall, a long ring and the
    motor tremolo. C6 then E6."""
    voice = dict(mod_ratio=4.0, index=1.5, index_decay=0.15, index_floor=0.2,
                 amp_decay=0.9, tremolo=0.3)
    track: list[float] = []
    place(track, note(1046.5, 1.3, **voice), 0.0)
    place(track, note(1318.5, 1.2, **voice), 0.12, 0.8)
    return track


def koto() -> list[float]:
    """KOTO: a 3:1 pluck whose brightness dies in 50 ms. E5 then B5."""
    voice = dict(mod_ratio=3.0, index=4.0, index_decay=0.05, index_floor=0.5, amp_decay=0.35)
    track: list[float] = []
    place(track, note(659.3, 0.7, **voice), 0.0)
    place(track, note(987.8, 0.7, **voice), 0.13, 0.85)
    return track


def clav() -> list[float]:
    """CLAV 1: a hard, buzzy 1:1 strike, very short. Two staccato G4s."""
    voice = dict(mod_ratio=1.0, index=5.0, index_decay=0.03, index_floor=1.5, amp_decay=0.12)
    track: list[float] = []
    place(track, note(392.0, 0.25, **voice), 0.0)
    place(track, note(392.0, 0.25, **voice), 0.14)
    return track


def harpsichord() -> list[float]:
    """HARPSICH 1: a 2:1 voice with a bright jack 'pluck' on top. C5 E5 G5."""
    voice = dict(mod_ratio=2.0, index=3.5, index_decay=0.2, index_floor=1.0, amp_decay=0.4,
                 tine_ratio=7.0, tine_index=1.5, tine_level=0.2)
    track: list[float] = []
    for k, freq in enumerate((523.3, 659.3, 784.0)):
        place(track, note(freq, 0.6, **voice), 0.07 * k, 0.6)
    return track


def steel_drum() -> list[float]:
    """STEEL DRUM: an inharmonic 3.5:1 pan with a little beating. D5 then A5."""
    voice = dict(mod_ratio=3.5, index=2.5, index_decay=0.25, index_floor=0.4, amp_decay=0.4,
                 detune=2.0)
    track: list[float] = []
    place(track, note(587.3, 0.7, **voice), 0.0)
    place(track, note(880.0, 0.7, **voice), 0.15, 0.8)
    return track


def flute() -> list[float]:
    """FLUTE 1: a soft 1:1 voice that breathes in, with vibrato. One A5."""
    track: list[float] = []
    place(track, note(880.0, 0.7, mod_ratio=1.0, index=0.8, index_decay=0.3, index_floor=0.5,
                      index_attack=0.06, attack=0.06, amp_decay=1.5, vibrato=0.006), 0.0)
    return track


def organ() -> list[float]:
    """E.ORGAN 1: carriers at 1, 2 and 4 times the note, like drawbars, with
    almost no modulation. A C5 and G5 chord."""
    track: list[float] = []
    for freq in (523.3, 784.0):
        for ratio, gain in ((1.0, 0.5), (2.0, 0.3), (4.0, 0.15)):
            place(track, note(freq, 0.6, mod_ratio=1.0, index=0.15, index_decay=1.0,
                              carrier_ratio=ratio, attack=0.01, amp_decay=5.0), 0.0, gain)
    return track


def strings() -> list[float]:
    """STRINGS 1: a slow swell, chorus and vibrato. An A major chord."""
    voice = dict(mod_ratio=1.0, index=1.2, index_decay=0.5, index_floor=1.0, attack=0.15,
                 amp_decay=2.0, detune=1.5, vibrato=0.004)
    track: list[float] = []
    for freq in (440.0, 554.4, 659.3):
        place(track, note(freq, 0.9, **voice), 0.0, 0.33)
    return track


def orch_chime() -> list[float]:
    """ORCH-CHIME: an inharmonic 1.41:1 chime with a long ring. G5 then D6."""
    voice = dict(mod_ratio=1.41, index=3.0, index_decay=0.8, amp_decay=1.0)
    track: list[float] = []
    place(track, note(784.0, 1.4, **voice), 0.0)
    place(track, note(1174.7, 1.2, **voice), 0.2, 0.8)
    return track


def synlead() -> list[float]:
    """SYN-LEAD 1: a bright, sustained 1:1 lead with vibrato. E5 then A5."""
    voice = dict(mod_ratio=1.0, index=3.0, index_decay=0.3, index_floor=2.5, attack=0.01,
                 amp_decay=1.5, vibrato=0.005)
    track: list[float] = []
    place(track, note(659.3, 0.18, **voice), 0.0)
    place(track, note(880.0, 0.4, **voice), 0.16)
    return track


if __name__ == "__main__":
    import sys

    tones = {"dx-epiano": epiano, "dx-piano-c": piano_c, "dx-bells": bells,
             "dx-marimba": marimba, "dx-bass": bass, "dx-brass": brass,
             "dx-vibe": vibe, "dx-koto": koto, "dx-clav": clav, "dx-harpsichord": harpsichord,
             "dx-steel-drum": steel_drum, "dx-flute": flute, "dx-organ": organ,
             "dx-strings": strings, "dx-orch-chime": orch_chime, "dx-synlead": synlead}
    for name in sys.argv[1:] or tones:  # names to make just those
        write(name, tones[name]())
