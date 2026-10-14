"""Edit the config file's rules and volumes while keeping its comments."""

from __future__ import annotations

from pathlib import Path

import tomlkit

from z_iris.config import parse_config

RULE_FIELDS = (
    "name", "match", "channel", "topic", "keyword", "server", "sound",
    "volume", "banner", "priority",
)
DEFAULT_FIELDS = ("sound", "volume", "master_volume", "notify_channel_messages")


def read_editable(text: str) -> dict:
    """The parts of the config the editor may show. Never includes zuliprc paths."""
    data = tomlkit.parse(text).unwrap()
    return {
        "servers": [
            {"name": s["name"], "volume": s.get("volume", 100)}
            for s in data.get("server", [])
        ],
        "defaults": {
            "sound": data.get("defaults", {}).get("sound", "chime"),
            "volume": data.get("defaults", {}).get("volume", 60),
            "master_volume": data.get("defaults", {}).get("master_volume", 100),
            "notify_channel_messages": data.get("defaults", {}).get(
                "notify_channel_messages", False
            ),
        },
        "rules": [
            {key: raw[key] for key in RULE_FIELDS if key in raw}
            for raw in data.get("rule", [])
        ],
    }


def _blank(value: object) -> bool:
    return value is None or value == ""


def apply_edit(text: str, payload: dict, sounds_dir: Path | None = None) -> str:
    """Return new config text with the payload applied. Raises ConfigError.

    The result is validated by the real parser before it is returned.
    """
    doc = tomlkit.parse(text)

    if "defaults" in payload:
        defaults = doc.setdefault("defaults", tomlkit.table())
        for key in DEFAULT_FIELDS:
            if key in payload["defaults"]:
                defaults[key] = payload["defaults"][key]

    for edited in payload.get("servers", []):
        for server in doc.get("server", []):
            if server["name"] == edited.get("name") and "volume" in edited:
                server["volume"] = edited["volume"]

    if "rules" in payload:
        if "rule" in doc:
            del doc["rule"]
        rules = tomlkit.aot()
        for raw in payload["rules"]:
            table = tomlkit.table()
            for key in RULE_FIELDS:
                value = raw.get(key)
                if _blank(value) or (key == "priority" and value == 0):
                    continue
                table[key] = value
            rules.append(table)
        if len(rules):
            doc["rule"] = rules

    new = tomlkit.dumps(doc)
    parse_config(new, sounds_dir)
    return new
