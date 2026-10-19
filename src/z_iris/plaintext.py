"""Turn Zulip markdown into the plain text a macOS notification can show.

Notifications cannot show bold, links or any other formatting, so the markers
are removed and the useful part kept. Emoji shortcodes become real emoji, which
Apple Color Emoji in the notification renders.
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

import emoji

# Zulip's emoji names, from scripts/claude/make_zulip_emoji.py.
_ZULIP_EMOJI = Path(__file__).parent / "static" / "zulip_emoji.json"

_FENCE = re.compile(r"```[ \t]*([^\n`]*)\n?(.*?)(?:```|\Z)", re.DOTALL)
_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)]*)\)")
_USER = re.compile(r"@(_?)\*\*([^*|]+?)(?:\|\d+)?\*\*")
_GROUP = re.compile(r"@\*([^*\n]+)\*")
_CHANNEL = re.compile(r"#\*\*([^*>]+?)(?:>([^*]+?))?\*\*")
_BOLD = re.compile(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1")
_STRIKE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
_ITALIC_STAR = re.compile(r"(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\w*])")
_ITALIC_UNDER = re.compile(r"(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![\w_])")
_CODE = re.compile(r"`([^`\n]+)`")
_TIME = re.compile(r"<time:[^>]*>")
# Not inside a word, so a:b:c is not read as :b:.
_SHORTCODE = re.compile(r"(?<!\w):([\w+\-]+):(?!\w)")
_RULE = re.compile(r"^\s*([-*_])(?:\s*\1){2,}\s*$")
_LIST = re.compile(r"^(\s*)[-*+]\s+")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+")
_QUOTE = re.compile(r"^\s*>+\s?")


def _fence(match: re.Match) -> str:
    header, body = match.group(1).strip(), match.group(2).strip("\n")
    kind = header.split(" ", 1)[0].lower()
    if kind == "spoiler":
        title = header[len("spoiler"):].strip()
        return f"[spoiler: {title}]" if title else "[spoiler]"
    return f"\n{body}\n"


def _link(match: re.Match) -> str:
    text, target = match.group(1), match.group(2)
    return f"📎 {text}" if target.startswith("/user_uploads/") else text


@functools.cache
def _zulip_names() -> dict[str, str]:
    try:
        return json.loads(_ZULIP_EMOJI.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _shortcode(match: re.Match) -> str:
    # Zulip's names first, so :smile: is the 🙂 Zulip shows, not emoji's 😄.
    char = _zulip_names().get(match.group(1))
    return char or emoji.emojize(match.group(0), language="alias")


def expand_emoji(text: str) -> str:
    """Replace :shortcodes: with their emoji; unknown ones (custom realm
    emoji) stay as written. Never raises."""
    try:
        return _SHORTCODE.sub(_shortcode, text)
    except Exception:
        return text


def plain_text(markdown: str) -> str:
    """Plain text for a notification body. Never raises."""
    try:
        text = _FENCE.sub(_fence, markdown.replace("\r\n", "\n"))
        text = _IMAGE.sub(lambda m: f"🖼 {m.group(1).strip() or 'image'}", text)
        text = _LINK.sub(_link, text)
        text = _USER.sub(lambda m: ("" if m.group(1) else "@") + m.group(2), text)
        text = _GROUP.sub(lambda m: f"@{m.group(1)}", text)
        text = _CHANNEL.sub(
            lambda m: f"#{m.group(1)} > {m.group(2)}" if m.group(2) else f"#{m.group(1)}",
            text,
        )
        text = _TIME.sub("", text)

        lines = []
        for line in text.split("\n"):
            if _RULE.match(line):
                continue
            line = _HEADING.sub("", line)
            line = _QUOTE.sub("", line)
            line = _LIST.sub(lambda m: f"{m.group(1)}• ", line)
            lines.append(line)
        text = "\n".join(lines)

        text = _BOLD.sub(lambda m: m.group(2), text)
        text = _STRIKE.sub(lambda m: m.group(1), text)
        text = _ITALIC_STAR.sub(lambda m: m.group(1), text)
        text = _ITALIC_UNDER.sub(lambda m: m.group(1), text)
        text = _CODE.sub(lambda m: m.group(1), text)
        text = expand_emoji(text)
        return " ".join(text.split())
    except Exception:  # a formatting bug must never lose the message
        return " ".join(markdown.split())
