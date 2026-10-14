import shutil
import subprocess

import pytest

from z_iris.sounds import SoundError, add_sound, builtin_names, library

needs_sox = pytest.mark.skipif(shutil.which("sox") is None, reason="needs sox")


def make_wav(path):
    subprocess.run(["sox", "-n", str(path), "synth", "0.1", "sine", "440"], check=True)
    return path.read_bytes()


def test_builtin_tones_are_bundled_and_exist():
    names = builtin_names()
    assert {"chime", "ping", "bell", "urgent", "double"} <= set(names)
    assert all(path.is_file() for path in library(None).values())


def test_synth_is_an_alias_for_chime():
    lib = library(None)
    assert lib["synth"] == lib["chime"]


def test_user_sounds_are_found_by_file_name_and_win_over_builtins(tmp_path):
    (tmp_path / "klaxon.wav").write_bytes(b"x")
    (tmp_path / "chime.wav").write_bytes(b"x")
    (tmp_path / "notes.txt").write_text("not a sound")
    lib = library(tmp_path)
    assert lib["klaxon"] == tmp_path / "klaxon.wav"
    assert lib["chime"] == tmp_path / "chime.wav"
    assert "notes" not in lib


@needs_sox
def test_add_sound_stores_a_playable_file_and_returns_its_name(tmp_path):
    data = make_wav(tmp_path / "src.wav")
    name = add_sound(tmp_path / "sounds", "My Alarm!.wav", data)
    assert name == "My Alarm"
    assert (tmp_path / "sounds" / "My Alarm.wav").is_file()
    assert (tmp_path / "sounds" / "originals" / "My Alarm.wav").read_bytes() == data
    assert "My Alarm" in library(tmp_path / "sounds")


@needs_sox
def test_add_sound_rejects_bad_names_types_and_garbage(tmp_path):
    good = make_wav(tmp_path / "src.wav")
    sounds = tmp_path / "sounds"
    for filename in ["../evil.wav", "a.exe", "noext", ".wav", "none.wav"]:
        with pytest.raises(SoundError):
            add_sound(sounds, filename, good)
    with pytest.raises(SoundError, match="play"):
        add_sound(sounds, "junk.wav", b"this is not audio")
    with pytest.raises(SoundError, match="large"):
        add_sound(sounds, "big.wav", b"0" * (10_000_001))
    assert not list(sounds.glob("*")) if sounds.exists() else True
