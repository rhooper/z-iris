from pathlib import Path

import pytest

from z_iris.config import ConfigError, load_config, parse_config

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
