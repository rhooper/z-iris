"""Restart z-iris when its source changes. For development."""

from __future__ import annotations

import subprocess
import time
from collections.abc import Callable, Sequence
from pathlib import Path

WATCHED = {".py", ".html"}


def snapshot(root: Path) -> dict[Path, int]:
    found = {}
    for path in root.rglob("*"):
        if path.suffix in WATCHED and "__pycache__" not in path.parts:
            try:
                found[path] = path.stat().st_mtime_ns
            except OSError:
                pass
    return found


def _stop(child: subprocess.Popen) -> None:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def run(
    command: Sequence[str],
    root: Path,
    poll: float = 0.5,
    settle: float = 0.3,
    stop: Callable[[], bool] = lambda: False,
    out: Callable[[str], None] = lambda message: print(message, flush=True),
) -> int:
    """Run command, and restart it whenever a watched file under root changes.

    A clean exit (the user chose Quit) ends the run. A crash waits for the next
    change, so fixing the code brings the app back by itself.
    """
    seen = snapshot(root)
    child = subprocess.Popen(list(command))
    announced = False
    try:
        while not stop():
            time.sleep(poll)
            current = snapshot(root)
            if current != seen:
                time.sleep(settle)
                seen = snapshot(root)
                out("z-iris: source changed, restarting")
                _stop(child)
                child = subprocess.Popen(list(command))
                announced = False
                continue
            code = child.poll()
            if code == 0:
                return 0
            if code is not None and not announced:
                out(f"z-iris: exited with {code}; waiting for a change")
                announced = True
        return 0
    except KeyboardInterrupt:
        return 130
    finally:
        _stop(child)
