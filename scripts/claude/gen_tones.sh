#!/bin/sh
# Purpose: regenerate the bundled tones in src/z_iris/sounds with sox.
# Date: 2026-10-14
# Usage: scripts/claude/gen_tones.sh   (needs sox; run from the repo root)
set -eu
out=src/z_iris/sounds
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# note FILE SHAPE FREQ SECONDS: one faded note at -3 dB headroom.
note() { sox -n -r 44100 -c 1 "$1" synth "$4" "$2" "$3" fade q 0.005 "$4" 0.03 gain -3; }
# join OUT PARTS...: concatenate notes.
join() { o=$1; shift; sox "$@" "$o"; }

note "$out/chime.wav" sine 880 0.15
note "$out/ping.wav" sine 1320 0.12
note "$out/blip.wav" square 660 0.05
note "$out/low.wav" sine 220 0.30
note "$out/soft.wav" triangle 523 0.25

# bell: a fundamental with a decaying octave
sox -n -r 44100 -c 1 "$out/bell.wav" synth 0.7 sine 880 synth 0.7 sine mix 1760 \
    fade q 0.003 0.7 0.6 gain -6

# knock: filtered noise burst
sox -n -r 44100 -c 1 "$out/knock.wav" synth 0.09 brownnoise lowpass 600 \
    fade q 0.002 0.09 0.06 gain -1

# sweeps
sox -n -r 44100 -c 1 "$out/rise.wav" synth 0.25 sine 600-1200 fade q 0.01 0.25 0.05 gain -3
sox -n -r 44100 -c 1 "$out/fall.wav" synth 0.25 sine 1200-600 fade q 0.01 0.25 0.05 gain -3

# repeats and alternations
note "$work/p.wav" sine 1320 0.09
sox -n -r 44100 -c 1 "$work/gap.wav" trim 0 0.07
join "$out/double.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav"
join "$out/triple.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav" "$work/gap.wav" "$work/p.wav"

note "$work/hi.wav" sine 880 0.12
note "$work/lo.wav" sine 660 0.12
join "$out/alert.wav" "$work/hi.wav" "$work/lo.wav" "$work/hi.wav" "$work/lo.wav"

note "$work/u.wav" square 1000 0.06
join "$out/urgent.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav" "$work/gap.wav" "$work/u.wav"

ls -l "$out"
