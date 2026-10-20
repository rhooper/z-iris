"""Edit the config file's rules and volumes while keeping its comments."""

from __future__ import annotations

from pathlib import Path

import tomlkit

from z_iris.config import parse_config

RULE_FIELDS = (
    "name", "match", "channel", "topic", "keyword", "server", "sound",
    "volume", "banner", "priority", "enabled", "flash", "flash_color",
    "flash_seconds", "repeat", "repeat_every", "repeat_boost", "min_gap",
    "batch_window", "sticky",
)
FOCUS_FIELDS = ("mode", "quiet_hours", "quiet_mode")
DEFAULT_FIELDS = (
    "sound", "volume", "master_volume", "notify_channel_messages", "flash",
    "flash_color", "flash_seconds", "repeat", "repeat_every", "repeat_boost",
    "min_gap", "batch_window", "sticky",
)


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
            **{
                key: data["defaults"][key]
                for key in DEFAULT_FIELDS
                if key in data.get("defaults", {})
                and key not in ("sound", "volume", "master_volume", "notify_channel_messages")
            },
        },
        "focus": {
            "mode": data.get("focus", {}).get("mode", "off"),
            "quiet_hours": list(data.get("focus", {}).get("quiet_hours", [])),
            "quiet_mode": data.get("focus", {}).get("quiet_mode", "silent"),
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

    if "focus" in payload:
        focus = doc.setdefault("focus", tomlkit.table())
        for key in FOCUS_FIELDS:
            if key in payload["focus"]:
                focus[key] = payload["focus"][key]

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
                if _blank(value) or (key == "priority" and value == 0) or (
                    key == "enabled" and value is True
                ):
                    continue
                table[key] = value
            rules.append(table)
        if len(rules):
            doc["rule"] = rules

    new = tomlkit.dumps(doc)
    parse_config(new, sounds_dir)
    return new


def replace_sound(text: str, old: str, new: str) -> str:
    """Switch the default sound and every rule's sound from old to new, keeping
    the file's comments and layout. Text without old comes back unchanged."""
    doc = tomlkit.parse(text)
    changed = False
    defaults = doc.get("defaults")
    if defaults is not None and defaults.get("sound") == old:
        defaults["sound"] = new
        changed = True
    for rule in doc.get("rule", []):
        if rule.get("sound") == old:
            rule["sound"] = new
            changed = True
    return tomlkit.dumps(doc) if changed else text
