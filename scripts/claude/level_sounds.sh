#!/bin/sh
# Purpose: level every bundled sound to the same loudness as heard (z-iris
#          normalize: -13 LUFS momentary, ITU-R BS.1770), then report each
#          sound's loudness and peak, measured independently as a check.
# Date: 2026-10-28
# Usage: scripts/claude/level_sounds.sh   (from the repo root; needs Swift and uv)
set -eu
dir=swift/Resources/sounds
(cd swift && swift run -q z-iris normalize --dir Resources/sounds --no-backup)
uv run -q --with numpy --with scipy --with soundfile scripts/claude/measure_loudness.py "$dir" -13
