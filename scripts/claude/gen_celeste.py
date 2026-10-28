"""Generate bundled tones in the spirit of Lena Raine's Celeste soundtrack:
the instruments, not its melodies (every note pattern here is original).

  celeste-piano    a soft felt piano, a gentle major-seventh chord
  celeste-rhodes   an electric piano chord with a slow tremolo
  celeste-arp      a bright, chorused synth arpeggio in sixteenths
  celeste-pad      a warm, detuned pad swelling open (kept short)
  celeste-crystal  a glassy crystal bell, two notes
  celeste-chip     a PICO-8-style square lead with vibrato, as in Celeste Classic
  celeste-sparkle  a quick rising pluck run, a pickup's shimmer
  celeste-bass     a round synth bass, two notes

Date: 2026-10-28
Usage: python3 scripts/claude/gen_celeste.py [name ...]   (from the repo root)
Then: scripts/claude/level_sounds.sh
"""

from __future__ import annotations

import math
import struct
import sys
import wave

from gen_synths import OUT, RATE, Osc, additive, chorus, finish, fm, hz, place, subtractive


def piano() -> list[float]:
    track: list[float] = []
    for name in ("C4", "E4", "G4", "B4"):
        f = hz(name)
        # felt hammers: few, soft overtones, slightly stretched, dying fast
        note = additive(f, 0.8, tuple((k * (1 + 0.0003 * k * k), 1.0 / k ** 1.4, 0.7 / k ** 0.6) for k in range(1, 7)),
                        attack=0.006)
        place(track, note, 0.0, 0.5)
    return track


def rhodes() -> list[float]:
    track: list[float] = []
    for name in ("D4", "F#4", "A4", "E5"):
        f = hz(name)
        body = fm(f, 0.9, ratio=1.0, index=1.2, index_tau=0.25, amp_tau=0.5)
        tine = fm(f, 0.9, ratio=14.0, index=0.6, index_tau=0.02, amp_tau=0.06)
        place(track, [a + 0.3 * b for a, b in zip(body, tine)], 0.0, 0.45)
    return [v * (1 + 0.25 * math.sin(2 * math.pi * 4.5 * n / RATE)) for n, v in enumerate(track)]


def arp() -> list[float]:
    track: list[float] = []
    for k, name in enumerate(("A4", "E5", "C#5", "E5", "A5", "E5")):
        note = subtractive([hz(name)], 0.16, gate=0.05, amp=(0.002, 0.08, 0.3, 0.06), cutoff=1200,
                           sweep=3000, fenv=(0.002, 0.05, 0.2, 0.05), resonance=0.15, detune=0.006,
                           shapes=("saw", "pulse"), pwm=0.2)
        place(track, note, 0.07 * k, 0.8)
    return chorus(track, depth_ms=1.8, mix=0.45)


def pad() -> list[float]:
    voice = subtractive([hz(n) for n in ("F3", "A3", "C4", "E4")], 0.8, gate=0.5, amp=(0.12, 0.4, 0.85, 0.22),
                        cutoff=600, sweep=1400, fenv=(0.25, 0.35, 0.6, 0.22), resonance=0.15, detune=0.008,
                        shapes=("saw", "saw", "saw"))
    return chorus(voice, depth_ms=2.2, mix=0.5)


def crystal() -> list[float]:
    track: list[float] = []
    for name, at in (("E5", 0.0), ("B5", 0.14)):
        f = hz(name)
        bell = fm(f, 0.6, ratio=3.5, index=1.8, index_tau=0.08, amp_tau=0.22)
        shimmer = additive(f, 0.6, ((2.0, 0.3, 0.15), (4.2, 0.15, 0.08)))
        place(track, [a + b for a, b in zip(bell, shimmer)], at, 0.7)
    return chorus(track, depth_ms=1.0, mix=0.3)


def chip() -> list[float]:
    track: list[float] = []
    for name, at, length in (("C5", 0.0, 0.14), ("G5", 0.14, 0.26)):
        f, osc, out = hz(name), Osc("pulse"), []
        for n in range(int(length * RATE)):
            t = n / RATE
            vibrato = 1 + 0.012 * math.sin(2 * math.pi * 6 * t) * min(t / 0.08, 1.0)
            level = 1.0 if t < length - 0.03 else (length - t) / 0.03
            out.append(round(osc.next(f * vibrato, 0.25) * level * 7) / 7)  # PICO-8's few volume steps
        place(track, out, at, 0.6)
    return track


def sparkle() -> list[float]:
    track: list[float] = []
    for k, name in enumerate(("C5", "E5", "G5", "B5", "E6")):
        f = hz(name)
        pluck = additive(f, 0.35, ((1, 1.0, 0.12), (2, 0.25, 0.05), (3, 0.1, 0.03)))
        place(track, pluck, 0.045 * k, 0.5 + 0.06 * k)
    return chorus(track, depth_ms=1.2, mix=0.35)


def bass() -> list[float]:
    track: list[float] = []
    for name, at in (("A2", 0.0), ("E3", 0.18)):
        note = subtractive([hz(name)], 0.3, gate=0.14, amp=(0.004, 0.2, 0.7, 0.08), cutoff=300, sweep=900,
                           fenv=(0.004, 0.1, 0.2, 0.08), resonance=0.2, detune=0.003, shapes=("saw", "pulse"),
                           sub=0.5, drive=1.6)
        place(track, note, at)
    return track


TONES = {
    "celeste-piano": piano, "celeste-rhodes": rhodes, "celeste-arp": arp, "celeste-pad": pad,
    "celeste-crystal": crystal, "celeste-chip": chip, "celeste-sparkle": sparkle, "celeste-bass": bass,
}


def main() -> None:
    for name in sys.argv[1:] or TONES:
        track = finish(TONES[name](), fade=0.02)
        path = OUT / f"{name}.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in track))
        print(f"wrote {path} ({len(track) / RATE:.2f} s)")


if __name__ == "__main__":
    main()
