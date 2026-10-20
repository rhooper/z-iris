from pathlib import Path

import pytest

from z_iris.media import MessageImages
from z_iris.message import Message
from z_iris.sender import Sender, sender_for

AVATAR, PICTURE = Path("/c/av.png"), Path("/c/pic.png")


def dm(ids=(9,), names=("Ada",), sender="Ada"):
    return Message("work", "h", 101, "dm", 9, sender, "x", frozenset(), None, None, None,
                   tuple(ids), dm_names=tuple(names))


def channel():
    return Message("work", "h", 101, "channel", 9, "Ada", "x", frozenset(), 7, "ops",
                   "deploys", ())


def test_a_dm_is_the_sender_with_today_s_title_as_name():
    s = sender_for(dm(), "Ada", MessageImages(AVATAR, PICTURE))
    assert s == Sender("zulip:work:9", "Ada", AVATAR, PICTURE, "work:dm:9", None, ())


def test_a_channel_message_names_the_sender_with_the_full_title():
    s = sender_for(channel(), "Ada (#ops > deploys)", MessageImages(AVATAR, None))
    assert s.name == "Ada (#ops > deploys)" and s.group_name is None
    assert s.conversation == "work:channel:7:deploys" and s.members == ()


def test_a_group_dm_is_a_group_named_like_today():
    s = sender_for(dm((3, 9, 12), ("Bob", "Ada", "Cy")), "Ada (group)", MessageImages(AVATAR, None))
    assert (s.name, s.group_name) == ("Ada", "group")
    assert s.conversation == "work:dm:3,9,12"
    assert s.members == (("zulip:work:3", "Bob"), ("zulip:work:9", "Ada"), ("zulip:work:12", "Cy"))


def test_a_group_without_avatar_or_names_is_still_a_group():
    s = sender_for(dm((3, 12), ("", "Cy")), "Ada (group)", MessageImages(None, None))
    assert s is not None and s.avatar is None
    assert s.members == (("zulip:work:3", ""), ("zulip:work:12", "Cy"))


def test_a_dm_without_an_avatar_has_no_sender():
    assert sender_for(dm(), "Ada", MessageImages(None, PICTURE)) is None


def test_json_round_trip_keeps_text_intact():
    s = Sender("zulip:w:9", 'Ada "x"\n🎉', AVATAR, None, "w:dm:9", "group",
               (("zulip:w:3", "Bob"),))
    assert Sender.from_json(s.to_json()) == s
    __import__("json").dumps(s.to_json())  # serialisable


@pytest.mark.parametrize("data", [{}, [], None, "x", {"handle": 1},
                                  {"handle": "h", "name": "n", "conversation": "c",
                                   "members": [["only one"]]}])
def test_malformed_json_is_no_sender(data):
    assert Sender.from_json(data) is None
