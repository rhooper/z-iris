import shutil
import subprocess

import pytest

from z_iris.loudness import TARGET_RMS, Loudness, parse_stat

pytestmark = pytest.mark.skipif(shutil.which("sox") is None, reason="needs sox")


def tone(path, amplitude, seconds="0.2", shape="sine", freq="440"):
    subprocess.run(
        ["sox", "-n", str(path), "synth", seconds, shape, freq, "gain", "-n", "0"],
        check=True,
    )
    subprocess.run(["sox", str(path), str(path) + ".x.wav", "vol", str(amplitude)], check=True)
    return type(path)(str(path) + ".x.wav")


def levels(path, gain):
    out = subprocess.run(
        ["sox", str(path), "-n", "vol", f"{gain:.6f}", "stat"], capture_output=True, text=True
    ).stderr
    return parse_stat(out)


def test_parse_stat():
    text = "Maximum amplitude:     0.500000\nRMS     amplitude:     0.250000\n"
    assert parse_stat(text) == (0.5, 0.25)
    assert parse_stat("garbage") is None


def test_quiet_and_loud_files_land_on_the_same_loudness(tmp_path):
    quiet = tone(tmp_path / "q.wav", 0.1)
    loud = tone(tmp_path / "l.wav", 0.5)
    n = Loudness()
    rq = levels(quiet, n.gain(quiet))[1]
    rl = levels(loud, n.gain(loud))[1]
    assert rq == pytest.approx(rl, rel=0.05)
    assert rq == pytest.approx(TARGET_RMS, rel=0.05)


def test_a_peaky_file_is_capped_so_it_never_clips(tmp_path):
    click = tmp_path / "c.wav"
    subprocess.run(["sox", "-n", str(click), "synth", "0.002", "square", "1000", "pad", "0", "0.5"], check=True)
    gain = Loudness().gain(click)
    peak, rms = levels(click, gain)
    assert peak <= 1.0001
    assert rms < TARGET_RMS  # limited by the peak, not boosted into clipping


def test_results_are_cached_per_file_version(tmp_path):
    calls = []
    n = Loudness(measure=lambda p: calls.append(p) or (0.5, 0.1))
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"x")
    assert n.gain(wav) == n.gain(wav)
    assert len(calls) == 1
    wav.write_bytes(b"xy")
    n.gain(wav)
    assert len(calls) == 2


def test_unreadable_or_silent_files_get_unity_gain(tmp_path):
    assert Loudness(measure=lambda p: None).gain(tmp_path / "x.wav") == 1.0
    assert Loudness(measure=lambda p: (0.0, 0.0)).gain(tmp_path / "y.wav") == 1.0
    (tmp_path / "z.wav").write_bytes(b"x")
    assert Loudness(measure=lambda p: (0.0, 0.0)).gain(tmp_path / "z.wav") == 1.0
