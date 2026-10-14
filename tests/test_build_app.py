import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "claude" / "build_app.sh"


def run(dest):
    return subprocess.run(["bash", str(SCRIPT), str(dest)], capture_output=True, text=True)


def test_a_destination_not_ending_in_app_is_refused_and_untouched(tmp_path):
    victim = tmp_path / "precious"
    victim.mkdir()
    (victim / "keep.txt").write_text("x")
    result = run(victim)
    assert result.returncode != 0 and ".app" in result.stderr
    assert (victim / "keep.txt").exists()


def test_an_app_suffix_with_trailing_slash_or_bare_dot_app_is_checked(tmp_path):
    (tmp_path / "keep").mkdir()
    assert run(tmp_path / "keep").returncode != 0
    assert (tmp_path / "keep").exists()


@pytest.mark.skipif(
    not Path("/opt/homebrew/opt/python@3.13").exists(), reason="needs Homebrew Python 3.13"
)
def test_the_launcher_adds_homebrew_to_path(tmp_path):
    dest = tmp_path / "z-iris.app"
    result = run(dest)
    assert result.returncode == 0, result.stderr
    launcher = (dest / "Contents" / "MacOS" / "z-iris").read_text()
    assert "/opt/homebrew/bin" in launcher and "/usr/local/bin" in launcher
