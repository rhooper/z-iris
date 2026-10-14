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
    assert data["servers"] == [{"name": "work", "volume": 100}]
    assert data["defaults"]["volume"] == 60
    assert data["rules"][0]["name"] == "old"
    assert "zuliprc" not in str(data)


def test_apply_edit_replaces_rules_and_keeps_comments_and_zuliprc():
    new = apply_edit(TEXT, {"rules": [RULE]})
    assert "# my config" in new and "# keep me" in new and "# base level" in new
    config = parse_config(new)
    assert [r.name for r in config.rules] == ["outage"]
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
