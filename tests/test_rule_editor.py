"""Rules without names, several channels and channel patterns, auto-sorting,
and one volume per rule plus a master."""

import pytest

from z_iris.config import ConfigError, parse_config, resolve_action
from z_iris.editing import apply_edit, read_editable
from z_iris.message import Message
from z_iris.rules import pick_rule

BASE = '[[server]]\nname = "work"\nzuliprc = "/x"\n'


def channel_message(name, topic="t"):
    return Message("work", "h", 1, "channel", 9, "Ada", "x", frozenset(), 7, name, topic, ())


def rules(text):
    return parse_config(BASE + text).rules


# matching


def test_a_rule_can_name_several_channels():
    (rule,) = rules('[[rule]]\nmatch = "channel"\nchannel = ["ops", "Deploys"]\n')
    assert pick_rule([rule], channel_message("ops")) is rule
    assert pick_rule([rule], channel_message("deploys")) is rule
    assert pick_rule([rule], channel_message("general")) is None


def test_a_plain_channel_matches_only_that_whole_name():
    (rule,) = rules('[[rule]]\nmatch = "channel"\nchannel = "ops"\n')
    assert pick_rule([rule], channel_message("OPS")) is rule
    assert pick_rule([rule], channel_message("devops")) is None
    assert pick_rule([rule], channel_message("ops-east")) is None


def test_channel_patterns_match_the_whole_name():
    (rule,) = rules('[[rule]]\nmatch = "channel"\nchannel = ["ops-.*", "team-(a|b)"]\n')
    for name in ("ops-east", "OPS-west", "team-a", "team-b"):
        assert pick_rule([rule], channel_message(name)) is rule, name
    for name in ("my-ops-east", "team-c", "team-ab"):
        assert pick_rule([rule], channel_message(name)) is None, name


def test_a_topic_rule_s_channels_work_the_same_way():
    (rule,) = rules('[[rule]]\nmatch = "topic"\nchannel = ["ops", "infra-.*"]\ntopic = "^deploy"\n')
    assert pick_rule([rule], channel_message("infra-eu", "deploy now")) is rule
    assert pick_rule([rule], channel_message("general", "deploy now")) is None


@pytest.mark.parametrize("value, error", [
    ('"("', "bad channel pattern"), ("[]", "channel"), ('[""]', "channel"), ("[1]", "channel"),
])
def test_bad_channels_are_refused_naming_the_rule(value, error):
    with pytest.raises(ConfigError, match=error) as caught:
        rules(f'[[rule]]\ndescription = "ops alerts"\nmatch = "channel"\nchannel = {value}\n')
    assert "ops alerts" in str(caught.value)


# descriptions instead of names


def test_rules_need_no_name_and_are_labelled_by_what_they_match():
    found = rules(
        '[[rule]]\nmatch = "channel"\nchannel = ["ops", "deploys"]\n'
        '[[rule]]\nmatch = "dm"\n'
        '[[rule]]\nmatch = "keyword"\nkeyword = "outage"\n'
        '[[rule]]\nmatch = "topic"\nchannel = "ops"\ntopic = "^deploy"\n'
    )
    assert [r.label for r in found] == [
        "Channel #ops, #deploys", "Direct message", "Keyword /outage/", "Topic /^deploy/ in #ops",
    ]


def test_a_description_is_the_label_and_an_old_name_becomes_one():
    described, named = rules(
        '[[rule]]\ndescription = "Pages"\nmatch = "mention"\n'
        '[[rule]]\nname = "old"\nmatch = "dm"\n'
    )
    assert (described.label, named.label) == ("Pages", "old")


def test_the_action_carries_the_label_and_the_rule_s_position():
    config = parse_config(BASE + '[[rule]]\nmatch = "dm"\n[[rule]]\nmatch = "dm"\n')
    first, second = (resolve_action(config, "work", r) for r in config.rules)
    assert first.rule == second.rule == "Direct message"
    assert (first.rule_index, second.rule_index) == (0, 1)


# the editor: descriptions, channel lists, sorting


def test_the_editor_reads_descriptions_and_channel_lists():
    data = read_editable(BASE + '[[rule]]\nname = "old"\nmatch = "channel"\nchannel = "ops"\n'
                         '[[rule]]\nmatch = "channel"\nchannel = ["a", "b"]\n')
    assert data["rules"][0]["description"] == "old" and "name" not in data["rules"][0]
    assert data["rules"][0]["channel"] == ["ops"]
    assert data["rules"][1]["channel"] == ["a", "b"]


def test_saving_writes_descriptions_and_one_or_many_channels():
    new = apply_edit(BASE + '[[rule]]\nname = "old"\nmatch = "dm"\n', {"rules": [
        {"description": "pages", "match": "channel", "channel": ["ops"]},
        {"match": "channel", "channel": ["a", "b"]},
    ]})
    assert 'name = "old"' not in new
    assert 'description = "pages"' in new and 'channel = "ops"' in new
    assert 'channel = ["a", "b"]' in new


def test_saving_sorts_by_priority_then_label():
    new = apply_edit(BASE, {"rules": [
        {"match": "keyword", "keyword": "x"},
        {"description": "zeta", "match": "dm", "priority": 5},
        {"description": "Alpha", "match": "mention"},
        {"match": "channel", "channel": ["ops"], "priority": 5},
    ]})
    assert [r.label for r in parse_config(new).rules] == [
        "Channel #ops", "zeta", "Alpha", "Keyword /x/",
    ]


# volumes: a rule's volume and the master


def test_the_editor_folds_a_shared_server_volume_into_the_master():
    text = BASE.replace('zuliprc = "/x"\n', 'zuliprc = "/x"\nvolume = 50\n') + \
        "[defaults]\nvolume = 40\nmaster_volume = 50\n"
    data = read_editable(text)
    assert data["defaults"]["master_volume"] == 25
    assert "volume" not in data["servers"][0]
    new = apply_edit(text, {"defaults": {"master_volume": data["defaults"]["master_volume"]}})
    config = parse_config(new)
    assert config.servers[0].volume == 100 and config.master_volume == 25
    assert resolve_action(config, "work", None).volume == resolve_action(parse_config(text), "work", None).volume


def test_different_server_volumes_are_left_alone():
    text = ('[[server]]\nname = "a"\nzuliprc = "/x"\nvolume = 50\n'
            '[[server]]\nname = "b"\nzuliprc = "/y"\nvolume = 80\n[defaults]\nmaster_volume = 50\n')
    assert read_editable(text)["defaults"]["master_volume"] == 50
    new = apply_edit(text, {"defaults": {"master_volume": 50}})
    assert [s.volume for s in parse_config(new).servers] == [50, 80]
