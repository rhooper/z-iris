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
from z_iris.mutes import MuteState
from z_iris.narrow import encode_component, narrow_url
from z_iris.policy import decide

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


MUTE_REGISTER = {
    "subscriptions": [
        {"stream_id": 7, "name": "ops", "is_muted": False},
        {"stream_id": 8, "name": "noise", "is_muted": True},
        {"stream_id": 9, "name": "Ελληνικά"},
    ],
    "user_topics": [
        {"stream_id": 7, "topic_name": "Lunch", "visibility_policy": 1},
        {"stream_id": 8, "topic_name": "Releases", "visibility_policy": 2},
        {"stream_id": 8, "topic_name": "followed", "visibility_policy": 3},
    ],
    "muted_topics": [["ops", "Legacy", 1700000000], ["gone", "x", 1], ["Ελληνικά", "ΟΔΟΣ", 2]],
}

MUTE_QUERIES = [
    [7, "deploys"], [7, "lunch"], [7, "LUNCH"], [7, "legacy"], [8, "anything"],
    [8, "releases"], [8, "Followed"], [9, "οδος"], [9, "οδοσ"], [9, "ΟΔΟΣ"], [9, "x"],
    [99, "x"], [7, "İstanbul"], [7, "i̇stanbul"],
]


def mute_cases() -> list[dict]:
    scenarios = {
        "register_only": (MUTE_REGISTER, []),
        "empty_register": ({}, []),
        "events": (MUTE_REGISTER, [
            {"type": "subscription", "op": "update", "stream_id": 7, "property": "is_muted",
             "value": True},
            {"type": "user_topic", "stream_id": 7, "topic_name": "DEPLOYS", "visibility_policy": 2},
            {"type": "user_topic", "stream_id": 7, "topic_name": "lunch", "visibility_policy": 0},
            {"type": "subscription", "op": "update", "stream_id": 8, "property": "is_muted",
             "value": False},
            {"type": "subscription", "op": "update", "stream_id": 8, "property": "color",
             "value": "#fff"},
            {"type": "subscription", "op": "remove", "subscriptions": [{"stream_id": 7}]},
            {"type": "subscription", "op": "add",
             "subscriptions": [{"stream_id": 12, "name": "new", "is_muted": True}]},
            {"type": "message", "message": {}},
        ]),
        "legacy_replaced": (MUTE_REGISTER, [
            {"type": "user_topic", "stream_id": 7, "topic_name": "legacy", "visibility_policy": 1},
            {"type": "muted_topics", "muted_topics": [["ops", "deploys", 3]]},
            {"type": "muted_topics", "muted_topics": []},
            {"type": "muted_topics"},
        ]),
        "legacy_then_user_topic_unmute": (MUTE_REGISTER, [
            {"type": "user_topic", "stream_id": 7, "topic_name": "Legacy", "visibility_policy": 2},
            {"type": "muted_topics", "muted_topics": []},
        ]),
    }
    cases = []
    for name, (register, events) in scenarios.items():
        def build(register=register, events=events):
            state = MuteState.from_register(register)
            answers = [[state.is_muted(c, t) for c, t in MUTE_QUERIES]]
            for event in events:
                state.apply(event)
                answers.append([state.is_muted(c, t) for c, t in MUTE_QUERIES])
            return answers
        cases.append(run(name, {"register": register, "events": events,
                                "queries": MUTE_QUERIES}, build))
    cases.append(run("malformed_user_topic", {"register": {"user_topics": [{"stream_id": 1}]},
                                              "events": [], "queries": []},
                     lambda: MuteState.from_register({"user_topics": [{"stream_id": 1}]})))
    return cases


def policy_cases() -> list[dict]:
    def msg(kind="channel", sender=9, flags=(), channel=7, topic="deploys"):
        if kind == "dm":
            return Message("w", "h", 1, "dm", sender, "Ada", "x", frozenset(flags), None, None,
                           None, (sender,))
        return Message("w", "h", 1, "channel", sender, "Ada", "x", frozenset(flags), channel,
                       "ops", topic, ())
    messages = {
        "own_channel": msg(sender=5, flags=["mentioned"]),
        "own_dm": msg("dm", sender=5),
        "dm": msg("dm"),
        "dm_ignores_mutes": msg("dm", flags=[]),
        "mention": msg(flags=["mentioned"]),
        "muted_mention": msg(channel=8, flags=["mentioned"]),
        "muted_wildcard": msg(channel=8, flags=["wildcard_mentioned"]),
        "muted_topic": msg(topic="LUNCH"),
        "wildcard": msg(flags=["topic_wildcard_mentioned"]),
        "alert_word": msg(flags=["has_alert_word"]),
        "plain": msg(),
        "followed_topic_in_muted_channel": msg(channel=8, topic="followed"),
    }
    state = MuteState.from_register(MUTE_REGISTER)
    cases = []
    for name, message in messages.items():
        for enabled in (False, True):
            def build(message=message, enabled=enabled):
                decision = decide(message, state, 5, enabled)
                return {"notify": decision.notify, "reason": decision.reason}
            cases.append(run(f"{name} channel={enabled}",
                             {"register": MUTE_REGISTER, "message": message_dict(message),
                              "self_id": 5, "notify_channel_messages": enabled}, build))
    return cases


def lower_cases() -> list[dict]:
    texts = ["LUNCH", "ΟΔΟΣ", "ΟΔΟΣ ΚΑΙ", "Σ", "ΑΣ.", "ΑΣ'Β", "ΑΣΑ", "İstanbul", "ẞ", "Ǆ",
             "ΑΣ\u0301", "ﬃ", "Ω", "MiXeD café 🚀", ""]
    return [run(f"lower {t!r}", {"text": t}, lambda t=t: t.lower()) for t in texts]


REGEX_SUBJECTS = ["ops", "OPS", "ops-alerts", "dev ops", "deploy failed", "Deploy FAILED!",
                  "a{1}", "x{,2}y", "ab", "aab", "", "line\n", "café", "CAFÉ", "😀 ok",
                  "q&a", "[x]", "a-b", "price: $5", "back\\slash", "tab\there", "1.2.3",
                  "straße", "STRASSE", "\x0b", "x]y"]

REGEX_PATTERNS = [
    "ops", "^ops$", "ops|dev", ".*ops.*", "deploy (failed|broke)", r"\bfail", r"\d+\.\d+",
    r"(?P<w>a)(?P=w)b", r"a\Z", r"line\Z", "line$", "a{1}", "a{,2}", "a{2,}", "{", "x{,2}y",
    "a{x}", "}", "[]x]", "[[]", "[x&&y]", "[a--b]", "[^]x]", r"[\b]", r"\v", r"\s", r"\w+",
    "caf.", "CAFÉ", "straße", r"\$\d", "q&a", r"back\\slash", r"\x41", r"é", r"\U0001F600",
    r"\N{LATIN SMALL LETTER E WITH ACUTE}", "(?i)ops", "(?:ab)+", "a++", "(?=o)ops", "(?<=a)b",
    "(?<!x)ab", r"\p{L}", r"\h", r"\Q.\E", "(", "[", "*", "a**", r"\k<x>", "(?P<1>x)",
    "(?P>x)", "x(?i)", "(?<=a+)b", r"\1(a)", "(a)\\1", r"\0", r"\Aops", r"\B", "ops\\", "",
    "[a-z]+", "[z-a]", r"[\x41-\x5a]+", r"\101", r"(a)(b)\2", r"(a\1)", "(?P<n>a)|b", "[-a]",
    "[a-]", r"[\d-z]", "[]-a]", "[a-c-e]", r"\x4", "(?<n>a)", "(?P<2x>a)", "(?x) o p s",
]


def regex_cases() -> list[dict]:
    import re
    cases = []
    for pattern in REGEX_PATTERNS:
        def build(pattern=pattern):
            compiled = re.compile(pattern, re.IGNORECASE)
            results = []
            for subject in REGEX_SUBJECTS:
                found = compiled.search(subject)
                results.append({"search": None if found is None else found.group(0),
                                "fullmatch": compiled.fullmatch(subject) is not None})
            return results
        cases.append(run(f"re {pattern!r}", {"pattern": pattern, "subjects": REGEX_SUBJECTS},
                         build))
    return cases


FIXTURES = {
    "lower": lower_cases,
    "regex": regex_cases,
    "message": message_cases,
    "narrow": narrow_cases,
    "mutes": mute_cases,
    "policy": policy_cases,
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in FIXTURES.items():
        text = json.dumps(build(), indent=1, ensure_ascii=False, sort_keys=True)
        (OUT / f"{name}.json").write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
