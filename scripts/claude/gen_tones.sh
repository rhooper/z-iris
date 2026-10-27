#!/bin/sh
# Purpose: regenerate the bundled tones in swift/Resources/sounds with sox.
# Date: 2026-10-14; tones refined 2026-10-27
# Usage: scripts/claude/gen_tones.sh   (needs sox and Swift; run from the repo root)
set -eu
out=swift/Resources/sounds
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# note FILE SHAPE FREQ SECONDS: one faded note at -3 dB headroom.
note() { sox -n -r 44100 -c 1 "$1" synth "$4" "$2" "$3" fade q 0.005 "$4" 0.03 gain -3; }
# chord FILE SECONDS FREQ[:DB] ...: sines mixed, each at its own level (dB
# below the first), with a soft attack and a decay over the whole note, so a
# tone rings out instead of stopping.
chord() {
    o=$1; len=$2; shift 2
    parts=""
    for spec in "$@"; do
        f=${spec%%:*}; db=0
        [ "$spec" != "$f" ] && db=${spec#*:}
        sox -n -r 44100 -c 1 "$work/part-$f.wav" synth "$len" sine "$f" gain "$db"
        parts="$parts $work/part-$f.wav"
    done
    # shellcheck disable=SC2086
    sox -m $parts "$o" fade q 0.006 "$len" "$(echo "$len * 0.85" | bc)" gain -n -3
}
# join OUT PARTS...: concatenate notes.
join() { o=$1; shift; sox "$@" "$o"; }

# Single tones, an octave lower than they were or with soft harmony above,
# so none is a thin, piercing sine.
chord "$out/chime.wav" 0.35 440 659.3:-8 880:-14          # A4 with its fifth and octave
chord "$out/ping.wav" 0.25 659.3 1318.5:-12               # E5 (was E6)
sox -n -r 44100 -c 1 "$work/blip-sq.wav" synth 0.06 square 660 lowpass 2500 fade q 0.003 0.06 0.03
sox -n -r 44100 -c 1 "$work/blip-lo.wav" synth 0.06 sine 330 fade q 0.003 0.06 0.03
sox -m "$work/blip-sq.wav" "$work/blip-lo.wav" "$out/blip.wav" gain -n -3   # softened square, octave below
chord "$out/low.wav" 0.4 220 440:-6 660:-14               # A3, with partials laptops can play
sox -n -r 44100 -c 1 "$work/soft-a.wav" synth 0.35 triangle 523.3
sox -n -r 44100 -c 1 "$work/soft-b.wav" synth 0.35 triangle 659.3 gain -8
sox -m "$work/soft-a.wav" "$work/soft-b.wav" "$out/soft.wav" fade q 0.01 0.35 0.3 gain -n -3   # C5 and its third
chord "$out/mid-short.wav" 0.2 261.63 392:-8 523.3:-14    # middle C with its fifth, 200 ms
chord "$out/mid-long.wav" 0.35 261.63 392:-8 523.3:-14    # the same, 350 ms

# bell: a church-bell spectrum on A4 (hum, prime, minor third, fifth,
# nominal), an octave below the old two-sine bell, ringing out
sox -n -r 44100 -c 1 "$out/bell.wav" synth 1.0 sine 440 synth 1.0 sine mix 220 synth 1.0 sine mix 528 \
    synth 1.0 sine mix 660 synth 1.0 sine mix 880 fade q 0.003 1.0 0.95 gain -n -3

# knock: a short tap, white noise band-passed around 1.6 kHz, with a faint
# 1.1 kHz body so it reads as a wooden tock rather than a hiss
sox -n -r 44100 -c 1 "$work/tap.wav" synth 0.09 whitenoise bandpass 1600 500 \
    fade q 0.001 0.09 0.05
sox -n -r 44100 -c 1 "$work/body.wav" synth 0.09 sine 1100 vol 0.5 fade q 0.001 0.09 0.06
sox -m "$work/tap.wav" "$work/body.wav" "$out/knock.wav" gain -3

# sweeps, an octave lower, with the octave above sweeping alongside
sox -n -r 44100 -c 1 "$work/r1.wav" synth 0.3 sine 300-600
sox -n -r 44100 -c 1 "$work/r2.wav" synth 0.3 sine 600-1200 gain -10
sox -m "$work/r1.wav" "$work/r2.wav" "$out/rise.wav" fade q 0.01 0.3 0.08 gain -n -3
sox -n -r 44100 -c 1 "$work/f1.wav" synth 0.3 sine 600-300
sox -n -r 44100 -c 1 "$work/f2.wav" synth 0.3 sine 1200-600 gain -10
sox -m "$work/f1.wav" "$work/f2.wav" "$out/fall.wav" fade q 0.01 0.3 0.08 gain -n -3

# repeats and alternations, built from the new ping
chord "$work/p.wav" 0.12 659.3 1318.5:-12
sox -n -r 44100 -c 1 "$work/gap.wav" trim 0 0.07
join "$out/double.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav"
join "$out/triple.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav"

chord "$work/hi.wav" 0.14 440 880:-10                     # A4 / E4, an octave down
chord "$work/lo.wav" 0.14 329.6 659.3:-10
join "$out/alert.wav" "$work/hi.wav" "$work/lo.wav" "$work/hi.wav" "$work/lo.wav"

# urgent keeps the square's bite, an octave lower and with its harshest top cut
sox -n -r 44100 -c 1 "$work/u.wav" synth 0.06 square 500 lowpass 4000 fade q 0.002 0.06 0.02 gain -3
join "$out/urgent.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav"

# Store every tone at the same loudness (ZIrisCore/Loudness.swift).
(cd swift && swift run z-iris normalize --dir Resources/sounds --no-backup)
ls -l "$out"
