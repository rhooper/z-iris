"""Screenshot the rule editor with every rule expanded, using headless Chrome.

Serves the editor on a copy of the config (so nothing is changed) and saves a
PNG. For checking the editor's layout without clicking through it.

Date: 2026-10-20
Usage: uv run python scripts/claude/editor_shot.py OUT.png [config.toml] [width] [collapsed]
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from z_iris.config import DEFAULT_PATH, load_config
from z_iris.settings import Settings
from z_iris.webui import EditorServer

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def main(argv: list[str]) -> int:
    out = Path(argv[0]).resolve()
    source = Path(argv[1]) if len(argv) > 1 else DEFAULT_PATH
    width = int(argv[2]) if len(argv) > 2 else 900
    with tempfile.TemporaryDirectory() as work:
        config = Path(work) / "config.toml"
        shutil.copy(source, config)
        if (source.parent / "sounds").is_dir():
            shutil.copytree(source.parent / "sounds", Path(work) / "sounds")
        server = EditorServer(Settings(load_config(config), config), config)
        url = server.start() + ("" if "collapsed" in argv[3:] else "?expand")
        subprocess.run(
            [CHROME, "--headless=new", f"--user-data-dir={work}/chrome", "--hide-scrollbars",
             f"--window-size={width},6000", "--virtual-time-budget=4000",
             f"--screenshot={out}", url],
            check=True, capture_output=True, timeout=60,
        )
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
