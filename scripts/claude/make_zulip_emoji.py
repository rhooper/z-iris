"""Regenerate src/z_iris/static/zulip_emoji.json: Zulip's emoji names (and
aliases) mapped to the emoji they stand for, so :slight_smile: and
:working_on_it: expand the way Zulip shows them.

The source is zulip-terminal's zulipterminal/unicode_emojis.py, which is
generated from the Zulip server's emoji data (Apache-2.0). It is parsed with
ast, never imported or executed.

2026-10-19. Usage:
  uv run python scripts/claude/make_zulip_emoji.py [path/to/unicode_emojis.py]
"""

from __future__ import annotations

import ast
import json
import sys
from pathlib import Path

DEFAULT_SOURCE = Path.home() / "Devel/zulip-terminal/zulipterminal/unicode_emojis.py"
TARGET = Path(__file__).resolve().parents[2] / "src/z_iris/static/zulip_emoji.json"


def emoji_data(source: Path) -> dict:
    tree = ast.parse(source.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "EMOJI_DATA" for t in node.targets
        ):
            return ast.literal_eval(node.value)
    raise SystemExit(f"no EMOJI_DATA in {source}")


def name_map(data: dict) -> dict[str, str]:
    names: dict[str, str] = {}
    for name, entry in data.items():
        char = "".join(chr(int(part, 16)) for part in entry["code"].split("-"))
        # A canonical name wins over another emoji's alias of the same text.
        names[name] = char
        for alias in entry.get("aliases", []):
            names.setdefault(alias, char)
    return dict(sorted(names.items()))


def main(argv: list[str]) -> int:
    source = Path(argv[0]) if argv else DEFAULT_SOURCE
    names = name_map(emoji_data(source))
    TARGET.write_text(json.dumps(names, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    print(f"{len(names)} names -> {TARGET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
