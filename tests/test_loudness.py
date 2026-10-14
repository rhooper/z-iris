import math
import shutil
import subprocess

import pytest

from z_iris.loudness import (
    TARGET_RMS, gain_for, levels, normalize_directory, normalize_file, parse_stat,
)
from z_iris.sounds import add_sound, builtin_names, library

pytestmark = pytest.mark.skipif(shutil.which("sox") is None, reason="needs sox")


def sine(path, amplitude, seconds="0.3"):
    subprocess.run(
        ["sox", "-n", str(path), "synth", seconds, "sine", "440", "vol", str(amplitude)],
        check=True,
    )
    return path


def db(a, b):
    return abs(20 * math.log10(a / b))


def test_parse_stat():
    text = "Maximum amplitude:     0.500000\nRMS     amplitude:     0.250000\n"
    assert parse_stat(text) == (0.5, 0.25)
    assert parse_stat("garbage") is None


def test_gain_reaches_the_target_but_never_clips():
    assert gain_for(0.5, 0.1) == pytest.approx(TARGET_RMS / 0.1) or gain_for(0.5, 0.1) == pytest.approx(1 / 0.5)
    assert gain_for(0.9, 0.05) == pytest.approx(1 / 0.9)
    assert gain_for(0.0, 0.0) == 1.0


def test_normalize_file_stores_a_louder_or_quieter_file_at_the_target(tmp_path):
    for amplitude in (0.1, 0.8):
        path = sine(tmp_path / f"s{amplitude}.wav", amplitude)
        normalize_file(path, tmp_path / "originals")
        peak, rms = levels(path)
        assert rms == pytest.approx(TARGET_RMS, rel=0.06)
        assert peak <= 1.0
    assert (tmp_path / "originals" / "s0.1.wav").is_file()


def test_normalizing_twice_changes_nothing(tmp_path):
    path = sine(tmp_path / "a.wav", 0.2)
    normalize_file(path, tmp_path / "o")
    first = path.read_bytes()
    assert normalize_file(path, tmp_path / "o") == (path, False)
    assert path.read_bytes() == first


def test_a_peaky_file_is_limited_by_its_peak(tmp_path):
    click = tmp_path / "c.wav"
    subprocess.run(["sox", "-n", str(click), "synth", "0.002", "square", "1000", "pad", "0", "0.5"], check=True)
    normalize_file(click, tmp_path / "o")
    peak, rms = levels(click)
    assert peak <= 1.0 and rms < TARGET_RMS


def test_normalize_directory_converts_other_formats_to_wav_and_keeps_originals(tmp_path):
    wav = sine(tmp_path / "src.wav", 0.1)
    flac = tmp_path / "tune.flac"
    subprocess.run(["sox", str(wav), str(flac)], check=True)
    wav.unlink()
    changed = normalize_directory(tmp_path)
    assert [p.name for _, p in changed] == ["tune.wav"]
    assert not flac.exists() and (tmp_path / "originals" / "tune.flac").is_file()
    assert levels(tmp_path / "tune.wav")[1] == pytest.approx(TARGET_RMS, rel=0.06)
    assert normalize_directory(tmp_path) == []


def test_uploads_are_stored_normalized_with_the_original_kept(tmp_path):
    quiet = sine(tmp_path / "q.wav", 0.05)
    name = add_sound(tmp_path / "sounds", "Quiet One.wav", quiet.read_bytes())
    stored = library(tmp_path / "sounds")[name]
    assert levels(stored)[1] == pytest.approx(TARGET_RMS, rel=0.06)
    assert (tmp_path / "sounds" / "originals" / "Quiet One.wav").read_bytes() == quiet.read_bytes()


def test_bundled_tones_are_stored_normalized():
    for name in builtin_names():
        peak, rms = levels(library(None)[name])
        limited = peak >= 0.98
        assert limited or db(rms, TARGET_RMS) < 0.5, (name, peak, rms)
