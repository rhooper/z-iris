import pytest

from z_iris.message import message_from_event

SELF = 5


def channel_event(**overrides):
    message = {
        "id": 101,
        "type": "stream",
        "stream_id": 7,
        "display_recipient": "ops",
        "subject": "deploys",
        "sender_id": 9,
        "sender_full_name": "Ada",
        "content": "hello",
    }
    message.update(overrides)
    return {"type": "message", "message": message, "flags": ["mentioned"]}


def test_channel_message():
    m = message_from_event("work", "chat.example.com", SELF, channel_event())
    assert (m.kind, m.channel_id, m.channel_name, m.topic) == (
        "channel",
        7,
        "ops",
        "deploys",
    )
    assert (m.id, m.sender_id, m.sender_name, m.content) == (101, 9, "Ada", "hello")
    assert m.is_mention and not m.is_wildcard_mention and not m.has_alert_word
    assert m.dm_user_ids == ()


def test_topic_key_fallback():
    event = channel_event()
    event["message"]["topic"] = event["message"].pop("subject")
    assert message_from_event("w", "h", SELF, event).topic == "deploys"


def dm_event(people):
    return {
        "type": "message",
        "message": {
            "id": 5,
            "type": "private",
            "display_recipient": [{"id": i, "full_name": f"p{i}"} for i in people],
            "sender_id": people[0],
            "sender_full_name": "p",
            "content": "x",
        },
        "flags": [],
    }


def test_one_to_one_dm_names_the_other_person():
    m = message_from_event("w", "h", SELF, dm_event([9, SELF]))
    assert (m.kind, m.dm_user_ids) == ("dm", (9,))


def test_group_dm_lists_everyone_but_me_sorted():
    m = message_from_event("w", "h", SELF, dm_event([12, SELF, 3]))
    assert m.dm_user_ids == (3, 12)


def test_dm_to_self():
    m = message_from_event("w", "h", SELF, dm_event([SELF]))
    assert m.dm_user_ids == (SELF,)


def test_malformed_event_raises():
    with pytest.raises((KeyError, TypeError)):
        message_from_event("w", "h", SELF, {"type": "message", "message": {}})


def test_new_style_wildcard_flags_count_as_wildcard_mentions():
    base = {"type": "message", "message": {
        "id": 1, "type": "stream", "stream_id": 1, "display_recipient": "c",
        "subject": "t", "sender_id": 2, "sender_full_name": "A", "content": "x"}}
    for flag in ("wildcard_mentioned", "stream_wildcard_mentioned", "topic_wildcard_mentioned"):
        m = message_from_event("w", "h", 5, {**base, "flags": [flag]})
        assert m.is_wildcard_mention and not m.is_mention


def test_message_carries_group_member_names():
    m = message_from_event("w", "h", SELF, dm_event([12, SELF, 3]))
    assert m.dm_names == ("p3", "p12")  # in dm_user_ids order
    event = dm_event([9, SELF])
    del event["message"]["display_recipient"][0]["full_name"]
    assert message_from_event("w", "h", SELF, event).dm_names == ("",)
    channel = message_from_event("w", "h", SELF, {"type": "message", "flags": [], "message": {
        "id": 1, "type": "stream", "stream_id": 1, "display_recipient": "c",
        "subject": "t", "sender_id": 2, "sender_full_name": "A", "content": "x"}})
    assert channel.dm_names == ()
