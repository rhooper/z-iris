# /// script
# dependencies = ["emoji==2.16.0"]
# ///
"""Write the app's emoji table (ZIrisCore/Resources/emoji.json): shortcode
name -> emoji, Zulip's names first and then the emoji package's aliases, as
the Python version looked them up. Rerun after make_zulip_emoji.py.

2026-10-26. Usage: uv run scripts/claude/dump_emoji.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import emoji

ROOT = Path(__file__).resolve().parents[2]
ZULIP = ROOT / "swift/Resources/zulip_emoji.json"
OUT = ROOT / "swift/Sources/ZIrisCore/Resources/emoji.json"


def main() -> None:
    table = {}
    for data in emoji.EMOJI_DATA.values():
        for name in [data["en"], *data.get("alias", [])]:
            char = emoji.emojize(name, language="alias")
            if char != name:
                table[name.strip(":")] = char
    table.update(json.loads(ZULIP.read_text(encoding="utf-8")))
    # Only names plaintext's shortcode pattern can match.
    table = {name: char for name, char in table.items() if re.fullmatch(r"[\w+\-]+", name)}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(table, ensure_ascii=False, sort_keys=True, indent=0)
    OUT.write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
