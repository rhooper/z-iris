import pytest

from z_iris.config import ConfigError, parse_config
from z_iris.editing import apply_edit, read_editable

TEXT = '''# my config
[[server]]
name = "work"
zuliprc = "~/.zuliprc"   # keep me

[defaults]
volume = 60  # base level

[[rule]]
name = "old"
match = "mention"
'''

RULE = {"name": "outage", "match": "keyword", "keyword": "outage", "volume": 90,
        "sound": "none", "banner": "title", "priority": 1, "server": "work"}


def test_read_editable_hides_zuliprc_and_lists_rules():
    data = read_editable(TEXT)
    assert data["servers"] == [{"name": "work"}]  # volume folds into the master
    assert data["defaults"]["volume"] == 60
    assert data["rules"][0]["description"] == "old"
    assert "zuliprc" not in str(data)


def test_apply_edit_replaces_rules_and_keeps_comments_and_zuliprc():
    new = apply_edit(TEXT, {"rules": [RULE]})
    assert "# my config" in new and "# keep me" in new and "# base level" in new
    config = parse_config(new)
    assert [r.label for r in config.rules] == ["outage"]
    assert config.rules[0].volume == 90 and config.rules[0].banner == "title"
    assert str(config.servers[0].zuliprc).endswith(".zuliprc")


def test_apply_edit_updates_defaults_and_server_volume():
    new = apply_edit(TEXT, {
        "defaults": {"volume": 30, "master_volume": 80, "sound": "chime",
                     "notify_channel_messages": True},
        "servers": [{"name": "work", "volume": 50}],
    })
    config = parse_config(new)
    assert (config.volume, config.master_volume, config.notify_channel_messages) == (30, 80, True)
    assert config.servers[0].volume == 50
    assert "# base level" in new


def test_empty_rule_list_removes_rules():
    assert parse_config(apply_edit(TEXT, {"rules": []})).rules == ()


def test_invalid_edit_raises_config_error_and_names_the_rule():
    bad = dict(RULE, volume=500)
    with pytest.raises(ConfigError, match="outage"):
        apply_edit(TEXT, {"rules": [bad]})
    with pytest.raises(ConfigError):
        apply_edit(TEXT, {"rules": [dict(RULE, keyword="(")]})


def test_blank_fields_are_omitted():
    new = apply_edit(TEXT, {"rules": [{"name": "m", "match": "mention", "sound": "",
                                        "volume": None, "server": "", "priority": 0}]})
    assert "sound" not in new.split("[[rule]]")[1]
    assert parse_config(new).rules[0].sound is None


def test_enabled_false_round_trips_and_true_is_not_written():
    rules = [{"name": "a", "match": "mention", "enabled": False},
             {"name": "b", "match": "mention", "enabled": True}]
    new = apply_edit(TEXT, {"rules": rules})
    assert new.count("enabled") == 1
    assert [r.enabled for r in parse_config(new).rules] == [False, True]
    data = read_editable(new)
    assert data["rules"][0]["enabled"] is False
    assert data["rules"][1].get("enabled", True) is True


def test_behaviour_fields_round_trip():
    rule = {"name": "r", "match": "mention", "flash": "top", "flash_color": "#112233",
            "flash_seconds": 1.2, "repeat": 2, "repeat_every": 15, "repeat_boost": 10,
            "min_gap": 4, "batch_window": 6, "sticky": True}
    new = apply_edit(TEXT, {"rules": [rule], "defaults": {"min_gap": 3, "flash": "screen",
                                                           "sticky": False}})
    config = parse_config(new)
    assert config.rules[0].behaviour["flash"] == "top"
    assert config.rules[0].behaviour["sticky"] is True
    assert read_editable(new)["rules"][0]["sticky"] is True
    assert config.behaviour["sticky"] is False
    assert config.behaviour["min_gap"] == 3 and config.behaviour["flash"] == "screen"
    data = read_editable(new)
    assert data["rules"][0]["repeat_every"] == 15
    assert data["defaults"]["flash"] == "screen" and data["defaults"]["min_gap"] == 3


def test_focus_round_trips_and_keeps_comments():
    text = TEXT + '\n[focus]\nmode = "off"  # focus note\n'
    focus = {"mode": "mentions_and_dms", "quiet_hours": ["22:00-07:00", "12:00-13:00"],
             "quiet_mode": "silent"}
    new = apply_edit(text, {"focus": focus})
    assert "# focus note" in new and "# base level" in new
    config = parse_config(new)
    assert config.focus.mode == "mentions_and_dms"
    assert config.focus.quiet_hours == ((1320, 420), (720, 780))
    assert read_editable(new)["focus"] == focus


def test_focus_defaults_and_bad_values():
    assert read_editable(TEXT)["focus"] == {"mode": "off", "quiet_hours": [], "quiet_mode": "silent"}
    new = apply_edit(TEXT, {"focus": {"mode": "silent", "quiet_hours": [], "quiet_mode": "silent"}})
    assert parse_config(new).focus.mode == "silent"
    with pytest.raises(ConfigError, match="focus"):
        apply_edit(TEXT, {"focus": {"mode": "bogus"}})
    with pytest.raises(ConfigError, match="quiet"):
        apply_edit(TEXT, {"focus": {"quiet_hours": ["late"]}})


def test_replace_sound_switches_default_and_rules_and_keeps_comments():
    from z_iris.editing import replace_sound

    text = (
        '[[server]]\nname = "w"\nzuliprc = "/x"\n\n'
        '[defaults]\n# my default\nsound = "Horn"\n\n'
        '[[rule]]\nname = "a"\nmatch = "dm"\nsound = "Horn"  # loud\n\n'
        '[[rule]]\nname = "b"\nmatch = "mention"\nsound = "bell"\n'
    )
    new = replace_sound(text, "Horn", "dx-bells")
    config = parse_config(new)
    assert config.sound == "dx-bells"
    assert [r.sound for r in config.rules] == ["dx-bells", "bell"]
    assert "# my default" in new and "# loud" in new
    assert replace_sound(text, "Gong", "bell") == text
