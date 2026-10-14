"""The sound library: bundled tones plus the user's own files."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from importlib import resources
from pathlib import Path

SUFFIXES = (".wav", ".aiff", ".aif", ".flac", ".mp3", ".ogg", ".caf")
MAX_BYTES = 10_000_000
RESERVED = {"none", "synth"}
_BAD_CHARACTERS = re.compile(r"[^A-Za-z0-9 _.\-]")


class SoundError(Exception):
    """A sound could not be added."""


def _builtin_dir() -> Path:
    return Path(str(resources.files("z_iris").joinpath("sounds")))


def builtin_names() -> list[str]:
    return sorted(p.stem for p in _builtin_dir().glob("*.wav"))


def library(user_dir: Path | None) -> dict[str, Path]:
    """Map sound names to files. User files win over bundled tones.

    "synth" stays as an alias for "chime", the name old configs used.
    """
    sounds = {p.stem: p for p in _builtin_dir().glob("*.wav")}
    sounds["synth"] = sounds["chime"]
    if user_dir is not None and user_dir.is_dir():
        for path in sorted(user_dir.iterdir()):
            if (
                path.suffix.lower() in SUFFIXES
                and path.is_file()
                and not path.name.startswith(".")
            ):
                sounds[path.stem] = path
    return sounds


def user_names(user_dir: Path | None) -> list[str]:
    if user_dir is None or not user_dir.is_dir():
        return []
    return sorted(
        p.stem
        for p in user_dir.iterdir()
        if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in SUFFIXES
    )


def add_sound(user_dir: Path, filename: str, data: bytes) -> str:
    """Store an uploaded sound and return its name. Raises SoundError."""
    if len(data) > MAX_BYTES:
        raise SoundError("file is too large (10 MB limit)")
    if "/" in filename or "\\" in filename or filename.startswith("."):
        raise SoundError("bad file name")
    suffix = Path(filename).suffix.lower()
    if suffix not in SUFFIXES:
        raise SoundError(f"file type must be one of {', '.join(SUFFIXES)}")
    name = _BAD_CHARACTERS.sub("", Path(filename).stem).strip(" .")
    if not name or name.lower() in RESERVED:
        raise SoundError("bad sound name")
    taken = {n.lower() for n in library(user_dir)}
    if name.lower() in taken:
        raise SoundError(f'a sound named "{name}" already exists; rename the file')

    user_dir.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=user_dir, suffix=suffix, prefix=".upload-")
    try:
        with os.fdopen(handle, "wb") as file:
            file.write(data)
        try:
            probe = subprocess.run(
                ["soxi", "-D", temporary], capture_output=True, text=True, timeout=10
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise SoundError(f"cannot check the file: {error}") from error
        if probe.returncode != 0:
            raise SoundError("sox cannot play this file")
        # Store the sound normalized, as a wav, and keep the file as uploaded.
        from z_iris.loudness import write_normalized

        stored = user_dir / f"{name}.wav"
        converted = user_dir / f".convert-{name}.wav"
        try:
            write_normalized(Path(temporary), converted)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            raise SoundError(str(error)) from error
        originals = user_dir / "originals"
        originals.mkdir(exist_ok=True)
        shutil.copyfile(temporary, originals / f"{name}{suffix}")
        os.replace(converted, stored)
    finally:
        for leftover in (temporary, str(user_dir / f".convert-{name}.wav")):
            if os.path.exists(leftover):
                os.unlink(leftover)
    return name


def delete_sound(user_dir: Path, name: str) -> None:
    """Delete one of the user's own sounds and its saved original."""
    if name not in user_names(user_dir):
        if name in library(None):
            raise SoundError(f'"{name}" is a bundled tone and cannot be deleted')
        raise SoundError(f'no sound of yours is named "{name}"')
    for path in list(user_dir.iterdir()):
        if path.is_file() and path.stem == name and path.suffix.lower() in SUFFIXES:
            path.unlink()
    originals = user_dir / "originals"
    if originals.is_dir():
        for path in list(originals.iterdir()):
            if path.is_file() and path.stem == name:
                path.unlink()
