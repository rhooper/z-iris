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

from z_iris.config import Action, Config, ConfigError, parse_config, resolve_action
from z_iris.engine import Engine
from z_iris.media import MessageImages
from z_iris.message import Message, message_from_event
from z_iris.mutes import MuteState
from z_iris.narrow import encode_component, narrow_url
from z_iris.pipeline import Notification
from z_iris.plaintext import plain_text
from z_iris.policy import decide
from z_iris.rules import Rule, pick_rule
from z_iris.sender import Sender, sender_for
from z_iris.settings import Settings
from z_iris.sounds import builtin_names
from z_iris.stream import Controls

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


HOME = str(Path.home())


def unhome(text: str) -> str:
    """Keep the user's home directory out of committed fixtures."""
    return "~HOME" + text[len(HOME):] if text.startswith(HOME) else text


def fixture_sounds() -> dict[str, Path]:
    """The bundled sound names at fixed paths, so fixtures don't depend on
    where the package is installed."""
    sounds = {name: Path(f"/sounds/{name}.wav") for name in builtin_names()}
    sounds["synth"] = sounds["chime"]
    return sounds


def rule_dict(rule: Rule) -> dict:
    return {
        "description": rule.description, "kind": rule.kind, "channels": list(rule.channels),
        "pattern": rule.pattern.pattern if rule.pattern else None, "server": rule.server,
        "sound": rule.sound, "volume": rule.volume, "banner": rule.banner,
        "priority": rule.priority, "index": rule.index, "enabled": rule.enabled,
        "behaviour": rule.behaviour, "label": rule.label,
    }


def config_dict(config: Config) -> dict:
    return {
        "servers": [{"name": s.name, "zuliprc": unhome(str(s.zuliprc)), "volume": s.volume}
                    for s in config.servers],
        "sound": unhome(config.sound), "volume": config.volume,
        "notify_channel_messages": config.notify_channel_messages,
        "player": list(config.player), "notifier": config.notifier,
        "external_images": config.external_images, "master_volume": config.master_volume,
        "rules": [rule_dict(r) for r in config.rules], "behaviour": config.behaviour,
        "focus": {"mode": config.focus.mode, "quiet_mode": config.focus.quiet_mode,
                  "quiet_hours": [list(h) for h in config.focus.quiet_hours]},
    }


def parse(text: str) -> Config:
    import z_iris.config as config_module
    real = config_module.library
    config_module.library = lambda _dir: fixture_sounds()
    try:
        return parse_config(text)
    finally:
        config_module.library = real


def run_config(name: str, text: str) -> dict:
    case = run(name, {"toml": text}, lambda: config_dict(parse(text)))
    if "error" in case:
        try:
            parse(text)
        except ConfigError as error:
            case["message"] = str(error)
    return case


S = '[[server]]\nname = "work"\nzuliprc = "~/.zuliprc"\n'
FULL = S + '''
[[server]]
name = "home"
zuliprc = "/etc/./zuliprc-home"
volume = 50

[defaults]
volume = 70
master_volume = 90
sound = "ping"
notify_channel_messages = true
flash = "top"
flash_color = "#FFAA00"
flash_seconds = 2
repeat = 3
sticky = true

[output]
player = ["play", "-q", "-V1"]
notifier = "/opt/bin/tn"
external_images = true

[focus]
mode = "mentions_and_dms"
quiet_mode = "mentions_and_dms"
quiet_hours = ["22:00-07:00", "9:05-9:30", "00:00-23:59"]

[[rule]]
description = "Pages"
match = "keyword"
keyword = "(?P<w>page)\\\\s+me"
priority = 5
sound = "sos"
volume = 100
banner = "title"
flash = "screen"
repeat = 2
repeat_every = 10

[[rule]]
match = "channel"
channel = ["ops", "deploy-.*"]
server = "work"

[[rule]]
name = "Old name"
match = "topic"
topic = "release"
channel = "eng"
enabled = false
stay = 30

[[rule]]
description = ""
match = "topic"
topic = "it's"

[[rule]]
description = "it's quoted"
match = "dm"
sound = "none"
min_gap = 60
batch_window = 5
repeat_boost = 20

[[rule]]
match = "mention"
sound = "/etc/hosts"

[[rule]]
match = "wildcard"
[[rule]]
match = "alert_word"
[[rule]]
match = "group_dm"
flash_seconds = 0.25
'''


def config_cases() -> list[dict]:
    rule = lambda body: S + "[[rule]]\n" + body  # noqa: E731
    texts = {
        "minimal": S,
        "full": FULL,
        "invalid_toml": S + "volume = = 3\n",
        "duplicate_key": S + "[defaults]\nvolume = 1\nvolume = 2\n",
        "no_server": "[defaults]\nvolume = 5\n",
        "server_not_list": "server = 5\n",
        "server_table": '[server]\nname = "w"\n',
        "server_no_name": '[[server]]\nzuliprc = "x"\n',
        "server_empty_name": '[[server]]\nname = ""\nzuliprc = "x"\n',
        "server_no_zuliprc": '[[server]]\nname = "w"\n',
        "server_duplicate": S + S,
        "server_volume_high": S + "volume = 101\n",
        "server_volume_bool": S + "volume = true\n",
        "server_relative_zuliprc": '[[server]]\nname = "w"\nzuliprc = "a//b/./c/"\n',
        "defaults_not_table": "defaults = 5\n" + S,
        "output_not_table": "output = [1]\n" + S,
        "volume_string": S + '[defaults]\nvolume = "x"\n',
        "volume_date": S + "[defaults]\nvolume = 1979-05-27\n",
        "master_volume_float": S + "[defaults]\nmaster_volume = 1.5\n",
        "sound_unknown": S + '[defaults]\nsound = "boing"\n',
        "sound_empty": S + '[defaults]\nsound = ""\n',
        "sound_number": S + "[defaults]\nsound = 3\n",
        "sound_path": S + '[defaults]\nsound = "/etc/hosts"\n',
        "sound_dir": S + '[defaults]\nsound = "/etc"\n',
        "sound_synth": S + '[defaults]\nsound = "synth"\n',
        "notify_string": S + '[defaults]\nnotify_channel_messages = "yes"\n',
        "player_empty": S + "[output]\nplayer = []\n",
        "player_numbers": S + "[output]\nplayer = [1]\n",
        "player_string": S + '[output]\nplayer = "play"\n',
        "notifier_empty": S + '[output]\nnotifier = ""\n',
        "external_images_int": S + "[output]\nexternal_images = 1\n",
        "rules_not_list": "rule = 3\n" + S,
        "rule_description_number": rule('description = 5\nmatch = "dm"\n'),
        "rule_name_number": rule('name = 5\nmatch = "dm"\n'),
        "rule_match_bad": rule('description = "x"\nmatch = "everything"\n'),
        "rule_match_missing": rule('sound = "ping"\n'),
        "rule_channel_on_mention": rule('match = "mention"\nchannel = "ops"\n'),
        "rule_channel_missing": rule('match = "channel"\n'),
        "rule_channel_empty_list": rule('match = "channel"\nchannel = []\n'),
        "rule_channel_empty_name": rule('match = "channel"\nchannel = [""]\n'),
        "rule_channel_empty_string": rule('match = "channel"\nchannel = ""\n'),
        "rule_channel_number": rule('match = "channel"\nchannel = 5\n'),
        "rule_channel_bool": rule('match = "channel"\nchannel = false\n'),
        "rule_channel_bad_pattern": rule('match = "channel"\nchannel = ["ok", "("]\n'),
        "rule_topic_missing": rule('match = "topic"\n'),
        "rule_topic_bad_regex": rule('description = "Bad"\nmatch = "topic"\ntopic = "("\n'),
        "rule_keyword_empty": rule('match = "keyword"\nkeyword = ""\n'),
        "rule_server_unknown": rule('match = "dm"\nserver = "play"\n'),
        "rule_server_number": rule('match = "dm"\nserver = 3\n'),
        "rule_volume_high": rule('match = "dm"\nvolume = 200\n'),
        "rule_banner_bad": rule('match = "dm"\nbanner = "huge"\n'),
        "rule_sound_unknown": rule('match = "dm"\nsound = "boing"\n'),
        "rule_enabled_string": rule('match = "dm"\nenabled = "no"\n'),
        "rule_priority_float": rule('match = "dm"\npriority = 1.5\n'),
        "rule_priority_bool": rule('match = "dm"\npriority = true\n'),
        "rule_priority_negative": rule('match = "dm"\npriority = -3\n'),
        "rule_flash_bad": rule('match = "dm"\nflash = "blink"\n'),
        "rule_flash_color_bad": rule('match = "dm"\nflash_color = "red"\n'),
        "rule_flash_seconds_low": rule('match = "dm"\nflash_seconds = 0.05\n'),
        "rule_flash_seconds_string": rule('match = "dm"\nflash_seconds = "1"\n'),
        "rule_repeat_float": rule('match = "dm"\nrepeat = 1.0\n'),
        "rule_repeat_high": rule('match = "dm"\nrepeat = 21\n'),
        "rule_sticky_int": rule('match = "dm"\nsticky = 1\n'),
        "rule_stay_high": rule('match = "dm"\nstay = 3601\n'),
        "defaults_flash_bad": S + '[defaults]\nflash = "blink"\n',
        "rule_error_before_defaults_error": S + '[defaults]\nflash = "blink"\n[[rule]]\nmatch = "x"\n',
        "defaults_error_before_focus_error": S + '[defaults]\nrepeat = -1\n[focus]\nmode = "x"\n',
        "focus_not_table": "focus = 5\n" + S,
        "focus_mode_bad": S + '[focus]\nmode = "loud"\n',
        "focus_quiet_mode_off": S + '[focus]\nquiet_mode = "off"\n',
        "focus_hours_string": S + '[focus]\nquiet_hours = "22:00-07:00"\n',
        "focus_hours_bad_format": S + '[focus]\nquiet_hours = ["7-8"]\n',
        "focus_hours_bad_time": S + '[focus]\nquiet_hours = ["25:00-07:00"]\n',
        "focus_hours_bad_minute": S + '[focus]\nquiet_hours = ["22:60-07:00"]\n',
        "focus_hours_same": S + '[focus]\nquiet_hours = ["22:00-22:00"]\n',
        "focus_hours_number": S + "[focus]\nquiet_hours = [5]\n",
        "focus_hours_three_digits": S + '[focus]\nquiet_hours = ["123:00-07:00"]\n',
        "focus_hours_quote": S + "[focus]\nquiet_hours = [\"it's\"]\n",
    }
    return [run_config(name, text) for name, text in texts.items()]


ACTION_CONFIG = S + '''
[[server]]
name = "home"
zuliprc = "/x"
volume = 33

[defaults]
volume = 50
master_volume = 75
flash_color = "#00ff00"
repeat = 1

[[rule]]
match = "dm"
volume = 90
sound = "ping"
banner = "off"
repeat = 4
flash_seconds = 1

[[rule]]
match = "mention"
sound = "none"

[[rule]]
match = "wildcard"
sound = "/etc/hosts"
volume = 1
'''


def action_cases() -> list[dict]:
    config = parse(ACTION_CONFIG)
    cases = []
    for server in ("work", "home", "elsewhere"):
        for index in (None, 0, 1, 2):
            rule = None if index is None else config.rules[index]
            def build(server=server, rule=rule):
                action = resolve_action(config, server, rule)
                data = dataclasses.asdict(action)
                data["sound"] = unhome(data["sound"])
                return data
            cases.append(run(f"{server} rule={index}", {"toml": ACTION_CONFIG, "server": server,
                                                         "rule": index}, build))
    # Python rounds halves to even: 50 * 33 * 75 / 10000 = 12.375; 5 * 50 * 50 / 10000 = 1.25.
    halves = S + '[[server]]\nname = "h"\nzuliprc = "/x"\nvolume = 50\n[defaults]\nvolume = 5\nmaster_volume = 50\n'
    half_config = parse(halves)
    for server in ("work", "h"):
        cases.append(run(f"halves {server}", {"toml": halves, "server": server, "rule": None},
                         lambda s=server: dataclasses.asdict(resolve_action(half_config, s, None))))
    return cases


PICK_CONFIG = S + '''
[[server]]
name = "home"
zuliprc = "/x"

[[rule]]
match = "channel"
channel = ["ops", "deploy-.*"]

[[rule]]
match = "topic"
topic = "fail|broke"

[[rule]]
match = "topic"
topic = "release"
channel = "eng"
priority = 1

[[rule]]
match = "keyword"
keyword = "\\\\burgent\\\\b"

[[rule]]
match = "mention"

[[rule]]
match = "wildcard"
server = "home"

[[rule]]
match = "alert_word"
enabled = false

[[rule]]
match = "dm"

[[rule]]
match = "group_dm"
priority = -1

[[rule]]
match = "keyword"
keyword = "lunch"
priority = 2
server = "home"
'''


def pick_cases() -> list[dict]:
    config = parse(PICK_CONFIG)

    def channel(name="ops", topic="deploys", content="x", flags=(), server="work"):
        return Message(server, "h", 1, "channel", 9, "Ada", content, frozenset(flags), 7, name,
                       topic, ())

    def dm(ids, content="x", server="work"):
        return Message(server, "h", 1, "dm", 9, "Ada", content, frozenset(), None, None, None,
                       tuple(ids))
    messages = {
        "plain_ops": channel(),
        "ops_case": channel("OPS"),
        "deploy_prod": channel("deploy-prod"),
        "deploy_partial": channel("my-deploy-prod"),
        "ops_suffix": channel("opsx"),
        "topic_fail": channel("random", "build failed"),
        "topic_in_ops": channel("ops", "it broke"),
        "release_in_eng": channel("eng", "Release 2.0", flags=["mentioned"]),
        "release_elsewhere": channel("other", "release"),
        "urgent_word": channel("other", "t", "this is URGENT now"),
        "urgent_part": channel("other", "t", "urgently"),
        "mention_topic": channel("other", "it broke", flags=["mentioned"]),
        "wildcard_work": channel("other", "t", flags=["wildcard_mentioned"]),
        "wildcard_home": channel("other", "t", flags=["wildcard_mentioned"], server="home"),
        "alert_word_disabled": channel("other", "t", flags=["has_alert_word"]),
        "dm_one": dm([9]),
        "dm_group": dm([3, 9]),
        "dm_lunch_home": dm([9], "lunch?", "home"),
        "dm_lunch_work": dm([9], "lunch?"),
        "nothing": channel("other", "t"),
    }
    cases = []
    for name, message in messages.items():
        def build(message=message):
            rule = pick_rule(config.rules, message)
            return None if rule is None else rule.index
        cases.append(run(name, {"toml": PICK_CONFIG, "message": message_dict(message)}, build))
    return cases


PLAIN_SAMPLES = [
    "**bold** and __bold__ and *it* and _it_ and ~~gone~~", "use `code` here",
    "snake_case_name stays", "2 * 3 * 4", "[the docs](https://example.com/x) rock",
    "![diagram](https://example.com/a.png)", "![](https://example.com/a.png)",
    "![  ](x)", "[report.pdf](/user_uploads/1/ab/report.pdf)",
    "hi @**Ada Lovelace** and @**Bob|12**", "@_**Ada** said", "@*backend* look",
    "@**all** heads up", "see #**ops>deploys** and #**dev**", "# Title\ntext",
    "####### seven", "    # indented four", "> quoted line\nreply", ">>> nested",
    "- one\n- two\n1. three", "  * nested\n+ plus", "a\n\n---\n\nb", "* * *\n_ _ _\n--",
    "nice :tada: :+1: :octopus:", ":working_on_it: :check: :upside_down: :smile:",
    ":white_check_mark: :face_with_tears_of_joy:", "custom :party_parrot: stays",
    "10:30:45 and a:b:c stay", ":tada::tada: (:octopus:)", ":thumbs_up: :-1: :e-mail:",
    "```python\nprint(1)\nx = 2\n```", "before ```quote\nthey said hi\n``` after",
    "```spoiler Plot twist\nthe butler did it\n```", "```spoiler\nsecret\n```",
    "```SPOILER  Loud \nx\n```", "```math\nE = mc^2\n```", "```\nunclosed fence\nstill",
    "```a```b```c```", "  lots   of\t space \n\n\n and lines ",
    "<time:2024-01-01T10:00:00Z> meeting", "", "**", "[", "](", "![](", "```", ":::",
    "@**", "#**>", "*" * 50, "_" * 50, "**a** [b](c) :smile: `d` " * 20,
    "**not bold **", "** spaced**", "*a*b", "x*a*", "_a_b", "it_is_", "~~ x~~",
    "windows\r\nline\r\nends", "tab\there\u00a0nbsp\u3000wide\u2028sep",
    "café **naïve** 日本語 _強調_", "emoji 👍🏽 :+1::-1:", "[link with **bold**](u)",
    "@**Ada|x**", "#**ops**> no", "<time:x", "`unclosed code", "``double``",
]


def plain_cases() -> list[dict]:
    return [run(f"plain {t[:40]!r}", {"text": t}, lambda t=t: plain_text(t)) for t in PLAIN_SAMPLES]


def sender_cases() -> list[dict]:
    def dm(ids=(9,), names=("Ada",)):
        return Message("work", "h", 101, "dm", 9, "Ada", "x", frozenset(), None, None, None,
                       tuple(ids), dm_names=tuple(names))
    channel = Message("work", "h", 101, "channel", 9, "Ada", "x", frozenset(), 7, "ops",
                      "deploys", ())
    both, avatar_only, none = (MessageImages(Path("/c/av.png"), Path("/c/pic.png")),
                               MessageImages(Path("/c/av.png"), None), MessageImages())
    situations = {
        "dm": (dm(), "Ada", both),
        "dm_no_avatar": (dm(), "Ada", none),
        "channel": (channel, "Ada (#ops > deploys)", avatar_only),
        "channel_no_avatar": (channel, "Ada (#ops > deploys)", none),
        "group": (dm((3, 9, 12), ("Bob", "Ada", "Cy")), "Ada (group)", avatar_only),
        "group_no_names": (dm((3, 9), ()), "Ada (group)", none),
        "group_short_names": (dm((3, 9, 12), ("Bob",)), "Ada (group)", none),
    }
    cases = []
    for name, (message, title, images) in situations.items():
        def build(message=message, title=title, images=images):
            sender = sender_for(message, title, images)
            return None if sender is None else sender.to_json()
        cases.append(run(f"for {name}", {"message": message_dict(message), "title": title,
                                         "avatar": str(images.avatar) if images.avatar else None,
                                         "picture": str(images.picture) if images.picture else None},
                         build))
    good = {"handle": "zulip:w:9", "name": "Ada", "conversation": "w:dm:9"}
    payloads = {
        "minimal": good,
        "full": {**good, "avatar": "/a//b/./c.png", "picture": "", "group_name": "group",
                 "members": [["zulip:w:3", "Bob"]]},
        "not_dict": ["x"],
        "name_missing": {"handle": "h", "conversation": "c"},
        "name_number": {**good, "name": 3},
        "members_not_list": {**good, "members": "x"},
        "members_falsy": {**good, "members": 0},
        "members_bad_pair": {**good, "members": [["a"]]},
        "members_numbers": {**good, "members": [["a", 1]]},
        "avatar_number": {**good, "avatar": 5},
        "group_number": {**good, "group_name": 1},
        "relative_avatar": {**good, "avatar": "./x/../y.png"},
    }
    for name, payload in payloads.items():
        def parse_json(payload=payload):
            sender = Sender.from_json(payload)
            return None if sender is None else sender.to_json()
        cases.append(run(f"json {name}", {"json": payload}, parse_json))
    return cases


class FakeClock:
    """tests/test_engine.py's clock: due timers run in (due, sequence) order."""

    def __init__(self):
        self.now = 1000.0
        self.timers = []
        self.seq = 0

    def __call__(self):
        return self.now

    def schedule(self, delay, fn):
        self.seq += 1
        timer = [self.now + delay, self.seq, fn, False]
        self.timers.append(timer)

        class Handle:
            def cancel(self_inner):
                timer[3] = True
        return Handle()

    def advance(self, seconds):
        end = self.now + seconds
        while True:
            due = sorted((t for t in self.timers if not t[3] and t[0] <= end),
                         key=lambda t: (t[0], t[1]))
            if not due:
                break
            timer = due[0]
            timer[3] = True
            self.now = max(self.now, timer[0])
            timer[2]()
        self.now = end


class TraceOutput:
    def __init__(self, clock, trace):
        self.clock, self.trace = clock, trace

    def _note(self, call, n, **extra):
        a = n.action
        self.trace.append({"t": self.clock(), "call": call, "server": n.message.server,
                           "id": n.message.id, "sound": unhome(a.sound), "flash": a.flash,
                           "volume": a.volume, "summary": n.summary, **extra})

    def deliver(self, n):
        self._note("deliver", n)

    def banner(self, n):
        self._note("banner", n)

    def sound(self, n, volume=None):
        self._note("sound", n, at=volume)

    def clear_read(self, server, ids):
        self.trace.append({"t": self.clock(), "call": "clear_read", "server": server,
                           "ids": None if ids is None else sorted(ids)})

    def clear_unless_unread(self, server, unread):
        self.trace.append({"t": self.clock(), "call": "clear_unless_unread", "server": server,
                           "ids": sorted(unread)})


ENGINE_CONFIG = S + '''
[[server]]
name = "home"
zuliprc = "/x"
volume = 80
[defaults]
master_volume = 90
'''


def engine_note(mid=1, kind="channel", channel_id=7, name="ops", topic="deploys", flags=(),
                ids=(9,), server="work", **action) -> dict:
    """A notification step: the message plus the Action fields that differ."""
    if kind == "dm":
        message = Message(server, "h", mid, "dm", 9, "Ada", "x", frozenset(flags), None, None,
                          None, tuple(ids))
    else:
        message = Message(server, "h", mid, "channel", 9, "Ada", "x", frozenset(flags),
                          channel_id, name, topic, ())
    fields = {"sound": "/s/ping.wav", "volume": 60, "banner": "full", "rule": None, **action}
    return {"op": "submit", "message": message_dict(message),
            "action": dataclasses.asdict(Action(**fields)), "reason": "rule"}


def read(*ids, server="work", **extra):
    return {"op": "event", "server": server,
            "event": {"type": "update_message_flags", "op": "add", "flag": "read",
                      "messages": list(ids), **extra}}


def advance(seconds):
    return {"op": "advance", "seconds": seconds}


ENGINE_SCENARIOS = {
    "deliver": [engine_note(), engine_note(2, kind="dm")],
    "min_gap": [engine_note(1, min_gap=10), advance(5), engine_note(2, min_gap=10),
                advance(5), engine_note(3, min_gap=10), engine_note(4, topic="other", min_gap=10)],
    "min_gap_by_rule": [engine_note(1, rule="R", rule_index=0, min_gap=30),
                        engine_note(2, topic="t2", rule="R", rule_index=0, min_gap=30),
                        engine_note(3, rule="Label", min_gap=30),
                        engine_note(4, topic="t3", rule="Label", min_gap=30)],
    "min_gap_silent_first": [engine_note(1, sound="none", min_gap=10), engine_note(2, min_gap=10)],
    "batch_one_conversation": [engine_note(1, batch_window=10), advance(2),
                               engine_note(2, batch_window=10), engine_note(3, batch_window=10),
                               advance(10), engine_note(4, batch_window=10), advance(20)],
    "batch_many_conversations": [
        engine_note(1, rule="R", batch_window=5), engine_note(2, channel_id=8, name="dev",
                                                              rule="R", batch_window=5),
        engine_note(3, kind="dm", ids=(3, 9), rule="R", batch_window=5), advance(6)],
    "batch_dm_summaries": [engine_note(1, kind="dm", batch_window=5),
                           engine_note(2, kind="dm", batch_window=5), advance(6),
                           engine_note(3, kind="dm", ids=(3, 9), batch_window=5),
                           engine_note(4, kind="dm", ids=(3, 9), batch_window=5), advance(6)],
    "batch_alone_no_summary": [engine_note(1, batch_window=5), advance(6)],
    "batch_banner_off": [engine_note(1, banner="off", batch_window=5),
                         engine_note(2, banner="off", batch_window=5), advance(6)],
    "batch_read_drops_held": [engine_note(1, batch_window=5), engine_note(2, batch_window=5),
                              read(2), advance(6)],
    "batch_paused_at_flush": [engine_note(1, batch_window=5), engine_note(2, batch_window=5),
                              {"op": "pause"}, advance(6), {"op": "resume"}, advance(1)],
    "repeat": [engine_note(1, repeat=3, repeat_every=10, repeat_boost=20), advance(35)],
    "repeat_ceiling": [engine_note(1, server="home", volume=70, repeat=4, repeat_every=5,
                                   repeat_boost=50), advance(30)],
    "repeat_read_stops": [engine_note(1, repeat=5, repeat_every=10), advance(15), read(1),
                          advance(60)],
    "repeat_read_all": [engine_note(1, repeat=5, repeat_every=10),
                        engine_note(2, topic="t", repeat=5, repeat_every=10), advance(11),
                        read(all=True), advance(60)],
    "repeat_other_server_read": [engine_note(1, repeat=2, repeat_every=10), read(1, server="home"),
                                 advance(25)],
    "repeat_old_operation_key": [engine_note(1, repeat=2, repeat_every=10),
                                 {"op": "event", "server": "work",
                                  "event": {"type": "update_message_flags", "operation": "add",
                                            "flag": "read", "messages": [1]}}, advance(25)],
    "repeat_other_flag_ignored": [engine_note(1, repeat=2, repeat_every=10),
                                  {"op": "event", "server": "work",
                                   "event": {"type": "update_message_flags", "op": "add",
                                             "flag": "starred", "messages": [1]}},
                                  {"op": "event", "server": "work",
                                   "event": {"type": "update_message_flags", "op": "remove",
                                             "flag": "read", "messages": [1]}}, advance(25)],
    "repeat_deleted": [engine_note(1, repeat=3, repeat_every=10), engine_note(2, topic="t",
                                                                             repeat=3,
                                                                             repeat_every=10),
                       {"op": "event", "server": "work",
                        "event": {"type": "delete_message", "message_id": 1}},
                       {"op": "event", "server": "work",
                        "event": {"type": "delete_message", "message_ids": [2, "x"]}},
                       advance(40)],
    "repeat_paused": [engine_note(1, repeat=3, repeat_every=10), {"op": "pause"}, advance(15),
                      {"op": "resume"}, advance(40)],
    "repeat_silent_never": [engine_note(1, sound="none", repeat=3, repeat_every=10),
                            engine_note(2, topic="t", volume=0, repeat=3, repeat_every=10),
                            advance(40)],
    "repeat_resubmitted": [engine_note(1, repeat=2, repeat_every=10), advance(5),
                           engine_note(1, repeat=2, repeat_every=10), advance(40)],
    "focus_mentions_and_dms": [
        {"op": "config", "toml": ENGINE_CONFIG + '[focus]\nmode = "mentions_and_dms"\n'},
        engine_note(1), engine_note(2, flags=["mentioned"]), engine_note(3, kind="dm"),
        engine_note(4, flags=["stream_wildcard_mentioned"])],
    "focus_silent": [
        {"op": "config", "toml": ENGINE_CONFIG + '[focus]\nmode = "silent"\n'},
        engine_note(1, flash="screen", repeat=2, repeat_every=5), advance(20)],
    "quiet_hours": [
        {"op": "config", "toml": ENGINE_CONFIG + '[focus]\nquiet_hours = ["22:00-07:00"]\n'},
        {"op": "minutes", "value": 23 * 60}, engine_note(1, repeat=1, repeat_every=5),
        {"op": "minutes", "value": 7 * 60}, engine_note(2, topic="t"),
        {"op": "minutes", "value": 6 * 60 + 59}, engine_note(3, topic="u", kind="dm")],
    "quiet_hours_mentions": [
        {"op": "config", "toml": ENGINE_CONFIG
         + '[focus]\nquiet_hours = ["9:00-17:00"]\nquiet_mode = "mentions_and_dms"\n'},
        {"op": "minutes", "value": 12 * 60}, engine_note(1), engine_note(2, kind="dm")],
    "focus_turns_on_during_repeat": [
        engine_note(1, repeat=3, repeat_every=10), advance(11),
        {"op": "config", "toml": ENGINE_CONFIG + '[focus]\nmode = "silent"\n'}, advance(30)],
    "paused_submit": [{"op": "pause"}, engine_note(1), {"op": "resume"}, engine_note(2)],
    "stop": [engine_note(1, repeat=3, repeat_every=10), engine_note(2, topic="t", batch_window=5),
             engine_note(3, topic="t", batch_window=5), {"op": "stop"}, advance(60),
             engine_note(4)],
    "reconcile": [engine_note(1, repeat=3, repeat_every=10),
                  engine_note(2, topic="t", repeat=3, repeat_every=10),
                  engine_note(3, topic="b", batch_window=10),
                  engine_note(4, topic="b", batch_window=10),
                  engine_note(5, topic="b", batch_window=10),
                  {"op": "reconcile", "server": "work", "unread": [2, 5, 99]}, advance(40)],
    "reconcile_other_server": [engine_note(1, repeat=1, repeat_every=10),
                               {"op": "reconcile", "server": "home", "unread": []}, advance(15)],
}


def engine_cases() -> list[dict]:
    cases = []
    for name, steps in ENGINE_SCENARIOS.items():
        def build(steps=steps):
            clock, trace = FakeClock(), []
            minutes = [12 * 60]
            settings = Settings(parse(ENGINE_CONFIG))
            controls = Controls()
            engine = Engine(TraceOutput(clock, trace), settings, controls, clock=clock,
                            scheduler=clock.schedule, local_minutes=lambda: minutes[0],
                            log=lambda text: trace.append({"t": clock(), "log": text}))
            for step in steps:
                op = step["op"]
                if op == "submit":
                    message = Message(**{**step["message"],
                                         "flags": frozenset(step["message"]["flags"]),
                                         "dm_user_ids": tuple(step["message"]["dm_user_ids"]),
                                         "dm_names": tuple(step["message"]["dm_names"])})
                    engine.submit(Notification(message, narrow_url(message), step["reason"],
                                               Action(**step["action"])))
                elif op == "event":
                    engine.handle_event(step["server"], step["event"])
                elif op == "advance":
                    clock.advance(step["seconds"])
                elif op == "pause":
                    controls.paused.set()
                elif op == "resume":
                    controls.paused.clear()
                elif op == "reconcile":
                    engine.reconcile_unread(step["server"], set(step["unread"]))
                elif op == "stop":
                    engine.stop()
                elif op == "minutes":
                    minutes[0] = step["value"]
                elif op == "config":
                    settings._config = parse(step["toml"])
            return trace
        cases.append(run(name, {"toml": ENGINE_CONFIG, "steps": steps}, build))
    return cases


def pipeline_cases() -> list[dict]:
    toml = ENGINE_CONFIG + '''
[[rule]]
match = "channel"
channel = "noise"
sound = "none"
banner = "off"

[[rule]]
match = "channel"
channel = "quiet-banner"
volume = 0

[[rule]]
match = "keyword"
keyword = "deploy"
'''
    register = {"subscriptions": [{"stream_id": 7, "name": "ops"},
                                  {"stream_id": 8, "name": "muted", "is_muted": True}]}

    def event(mid, stream="ops", stream_id=7, content="hi", flags=(), sender=9, kind="stream"):
        message = {"id": mid, "type": kind, "sender_id": sender, "sender_full_name": "Ada",
                   "content": content}
        if kind == "stream":
            message.update(stream_id=stream_id, display_recipient=stream, subject="t")
        else:
            message["display_recipient"] = [{"id": 5, "full_name": "Me"},
                                            {"id": sender, "full_name": "Ada"}]
        return {"type": "message", "message": message, "flags": list(flags)}
    events = [
        event(1), event(2, content="deploy now"), event(3, stream="noise"),
        event(4, stream="noise", flags=["mentioned"]), event(5, stream="quiet-banner"),
        event(6, stream="muted", stream_id=8, content="deploy"),
        {"type": "subscription", "op": "update", "stream_id": 8, "property": "is_muted",
         "value": False},
        event(7, stream="muted", stream_id=8, content="deploy"),
        {"type": "user_topic", "stream_id": 7, "topic_name": "T", "visibility_policy": 1},
        event(8, content="deploy"), event(9, flags=["mentioned"]), event(10, kind="private"),
        event(11, sender=5), {"type": "message", "message": {"id": 12}},
        {"type": "user_topic", "stream_id": 7}, {"type": "heartbeat"},
    ]

    def build():
        from z_iris.pipeline import Pipeline
        pipeline = Pipeline("work", "chat.example.com", 5, MuteState.from_register(register),
                            Settings(parse(toml)))
        out = []
        for e in events:
            n = pipeline.handle(e)
            out.append(None if n is None else {
                "id": n.message.id, "url": n.url, "reason": n.reason,
                "action": {**dataclasses.asdict(n.action), "sound": unhome(n.action.sound)}})
        return out
    return [run("pipeline", {"toml": toml, "register": register, "events": events}, build)]


FIXTURES = {
    "engine": engine_cases,
    "pipeline": pipeline_cases,
    "sender": sender_cases,
    "plain": plain_cases,
    "config": config_cases,
    "action": action_cases,
    "pick": pick_cases,
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
