"""Generate nineteen bundled tones after famous synthesizers and samplers.

Each is a short, characteristic gesture of its instrument, small enough for a
notification: subtractive voices (band-limited polyBLEP oscillators through a
resonant four-pole ladder low-pass), a BBD-style chorus, a wavetable, additive
partials and hard sync, as the originals made them.

  juno-pad       Roland Juno-106: saw and pulse-width-modulated square with
                 the famous chorus, an A minor add9 chord swelling in
  tb303-acid     Roland TB-303: a resonant squelch, an accented note and a slide
  prophet-brass  Sequential Prophet-5: detuned saw brass whose filter swells open
  obx-jump       Oberheim OB-Xa: the bright detuned "Jump" stab, twice
  cs80-blade     Yamaha CS-80: Vangelis's Blade Runner brass, a bend up and vibrato
  ppg-wave       PPG Wave: a digital wavetable sweeping through its harmonics
  d50-fantasia   Roland D-50: a sampled-attack bell sparkle over a soft pad
  m1-piano       Korg M1: the bright house piano stab
  alpha-hoover   Roland Alpha Juno: the rave "hoover", detuned and diving in
  odyssey-sync   ARP Odyssey: a hard-sync lead sweeping up, two notes
  mellotron-flute  Mellotron: a tape-replayed flute, with wow, flutter and hiss
  fairlight-orch   Fairlight CMI: the lo-fi "ORCH5" orchestra hit
  jupiter-arp      Roland Jupiter-8: its arpeggiator running up a chord
  sh101-zap        Roland SH-101: a laser zap, the pitch diving
  emulator-choir   E-mu Emulator: a sampled "aah" choir, formants on a chord
  jp8000-supersaw  Roland JP-8000: the trance supersaw stab
  synclavier-bell  Synclavier: an additive bell with its own partial decays
  buchla-bongo     Buchla: West Coast "bongos", a folded tone through a low-pass gate
  omnichord-strum  Suzuki Omnichord: a strum across the strumplate

Date: 2026-10-28
Usage: python3 scripts/claude/gen_synths.py [name ...]   (from the repo root)
Then: (cd swift && swift run z-iris normalize --dir Resources/sounds --no-backup)
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parents[2] / "swift" / "Resources" / "sounds"


def hz(note: str) -> float:
    """A note name such as "A4" or "C#3" as a frequency (A4 = 440 Hz)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[note[0]] + (1 if "#" in note else -1 if note[1] == "b" else 0)
    octave = int(note[-1])
    return 440.0 * 2 ** ((semis + 12 * (octave - 4)) / 12)


def blep(t: float, dt: float) -> float:
    """polyBLEP correction near a waveform's jump, for band-limited edges."""
    if t < dt:
        t /= dt
        return t + t - t * t - 1.0
    if t > 1.0 - dt:
        t = (t - 1.0) / dt
        return t * t + t + t + 1.0
    return 0.0


class Osc:
    """A band-limited saw or pulse whose pitch may change every sample."""

    def __init__(self, shape: str = "saw", phase: float = 0.0) -> None:
        self.shape, self.phase = shape, phase

    def next(self, freq: float, width: float = 0.5) -> float:
        p, dt = self.phase, min(freq / RATE, 0.49)
        if self.shape == "saw":
            value = 2.0 * p - 1.0 - blep(p, dt)
        else:
            value = (1.0 if p < width else -1.0) + blep(p, dt) - blep((p + 1.0 - width) % 1.0, dt)
        self.phase = (p + dt) % 1.0
        return value


class Ladder:
    """A four-pole (24 dB/octave) resonant low-pass, with tanh saturation."""

    def __init__(self) -> None:
        self.s = [0.0] * 4

    def next(self, x: float, cutoff: float, resonance: float, drive: float = 1.0) -> float:
        g = 1.0 - math.exp(-2.0 * math.pi * min(cutoff, RATE * 0.45) / RATE)
        x = math.tanh(drive * x - 4.0 * resonance * self.s[3])
        for i in range(4):
            self.s[i] += g * (math.tanh(x) - self.s[i])
            x = self.s[i]
        return x


class SVF:
    """A state-variable filter (Zavalishin's TPT form), stable at any cutoff:
    next() returns its low-pass and band-pass outputs."""

    def __init__(self) -> None:
        self.ic1 = self.ic2 = 0.0

    def next(self, x: float, cutoff: float, q: float) -> tuple[float, float]:
        g = math.tan(math.pi * min(cutoff, RATE * 0.45) / RATE)
        k = 1.0 / q
        a1 = 1.0 / (1.0 + g * (g + k))
        a2, v3 = g * a1, x - self.ic2
        v1 = a1 * self.ic1 + a2 * v3
        v2 = self.ic2 + a2 * self.ic1 + g * a2 * v3
        self.ic1, self.ic2 = 2 * v1 - self.ic1, 2 * v2 - self.ic2
        return v2, v1


def noise(seed: int):
    """Repeatable white noise, so the files are the same each time."""
    state = seed
    while True:
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        yield state / 0x3FFFFFFF - 1.0


def adsr(t: float, gate: float, a: float, d: float, s: float, r: float) -> float:
    """Attack, decay to sustain while the key is down for gate seconds, then release."""
    def held(u: float) -> float:
        return u / a if u < a else s + (1.0 - s) * math.exp(-(u - a) / d)
    if t <= gate:
        return held(t)
    return held(gate) * math.exp(-(t - gate) / r)


def chorus(track: list[float], depth_ms: float = 1.6, centre_ms: float = 3.5, rate_hz: float = 0.5,
           mix: float = 0.5) -> list[float]:
    """A BBD chorus: the dry signal plus a copy on a slowly swaying delay."""
    out = []
    for n, x in enumerate(track):
        delay = (centre_ms + depth_ms * math.sin(2 * math.pi * rate_hz * n / RATE)) * RATE / 1000
        pos = n - delay
        i = int(math.floor(pos))
        frac = pos - i
        wet = 0.0
        if i >= 0:
            wet = track[i] * (1 - frac) + (track[i + 1] if i + 1 < len(track) else 0.0) * frac
        out.append((1 - mix) * x + mix * wet)
    return out


def place(track: list[float], sound: list[float], at: float, gain: float = 1.0) -> None:
    start = int(at * RATE)
    if start + len(sound) > len(track):
        track.extend([0.0] * (start + len(sound) - len(track)))
    for i, v in enumerate(sound):
        track[start + i] += gain * v


def subtractive(freqs: list[float], seconds: float, *, gate: float, amp: tuple, cutoff: float,
                sweep: float, fenv: tuple, resonance: float = 0.2, detune: float = 0.004,
                shapes: tuple = ("saw", "saw"), drive: float = 1.5, glide=None, vibrato: float = 0.0,
                pwm: float = 0.0, sub: float = 0.0) -> list[float]:
    """One voice per frequency: detuned oscillators into a ladder whose cutoff
    follows its own envelope; the amp envelope shapes the whole."""
    voices = []
    for f in freqs:
        oscs = [Osc(shape, phase=k * 0.31) for k, shape in enumerate(shapes)]
        subosc = Osc("pulse")
        ladder = Ladder()
        out = []
        for n in range(int(seconds * RATE)):
            t = n / RATE
            pitch = f * (glide(t) if glide else 1.0)
            pitch *= 1.0 + vibrato * math.sin(2 * math.pi * 5.6 * t) * min(t / 0.3, 1.0)
            width = 0.5 + pwm * math.sin(2 * math.pi * 0.7 * t)
            spread = [1.0 + detune * (k - (len(oscs) - 1) / 2) for k in range(len(oscs))]
            mix = sum(o.next(pitch * s, width) for o, s in zip(oscs, spread)) / len(oscs)
            if sub:
                mix += sub * subosc.next(pitch / 2)
            c = cutoff + sweep * adsr(t, gate, *fenv)
            out.append(ladder.next(mix, c, resonance, drive) * adsr(t, gate, *amp))
        voices.append(out)
    return [sum(v[n] for v in voices) / len(voices) ** 0.5 for n in range(len(voices[0]))]


# ---- the ten patches ----

def juno_pad() -> list[float]:
    chord = [hz(n) for n in ("A3", "C4", "E4", "B4")]
    voice = subtractive(chord, 1.3, gate=0.9, amp=(0.06, 0.6, 0.8, 0.3), cutoff=900, sweep=1400,
                        fenv=(0.12, 0.5, 0.4, 0.3), resonance=0.15, detune=0.0, shapes=("saw", "pulse"),
                        pwm=0.3, sub=0.25)
    return chorus(voice, mix=0.5)


def tb303_acid() -> list[float]:
    track: list[float] = []
    steps = [("C3", 0.0, 0.0, False), ("C3", 0.14, 1.0, False), ("C4", 0.28, 0.6, True)]
    for name, at, accent, slide in steps:
        f = hz(name)
        glide = (lambda t: 0.5 + 0.5 * min(t / 0.06, 1.0)) if slide else None
        note = subtractive([f], 0.24 if slide else 0.15, gate=0.2 if slide else 0.11,
                           amp=(0.003, 0.4, 0.85, 0.02), cutoff=260, sweep=1800 + 2200 * accent,
                           fenv=(0.002, 0.09 + 0.05 * accent, 0.0, 0.03), resonance=0.82, detune=0.0,
                           shapes=("saw",), drive=2.2, glide=glide)
        place(track, note, at, 0.8 + 0.4 * accent)
    return track


def prophet_brass() -> list[float]:
    chord = [hz(n) for n in ("Bb3", "D4", "F4")]
    return subtractive(chord, 0.75, gate=0.5, amp=(0.04, 0.5, 0.85, 0.12), cutoff=500, sweep=3200,
                       fenv=(0.11, 0.25, 0.55, 0.12), resonance=0.12, detune=0.006, drive=1.8)


def obx_jump() -> list[float]:
    track: list[float] = []
    chord = [hz(n) for n in ("G3", "C4", "D4", "G4")]
    for at in (0.0, 0.2):
        stab = subtractive(chord, 0.22, gate=0.14, amp=(0.004, 0.2, 0.8, 0.05), cutoff=1800, sweep=3500,
                           fenv=(0.003, 0.1, 0.3, 0.05), resonance=0.1, detune=0.008, drive=1.6)
        place(track, stab, at)
    return track


def cs80_blade() -> list[float]:
    def bend(t: float) -> float:
        return 2 ** (-2 / 12 * math.exp(-t / 0.09))  # rises a whole tone into the note
    return subtractive([hz("A3"), hz("E4")], 1.1, gate=0.8, amp=(0.07, 0.5, 0.85, 0.25), cutoff=450,
                       sweep=2400, fenv=(0.25, 0.4, 0.6, 0.25), resonance=0.25, detune=0.007,
                       shapes=("saw", "pulse"), glide=bend, vibrato=0.006)


def ppg_wave() -> list[float]:
    f, seconds = hz("E4"), 0.9
    out = []
    phases = [0.0] * 24
    for n in range(int(seconds * RATE)):
        t = n / RATE
        centre = 1 + 13 * (t / seconds)  # the wavetable position sweeps up its harmonics
        value = 0.0
        for k in range(1, 25):
            if k * f > RATE * 0.45:
                break
            weight = math.exp(-((k - centre) / 2.2) ** 2) + (0.6 if k == 1 else 0.0)
            phases[k - 1] = (phases[k - 1] + k * f / RATE) % 1.0
            value += weight * math.sin(2 * math.pi * phases[k - 1])
        out.append(value * adsr(t, 0.6, 0.005, 0.5, 0.7, 0.25))
    # the PPG's 8-bit grain, lightly
    return [round(v * 48) / 48 for v in out]


def d50_fantasia() -> list[float]:
    track = subtractive([hz(n) for n in ("C4", "E4", "G4")], 1.4, gate=1.0, amp=(0.15, 0.8, 0.7, 0.35),
                        cutoff=700, sweep=900, fenv=(0.3, 0.6, 0.5, 0.3), resonance=0.1, detune=0.006)
    track = chorus(track, mix=0.4)
    for note, at in (("C5", 0.0), ("G5", 0.09), ("E6", 0.18)):  # the bell "attack" sparkle
        f = hz(note)
        bell = [(math.sin(2 * math.pi * f * n / RATE) + 0.5 * math.sin(2 * math.pi * f * 2.76 * n / RATE)
                 + 0.25 * math.sin(2 * math.pi * f * 5.4 * n / RATE)) * math.exp(-n / RATE / 0.25)
                for n in range(int(0.9 * RATE))]
        place(track, bell, at, 0.35)
    return track


def m1_piano() -> list[float]:
    track: list[float] = []
    for name in ("C4", "Eb4", "G4", "Bb4"):
        f = hz(name)
        note = []
        for n in range(int(0.8 * RATE)):
            t = n / RATE
            v = 0.0
            for k in range(1, 12):
                partial = f * k * (1 + 0.0004 * k * k)  # a piano's stretched partials
                if partial > RATE * 0.45:
                    break
                # staggered phases, so the partials do not all spike together at the strike
                v += math.sin(2 * math.pi * partial * t + 2.4 * k) / k ** 0.7 * math.exp(-t * (1.0 + 0.9 * k))
            note.append(v * min(t / 0.004, 1.0))
        place(track, note, 0.0, 0.5)
    click = [((n * 7919) % 97 / 48.5 - 1.0) * math.exp(-n / RATE / 0.004) for n in range(int(0.02 * RATE))]
    place(track, click, 0.0, 0.06)  # the hammer
    return track


def alpha_hoover() -> list[float]:
    def dive(t: float) -> float:
        return 2 ** ((-7 * math.exp(-t / 0.08) + 0.4 * math.sin(2 * math.pi * 3 * t) * min(t / 0.2, 1)) / 12)
    voice = subtractive([hz("C3"), hz("C4")], 0.7, gate=0.5, amp=(0.01, 0.3, 0.8, 0.12), cutoff=2600,
                        sweep=1500, fenv=(0.01, 0.2, 0.4, 0.12), resonance=0.05,
                        shapes=("pulse", "saw", "pulse", "saw", "pulse"), detune=0.012, pwm=0.35,
                        glide=dive, drive=1.8)
    return chorus(voice, depth_ms=2.5, mix=0.5)


def odyssey_sync() -> list[float]:
    track: list[float] = []
    for name, at, length in (("E4", 0.0, 0.2), ("A4", 0.18, 0.4)):
        f = hz(name)
        master, slave, ladder, out = 0.0, 0.0, Ladder(), []
        for n in range(int(length * RATE)):
            t = n / RATE
            ratio = 1.0 + 2.6 * min(t / length, 1.0)  # the synced oscillator sweeps up
            master += f / RATE
            slave += f * ratio / RATE
            if master >= 1.0:  # hard sync: the master resets the slave
                master -= 1.0
                slave = master * ratio
            slave %= 1.0
            raw = 2.0 * slave - 1.0
            out.append(ladder.next(raw, 3200, 0.2, 1.4) * adsr(t, length - 0.05, 0.004, 0.3, 0.8, 0.04))
        place(track, out, at)
    return track


def mellotron_flute() -> list[float]:
    track: list[float] = []
    hiss = noise(7)
    for name, at, length in (("C4", 0.0, 0.25), ("E4", 0.2, 0.25), ("G4", 0.4, 0.5)):
        f, phase, breath, out = hz(name), 0.0, SVF(), []
        for n in range(int(length * RATE)):
            t = n / RATE
            wow = 1.0 + 0.003 * math.sin(2 * math.pi * 0.8 * (at + t)) + 0.0015 * math.sin(2 * math.pi * 7 * t)
            phase = (phase + f * wow / RATE) % 1.0
            tone = math.sin(2 * math.pi * phase) + 0.12 * math.sin(4 * math.pi * phase)
            air = breath.next(next(hiss), f * 2, 2.0)[1]
            out.append((tone + 0.35 * air) * adsr(t, length - 0.08, 0.05, 0.3, 0.85, 0.08))
        place(track, out, at, 0.7)
    tape = noise(11)
    return [v + 0.004 * next(tape) for v in track]


def fairlight_orch() -> list[float]:
    chord = [hz(n) for n in ("C3", "C4", "E4", "G4")]
    hit = subtractive(chord, 0.6, gate=0.08, amp=(0.002, 0.15, 0.3, 0.25), cutoff=2400, sweep=4000,
                      fenv=(0.002, 0.12, 0.2, 0.2), resonance=0.05, detune=0.01,
                      shapes=("saw", "pulse", "saw"), drive=2.0)
    burst = noise(3)
    for n in range(int(0.05 * RATE)):  # the timpani-and-cymbal smack at the front
        hit[n] += 0.5 * next(burst) * math.exp(-n / RATE / 0.015)
    # the Fairlight's 8-bit, roughly 16 kHz sampling
    out, held = [], 0.0
    for n, v in enumerate(hit):
        if n % 3 == 0:
            held = round(v * 96) / 96
        out.append(held)
    return out


def jupiter_arp() -> list[float]:
    track: list[float] = []
    for k, name in enumerate(("C4", "E4", "G4", "C5", "G4", "C5")):
        note = subtractive([hz(name)], 0.16, gate=0.06, amp=(0.002, 0.08, 0.5, 0.05), cutoff=900, sweep=3200,
                           fenv=(0.002, 0.07, 0.15, 0.05), resonance=0.35, detune=0.003,
                           shapes=("pulse", "saw"), drive=1.6)
        place(track, note, 0.075 * k, 0.9 if k < 5 else 1.0)
    return track


def sh101_zap() -> list[float]:
    def dive(t: float) -> float:
        return 6.0 * math.exp(-t / 0.06) + 0.6  # from about A6 down to about F3
    return subtractive([hz("A4")], 0.32, gate=0.24, amp=(0.002, 0.2, 0.7, 0.06), cutoff=1500, sweep=3500,
                       fenv=(0.002, 0.15, 0.2, 0.06), resonance=0.45, detune=0.0, shapes=("pulse",),
                       glide=dive, drive=1.6)


def emulator_choir() -> list[float]:
    track: list[float] = []
    formants = ((800, 1.0, 6.0), (1150, 0.5, 8.0), (2900, 0.25, 10.0))  # an "aah"
    for name in ("A3", "C#4", "E4"):
        f, osc, filters, out = hz(name), Osc("saw"), [SVF() for _ in formants], []
        for n in range(int(1.1 * RATE)):
            t = n / RATE
            pitch = f * (1.0 + 0.007 * math.sin(2 * math.pi * 5.2 * t) * min(t / 0.25, 1.0))
            x = osc.next(pitch)
            voice = sum(level * flt.next(x, fc, q)[1] for (fc, level, q), flt in zip(formants, filters))
            out.append(voice * adsr(t, 0.8, 0.12, 0.5, 0.9, 0.25))
        place(track, out, 0.0, 0.6)
    return chorus(track, mix=0.35)


def jp8000_supersaw() -> list[float]:
    chord = [hz(n) for n in ("A3", "C4", "E4", "A4")]
    voice = subtractive(chord, 0.55, gate=0.3, amp=(0.003, 0.25, 0.75, 0.15), cutoff=3000, sweep=2500,
                        fenv=(0.003, 0.15, 0.4, 0.15), resonance=0.05, detune=0.007,
                        shapes=("saw",) * 7, drive=1.3)
    return chorus(voice, depth_ms=2.0, mix=0.4)


def synclavier_bell() -> list[float]:
    f = hz("G4")
    partials = ((1.0, 1.0, 1.2), (2.0, 0.6, 0.8), (2.4, 0.45, 0.5), (3.0, 0.3, 0.45),
                (4.07, 0.25, 0.3), (5.4, 0.15, 0.2), (6.8, 0.1, 0.12))  # ratio, level, seconds
    out = []
    for n in range(int(1.5 * RATE)):
        t = n / RATE
        v = sum(level * math.sin(2 * math.pi * f * ratio * t) * math.exp(-t / tau) for ratio, level, tau in partials)
        out.append(v * min(t / 0.002, 1.0))
    return out


def buchla_bongo() -> list[float]:
    track: list[float] = []
    for name, at in (("C4", 0.0), ("G4", 0.12), ("D4", 0.24)):
        f, gate_filter, out = hz(name), SVF(), []
        for n in range(int(0.35 * RATE)):
            t = n / RATE
            vactrol = math.exp(-t / 0.07) * min(t / 0.001, 1.0)  # the low-pass gate's slow-ish light cell
            tone = math.sin(2 * math.pi * f * t)
            folded = math.sin(2.5 * vactrol * tone * math.pi / 2)  # the wavefolder, harder when louder
            low, _ = gate_filter.next(folded, 150 + 5000 * vactrol, 0.8)
            out.append(low * vactrol)
        place(track, out, at, 0.9)
    return track


def omnichord_strum() -> list[float]:
    track: list[float] = []
    names = ("C4", "E4", "G4", "C5", "E5", "G5", "C6")
    for k, name in enumerate(names):
        f = hz(name)
        pluck = [(math.sin(2 * math.pi * f * n / RATE) + 0.3 * math.sin(4 * math.pi * f * n / RATE))
                 * math.exp(-n / RATE / 0.5) * min(n / RATE / 0.002, 1.0) for n in range(int(1.0 * RATE))]
        place(track, pluck, 0.035 * k, 0.55 - 0.04 * k)
    return chorus(track, depth_ms=1.0, mix=0.3)


TONES = {
    "juno-pad": juno_pad, "tb303-acid": tb303_acid, "prophet-brass": prophet_brass, "obx-jump": obx_jump,
    "cs80-blade": cs80_blade, "ppg-wave": ppg_wave, "d50-fantasia": d50_fantasia, "m1-piano": m1_piano,
    "alpha-hoover": alpha_hoover, "odyssey-sync": odyssey_sync, "mellotron-flute": mellotron_flute,
    "fairlight-orch": fairlight_orch, "jupiter-arp": jupiter_arp, "sh101-zap": sh101_zap,
    "emulator-choir": emulator_choir, "jp8000-supersaw": jp8000_supersaw, "synclavier-bell": synclavier_bell,
    "buchla-bongo": buchla_bongo, "omnichord-strum": omnichord_strum,
}


def finish(track: list[float], fade: float = 0.03) -> list[float]:
    """Fade the last moments to silence and scale to -3 dBFS peak."""
    count = min(int(fade * RATE), len(track))
    for i in range(count):
        track[-count + i] *= 1.0 - i / count
    peak = max(abs(v) for v in track) or 1.0
    return [v * 0.708 / peak for v in track]


def main() -> None:
    for name in sys.argv[1:] or TONES:
        track = finish(TONES[name]())
        path = OUT / f"{name}.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in track))
        print(f"wrote {path} ({len(track) / RATE:.2f} s)")


if __name__ == "__main__":
    main()
