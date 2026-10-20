import re

import pytest

from z_iris.message import Message
from z_iris.narrow import encode_component, narrow_url


def channel(name="ops", topic="deploys"):
    return Message(
        "w", "chat.example.com", 101, "channel", 9, "Ada", "x",
        frozenset(), 7, name, topic, (),
    )


def dm(ids):
    return Message(
        "w", "chat.example.com", 101, "dm", 9, "Ada", "x",
        frozenset(), None, None, None, tuple(ids),
    )


@pytest.mark.parametrize(
    "text, expected",
    [
        ("deploys", "deploys"),
        ("two words", "two.20words"),
        ("a.b", "a.2Eb"),
        ("a/b", "a.2Fb"),
        ("c#1", "c.231"),
        ("100%", "100.25"),
        ("café", "caf.C3.A9"),
        ("🚀", ".F0.9F.9A.80"),
    ],
)
def test_encode_component_matches_zulip(text, expected):
    assert encode_component(text) == expected


def test_channel_url():
    assert narrow_url(channel()) == (
        "zulip://chat.example.com/#narrow/channel/7-ops/topic/deploys/with/101"
    )


def test_channel_url_encodes_names():
    url = narrow_url(channel("my team", "q&a: 1.0"))
    assert url == (
        "zulip://chat.example.com/#narrow/channel/7-my.20team"
        "/topic/q.26a.3A.201.2E0/with/101"
    )


def test_one_to_one_dm_url():
    assert narrow_url(dm([9])) == "zulip://chat.example.com/#narrow/dm/9-pm/with/101"


def test_group_dm_url():
    assert narrow_url(dm([3, 12])) == (
        "zulip://chat.example.com/#narrow/dm/3,12-group/with/101"
    )


def test_url_only_contains_characters_the_desktop_handler_accepts():
    url = narrow_url(channel("a b/c", "x.y#z 🚀"))
    fragment = url.split("#", 1)[1]
    assert re.fullmatch(r"narrow/[\w.~/,:+\-]+", fragment)
