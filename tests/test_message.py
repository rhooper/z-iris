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
