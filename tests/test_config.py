from pathlib import Path

import pytest

from z_iris.config import (
    Action,
    ConfigError,
    load_config,
    parse_config,
    resolve_action,
)

MINIMAL = """
[[server]]
name = "work"
zuliprc = "~/.zuliprc"
"""


def test_minimal_config_gets_defaults():
    config = parse_config(MINIMAL)
    assert [s.name for s in config.servers] == ["work"]
    assert config.servers[0].zuliprc == Path("~/.zuliprc").expanduser()
    assert config.sound == "synth"
    assert config.volume == 60
    assert config.notify_channel_messages is False
    assert config.player == ("play", "-q")
    assert config.notifier == "terminal-notifier"


def test_overrides_and_sound_path_expansion():
    config = parse_config(
        MINIMAL
        + """
[defaults]
sound = "~/Sounds/a.wav"
volume = 30
notify_channel_messages = true
[output]
player = ["play"]
notifier = "/opt/homebrew/bin/terminal-notifier"
"""
    )
    assert config.sound == str(Path("~/Sounds/a.wav").expanduser())
    assert config.volume == 30
    assert config.notify_channel_messages is True
    assert config.player == ("play",)
    assert config.notifier == "/opt/homebrew/bin/terminal-notifier"


@pytest.mark.parametrize(
    "text, message",
    [
        ("", "at least one"),
        ("not = [valid", "invalid TOML"),
        ('[[server]]\nzuliprc = "x"', "needs a name"),
        ('[[server]]\nname = "a"', "needs a zuliprc"),
        (MINIMAL + MINIMAL, "duplicate"),
        (MINIMAL + "[defaults]\nvolume = 101", "volume"),
        (MINIMAL + "[defaults]\nvolume = -1", "volume"),
        (MINIMAL + "[defaults]\nvolume = true", "volume"),
        (MINIMAL + '[defaults]\nvolume = "loud"', "volume"),
        (MINIMAL + "[defaults]\nsound = 3", "sound"),
        (MINIMAL + '[defaults]\nnotify_channel_messages = "yes"', "notify_channel"),
        (MINIMAL + "[output]\nplayer = []", "player"),
        (MINIMAL + '[output]\nplayer = "play"', "player"),
    ],
)
def test_bad_config_is_rejected(text, message):
    with pytest.raises(ConfigError, match=message):
        parse_config(text)


def test_missing_file_explains_itself(tmp_path):
    with pytest.raises(ConfigError, match="config.example.toml"):
        load_config(tmp_path / "nope.toml")


def test_load_reads_a_file(tmp_path):
    path = tmp_path / "c.toml"
    path.write_text(MINIMAL)
    assert load_config(path).servers[0].name == "work"


RULE_BASE = MINIMAL + "\n"


def rule_config(body):
    return parse_config(RULE_BASE + "[[rule]]\n" + body)


def test_keyword_rule_parses_with_pattern_and_order():
    config = parse_config(
        MINIMAL
        + '[[rule]]\nname = "a"\nmatch = "keyword"\nkeyword = "Outage"\n'
        + 'volume = 90\nbanner = "title"\nsound = "none"\npriority = 2\n'
        + '[[rule]]\nname = "b"\nmatch = "mention"\n'
    )
    first, second = config.rules
    assert (first.name, first.kind, first.index) == ("a", "keyword", 0)
    assert first.pattern.search("an OUTAGE")
    assert (first.volume, first.banner, first.sound, first.priority) == (
        90, "title", "none", 2,
    )
    assert (second.name, second.index, second.priority) == ("b", 1, 0)


@pytest.mark.parametrize(
    "body",
    [
        'name = "r"\nmatch = "nope"\n',
        'name = "r"\nmatch = "channel"\n',
        'name = "r"\nmatch = "topic"\n',
        'name = "r"\nmatch = "keyword"\nkeyword = "("\n',
        'name = "r"\nmatch = "mention"\nvolume = 101\n',
        'name = "r"\nmatch = "mention"\nvolume = "loud"\n',
        'name = "r"\nmatch = "mention"\nbanner = "huge"\n',
        'name = "r"\nmatch = "mention"\nserver = "ghost"\n',
        'name = "r"\nmatch = "mention"\nsound = "/no/such/file.wav"\n',
        'name = "r"\nmatch = "mention"\npriority = "high"\n',
    ],
)
def test_bad_rules_name_the_rule(body):
    with pytest.raises(ConfigError, match="rule 'r'"):
        rule_config(body)


def test_rule_without_a_name_is_rejected():
    with pytest.raises(ConfigError, match="rule"):
        rule_config('match = "mention"\n')


def test_rule_sound_file_is_expanded(tmp_path):
    sound = tmp_path / "a.wav"
    sound.write_bytes(b"")
    config = rule_config(f'name = "r"\nmatch = "mention"\nsound = "{sound}"\n')
    assert config.rules[0].sound == str(sound)


def test_master_and_server_volume():
    config = parse_config(
        MINIMAL.replace('"~/.zuliprc"', '"~/.zuliprc"\nvolume = 50')
        + "[defaults]\nmaster_volume = 40\n"
    )
    assert config.servers[0].volume == 50
    assert config.master_volume == 40
    assert parse_config(MINIMAL).master_volume == 100
    for bad in ("master_volume = 101", 'master_volume = "x"'):
        with pytest.raises(ConfigError):
            parse_config(MINIMAL + f"[defaults]\n{bad}\n")
    with pytest.raises(ConfigError):
        parse_config(MINIMAL.replace('"~/.zuliprc"', '"~/.zuliprc"\nvolume = -1'))


def test_resolve_action():
    base = parse_config(MINIMAL)
    assert resolve_action(base, "work", None) == Action("synth", 60, "full", None)
    config = parse_config(
        MINIMAL.replace('"~/.zuliprc"', '"~/.zuliprc"\nvolume = 50')
        + "[defaults]\nmaster_volume = 50\n"
        + '[[rule]]\nname = "r"\nmatch = "mention"\nvolume = 80\nsound = "none"\n'
    )
    action = resolve_action(config, "work", config.rules[0])
    assert action == Action("none", 20, "full", "r")
