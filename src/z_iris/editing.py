"""Edit the config file's rules and volumes while keeping its comments."""

from __future__ import annotations

import re
from pathlib import Path

import tomlkit

from z_iris.config import parse_config
from z_iris.rules import Rule


def _shared_server_volume(servers: list) -> int | None:
    """The one volume every server has, if they agree; folded into the master
    so the editor shows just a rule's volume and the master."""
    volumes = {s.get("volume", 100) for s in servers}
    return volumes.pop() if len(volumes) == 1 else None


def _editable_rule(raw: dict) -> dict:
    rule = {key: raw[key] for key in RULE_FIELDS if key in raw}
    if "description" not in rule and raw.get("name"):
        rule["description"] = raw["name"]  # older configs named their rules
    if "channel" in rule:
        rule["channel"] = [rule["channel"]] if isinstance(rule["channel"], str) else list(rule["channel"])
    return rule


def _sort_key(raw: dict) -> tuple:
    """Highest priority first, then alphabetically by label."""
    source = raw.get("topic") if raw.get("match") == "topic" else raw.get("keyword")
    try:
        pattern = re.compile(source) if source else None
        label = Rule(raw.get("description") or None, raw.get("match", "mention"),
                     tuple(raw.get("channel") or ()), pattern, None, None, None, None,
                     0, 0).label
    except (re.error, KeyError, TypeError, ValueError):
        label = raw.get("description") or ""
    return (-(raw.get("priority") or 0), label.lower())

RULE_FIELDS = (
    "description", "match", "channel", "topic", "keyword", "server", "sound",
    "volume", "banner", "priority", "enabled", "flash", "flash_color",
    "flash_seconds", "repeat", "repeat_every", "repeat_boost", "min_gap",
    "batch_window", "sticky", "stay",
)
FOCUS_FIELDS = ("mode", "quiet_hours", "quiet_mode")
DEFAULT_FIELDS = (
    "sound", "volume", "master_volume", "notify_channel_messages", "flash",
    "flash_color", "flash_seconds", "repeat", "repeat_every", "repeat_boost",
    "min_gap", "batch_window", "sticky", "stay",
)


def read_editable(text: str) -> dict:
    """The parts of the config the editor may show. Never includes zuliprc paths."""
    data = tomlkit.parse(text).unwrap()
    shared = _shared_server_volume(data.get("server", []))
    master = data.get("defaults", {}).get("master_volume", 100)
    return {
        "servers": [{"name": s["name"]} for s in data.get("server", [])],
        "defaults": {
            "sound": data.get("defaults", {}).get("sound", "chime"),
            "volume": data.get("defaults", {}).get("volume", 60),
            "master_volume": round(master * shared / 100) if shared is not None else master,
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
        "rules": [_editable_rule(raw) for raw in data.get("rule", [])],
    }


def _blank(value: object) -> bool:
    return value is None or value == ""


def apply_edit(text: str, payload: dict, sounds_dir: Path | None = None) -> str:
    """Return new config text with the payload applied. Raises ConfigError.

    The result is validated by the real parser before it is returned.
    """
    doc = tomlkit.parse(text)

    if "master_volume" in payload.get("defaults", {}):
        # The editor's master already includes a shared server volume.
        if _shared_server_volume(doc.get("server", [])) is not None:
            for server in doc.get("server", []):
                if "volume" in server:
                    del server["volume"]

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
        edited_rules = [
            {**raw, "description": raw.get("description") or raw.get("name")} for raw in payload["rules"]
        ]
        for raw in sorted(edited_rules, key=_sort_key):
            table = tomlkit.table()
            for key in RULE_FIELDS:
                value = raw.get(key)
                if key == "channel" and isinstance(value, list):
                    value = [c for c in value if c]
                    value = value[0] if len(value) == 1 else (value or None)
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
