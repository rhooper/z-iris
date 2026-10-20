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
def test_the_launcher_is_a_signed_native_executable_that_runs_z_iris(tmp_path):
    dest = tmp_path / "z-iris.app"
    result = run(dest)
    assert result.returncode == 0, result.stderr
    launcher = dest / "Contents" / "MacOS" / "z-iris"
    # A script that execs another binary makes macOS list the menubar item
    # under whatever launched it, so the bundle's executable must be Mach-O.
    data = launcher.read_bytes()
    assert data[:4] == b"\xcf\xfa\xed\xfe"
    assert b"/opt/homebrew/bin" in data and b"/usr/local/bin" in data
    signature = subprocess.run(
        ["codesign", "-dv", str(dest)], capture_output=True, text=True
    ).stderr
    assert "Identifier=ca.toybox.z-iris" in signature
    help_text = subprocess.run(
        [str(launcher), "--help"], capture_output=True, text=True
    ).stdout
    assert help_text.startswith("usage: z-iris")


@pytest.mark.skipif(
    not Path("/opt/homebrew/opt/python@3.13").exists(), reason="needs Homebrew Python 3.13"
)
def test_the_priority_app_is_built_beside_z_iris(tmp_path):
    import plistlib

    result = run(tmp_path / "z-iris.app")
    assert result.returncode == 0, result.stderr
    app = tmp_path / "z-iris-priority.app"
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "ca.toybox.z-iris.priority"
    assert info["CFBundleExecutable"] == "z-iris-priority"
    assert info["CFBundleDisplayName"] == "z-iris priority"
    assert info["NSUserNotificationAlertStyle"] == "alert"
    assert info["LSUIElement"] is True
    executable = app / "Contents" / "MacOS" / "z-iris-priority"
    assert executable.read_bytes()[:4] == b"\xcf\xfa\xed\xfe"
    assert b"z_iris.priority" in executable.read_bytes()
    signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True).stderr
    assert "Identifier=ca.toybox.z-iris.priority" in signature
    main = plistlib.loads((tmp_path / "z-iris.app" / "Contents" / "Info.plist").read_bytes())
    assert "NSUserNotificationAlertStyle" not in main
