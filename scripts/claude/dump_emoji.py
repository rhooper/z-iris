"""Write the Swift port's emoji table: shortcode name -> emoji.

plaintext.expand_emoji looks a name up in Zulip's names first, then asks the
emoji package (language="alias"). This merges both into one map with the
same answers, so the Swift version needs no emoji package. Rerun after
make_zulip_emoji.py or an emoji upgrade (check_fixtures.sh checks).

2026-10-26. Usage: uv run python scripts/claude/dump_emoji.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import emoji

ROOT = Path(__file__).resolve().parents[2]
ZULIP = ROOT / "src/z_iris/static/zulip_emoji.json"
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
