"""Generate bundled drum tones after famous drum machines and synth drums.

All analog-style synthesis, as the machines made them: sines with pitch
envelopes for kicks and toms, tuned sines plus filtered noise for snares,
staggered noise bursts for claps, detuned square pairs for the 808 cowbell.
Each is driven a little into saturation, as their circuits were, which also
lets a short hit reach the others' loudness without clipping.

  808-snare     Roland TR-808 snare: two tuned heads and a snappy noise
  808-clap      TR-808 handclap: three quick bursts and a tail
  808-cowbell   TR-808 cowbell: two square waves at 540 and 800 Hz
  808-clave     TR-808 claves: a woodblock ping, three times
  808-beat      TR-808 kick, hat, snare, hat
  808-toms      TR-808 toms, high to low
  909-kick      Roland TR-909 kick: a punchy sweep with a click
  909-clap      TR-909 handclap, brighter and tighter
  909-roll      TR-909 snare roll, building
  syndrum-pew   Pollard Syndrum: the disco "pew"
  cr78-beat     Roland CR-78: a soft vintage kick, rim and hat pattern

Date: 2026-10-28
Usage: python3 scripts/claude/gen_drums.py [name ...]   (from the repo root)
Then: scripts/claude/level_sounds.sh
"""

from __future__ import annotations

import math
import struct
import sys
import wave

from gen_synths import OUT, RATE, SVF, finish, noise, place


def sweep_sine(start_hz: float, end_hz: float, sweep: float, decay: float, seconds: float,
               drive: float = 1.5) -> list[float]:
    """A sine whose pitch falls from start to end (time constant sweep) as it
    decays: a kick or a tom."""
    phase, out = 0.0, []
    for n in range(int(seconds * RATE)):
        t = n / RATE
        f = end_hz + (start_hz - end_hz) * math.exp(-t / sweep)
        phase += f / RATE
        out.append(math.tanh(drive * math.sin(2 * math.pi * phase)) * math.exp(-t / decay))
    return out


def filtered_noise(seconds: float, cutoff: float, q: float, decay: float, seed: int, band: bool = True,
                   attack: float = 0.0005) -> list[float]:
    """White noise through a band-pass (or high-pass, by subtracting the
    low-pass), decaying."""
    source, svf, out = noise(seed), SVF(), []
    for n in range(int(seconds * RATE)):
        t = n / RATE
        x = next(source)
        low, bandpass = svf.next(x, cutoff, q)
        y = bandpass if band else x - low
        out.append(y * math.exp(-t / decay) * min(t / attack, 1.0))
    return out


def mix(*parts: tuple[list[float], float]) -> list[float]:
    track: list[float] = []
    for sound, gain in parts:
        place(track, sound, 0.0, gain)
    return track


def saturate(track: list[float], drive: float = 2.0) -> list[float]:
    peak = max(abs(v) for v in track) or 1.0
    return [math.tanh(drive * v / peak) for v in track]


def snare_808(seed: int = 1) -> list[float]:
    heads = mix((sweep_sine(238, 180, 0.01, 0.06, 0.25, 1.2), 0.7), (sweep_sine(476, 330, 0.01, 0.04, 0.25, 1.2), 0.4))
    snappy = filtered_noise(0.25, 1800, 0.7, 0.07, seed, band=False)
    return saturate(mix((heads, 1.0), (snappy, 0.8)), 2.2)


def clap(seed: int, centre: float, tail: float, gap: float) -> list[float]:
    track: list[float] = []
    for k in range(3):
        place(track, filtered_noise(0.03, centre, 1.5, 0.008, seed + k), gap * k, 1.0)
    place(track, filtered_noise(0.35, centre, 1.2, tail, seed + 9), gap * 3, 0.9)
    return saturate(track, 2.5)


def cowbell() -> list[float]:
    out, svf = [], SVF()
    for n in range(int(0.45 * RATE)):
        t = n / RATE
        square = sum(1.0 if (f * t) % 1.0 < 0.5 else -1.0 for f in (540.0, 800.0))
        _, band = svf.next(square, 2600, 1.2)
        envelope = 0.6 * math.exp(-t / 0.015) + 0.4 * math.exp(-t / 0.12)  # the 808's two-stage decay
        out.append(band * envelope)
    return saturate(out, 3.5)


def clave(at_hz: float = 2500) -> list[float]:
    return [math.sin(2 * math.pi * at_hz * n / RATE) * math.exp(-n / RATE / 0.025) for n in range(int(0.12 * RATE))]


def hat_808(seed: int, decay: float = 0.03) -> list[float]:
    # six detuned square waves, as the 808's metal sound, then a high-pass
    freqs = (205.3, 304.4, 369.6, 522.7, 540.0, 800.0)
    svf, out = SVF(), []
    for n in range(int(0.15 * RATE)):
        t = n / RATE
        metal = sum(1.0 if (f * t) % 1.0 < 0.5 else -1.0 for f in freqs)
        low, _ = svf.next(metal, 7000, 0.7)
        out.append((metal - low) * math.exp(-t / decay))
    return out


def tom(start: float, end: float, decay: float = 0.18) -> list[float]:
    return sweep_sine(start, end, 0.05, decay, 0.4, 1.4)


def kick_909() -> list[float]:
    body = sweep_sine(330, 55, 0.025, 0.22, 0.5, 2.5)
    click = filtered_noise(0.02, 3000, 0.7, 0.004, 5, band=False)
    return saturate(mix((body, 1.0), (click, 0.6)), 1.6)


def snare_909(seed: int, level: float = 1.0) -> list[float]:
    heads = sweep_sine(300, 190, 0.008, 0.05, 0.2, 1.4)
    rattle = filtered_noise(0.2, 2500, 0.6, 0.06, seed, band=False)
    return [level * v for v in saturate(mix((heads, 0.8), (rattle, 1.0)), 2.0)]


TONES = {}


def tone(name: str):
    def register(make):
        TONES[name] = make
        return make
    return register


@tone("808-snare")
def _() -> list[float]:
    return snare_808()


@tone("808-clap")
def _() -> list[float]:
    return clap(seed=11, centre=1100, tail=0.09, gap=0.011)


@tone("808-cowbell")
def _() -> list[float]:
    return cowbell()


@tone("808-clave")
def _() -> list[float]:
    track: list[float] = []
    for at in (0.0, 0.16, 0.32):  # a fragment of son clave
        place(track, clave(), at)
    return track


@tone("808-beat")
def _() -> list[float]:
    track: list[float] = []
    step = 0.12
    place(track, sweep_sine(150, 55, 0.04, 0.3, 0.5, 2.0), 0.0, 1.0)  # kick
    place(track, hat_808(3), step, 0.35)
    place(track, snare_808(4), 2 * step, 0.8)
    place(track, hat_808(5), 3 * step, 0.35)
    return saturate(track, 1.6)


@tone("808-toms")
def _() -> list[float]:
    track: list[float] = []
    for k, (start, end) in enumerate(((330, 260), (240, 185), (170, 125))):
        place(track, tom(start, end), 0.11 * k)
    return saturate(track, 1.5)


@tone("909-kick")
def _() -> list[float]:
    return kick_909()


@tone("909-clap")
def _() -> list[float]:
    return clap(seed=21, centre=1500, tail=0.06, gap=0.008)


@tone("909-roll")
def _() -> list[float]:
    track: list[float] = []
    hits = 6
    for k in range(hits):  # sixteenths, louder each time
        place(track, snare_909(30 + k, 0.35 + 0.65 * k / (hits - 1)), 0.065 * k)
    return track


@tone("syndrum-pew")
def _() -> list[float]:
    pew = sweep_sine(900, 160, 0.09, 0.25, 0.35, 1.3)
    return saturate(mix((pew, 1.0), (filtered_noise(0.35, 4000, 0.7, 0.01, 7), 0.15)), 1.4)


@tone("cr78-beat")
def _() -> list[float]:
    track: list[float] = []
    step = 0.11
    place(track, sweep_sine(110, 70, 0.03, 0.12, 0.25, 1.2), 0.0, 1.0)  # a soft, round kick
    place(track, hat_808(8, decay=0.02), step, 0.3)
    place(track, clave(1700), 2 * step, 0.6)  # the rim
    place(track, hat_808(9, decay=0.02), 3 * step, 0.3)
    return saturate(track, 1.3)


def main() -> None:
    for name in sys.argv[1:] or TONES:
        track = finish(TONES[name](), fade=0.01)
        path = OUT / f"{name}.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in track))
        print(f"wrote {path} ({len(track) / RATE:.2f} s)")


if __name__ == "__main__":
    main()
