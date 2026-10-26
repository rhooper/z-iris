"""Write the Swift port's parity fixtures by running the Python modules.

Each fixture file is a JSON list of {"name", "input", "expected"}; a case the
Python code rejects has "error" (the exception's class name) instead of
"expected". While both implementations live, regenerate in the same commit as
any Python behaviour change (scripts/claude/check_fixtures.sh checks).

2026-10-26. Usage: uv run python scripts/claude/gen_fixtures.py
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

from z_iris.message import Message, message_from_event
from z_iris.narrow import encode_component, narrow_url

OUT = Path(__file__).resolve().parents[2] / "swift/Tests/ZIrisCoreTests/Fixtures"


def message_dict(message: Message) -> dict:
    data = dataclasses.asdict(message)
    data["flags"] = sorted(data["flags"])
    return data


def run(name: str, input, fn) -> dict:
    try:
        return {"name": name, "input": input, "expected": fn()}
    except Exception as error:  # the fixture records which cases are refused
        return {"name": name, "input": input, "error": type(error).__name__}


def channel_raw(**overrides) -> dict:
    raw = {
        "id": 101, "type": "stream", "stream_id": 7, "display_recipient": "ops",
        "subject": "deploys", "sender_id": 9, "sender_full_name": "Ada", "content": "hello",
    }
    raw.update(overrides)
    return raw


def dm_raw(people, **overrides) -> dict:
    raw = {
        "id": 202, "type": "private", "sender_id": 9, "sender_full_name": "Ada",
        "content": "hi", "display_recipient": people,
    }
    raw.update(overrides)
    return raw


def message_cases() -> list[dict]:
    me = {"id": 5, "full_name": "Me", "email": "me@x"}
    ada = {"id": 9, "full_name": "Ada", "email": "ada@x"}
    bob = {"id": 3, "full_name": "Bob", "email": "bob@x"}
    no_name = {"id": 12, "email": "anon@x"}
    topic_only = channel_raw()
    topic_only["topic"] = topic_only.pop("subject")
    no_message_id = channel_raw()
    del no_message_id["id"]
    events = {
        "channel": {"message": channel_raw(), "flags": ["mentioned"]},
        "channel_topic_key": {"message": topic_only, "flags": []},
        "channel_no_flags": {"message": channel_raw()},
        "channel_avatar": {"message": channel_raw(avatar_url="https://x/a.png"), "flags": []},
        "wildcard_flags": {
            "message": channel_raw(),
            "flags": ["read", "stream_wildcard_mentioned", "has_alert_word"],
        },
        "dm_one": {"message": dm_raw([me, ada]), "flags": ["read"]},
        "dm_group_sorted": {"message": dm_raw([me, ada, bob]), "flags": []},
        "dm_self": {"message": dm_raw([me]), "flags": []},
        "dm_missing_name": {"message": dm_raw([me, no_name, ada]), "flags": []},
        "malformed_no_message": {"flags": []},
        "malformed_no_id": {"message": no_message_id},
        "malformed_dm_recipient_string": {"message": dm_raw("ops")},
    }
    cases = []
    for name, event in events.items():
        def build(event=event):
            message = message_from_event("work", "chat.example.com", 5, event)
            return {
                "message": message_dict(message),
                "is_mention": message.is_mention,
                "is_wildcard_mention": message.is_wildcard_mention,
                "has_alert_word": message.has_alert_word,
            }
        cases.append(run(name, {"server": "work", "host": "chat.example.com", "self_id": 5,
                                "event": event}, build))
    return cases


def narrow_cases() -> list[dict]:
    texts = ["deploys", "two words", "a.b", "a/b", "c#1", "100%", "café", "🚀", "",
             "q&a: 1.0", "under_score-dash~tilde", "x.y#z 🚀", "日本語", "tab\tnew\nline"]
    cases = [run(f"encode {t!r}", {"text": t}, lambda t=t: encode_component(t)) for t in texts]
    messages = {
        "channel": Message("w", "chat.example.com", 101, "channel", 9, "Ada", "x",
                           frozenset(), 7, "ops", "deploys", ()),
        "channel_encoded": Message("w", "chat.example.com", 101, "channel", 9, "Ada", "x",
                                   frozenset(), 7, "my team", "q&a: 1.0", ()),
        "channel_empty_topic": Message("w", "h.example", 5, "channel", 9, "Ada", "x",
                                       frozenset(), 42, "a b/c", "", ()),
        "dm_one": Message("w", "chat.example.com", 101, "dm", 9, "Ada", "x",
                          frozenset(), None, None, None, (9,)),
        "dm_group": Message("w", "chat.example.com", 101, "dm", 9, "Ada", "x",
                            frozenset(), None, None, None, (3, 12)),
    }
    for name, message in messages.items():
        cases.append(run(f"url {name}", {"message": message_dict(message)},
                         lambda m=message: narrow_url(m)))
    return cases


FIXTURES = {
    "message": message_cases,
    "narrow": narrow_cases,
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in FIXTURES.items():
        text = json.dumps(build(), indent=1, ensure_ascii=False, sort_keys=True)
        (OUT / f"{name}.json").write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
