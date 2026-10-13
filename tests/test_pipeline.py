from z_iris.mutes import MuteState
from z_iris.pipeline import Pipeline

SELF = 5


def pipeline(channels=False):
    mutes = MuteState.from_register(
        {
            "subscriptions": [{"stream_id": 7, "name": "ops", "is_muted": False}],
            "user_topics": [],
        }
    )
    return Pipeline("work", "chat.example.com", SELF, mutes, channels)


def event(flags=(), topic="deploys", sender=9):
    return {
        "type": "message",
        "flags": list(flags),
        "message": {
            "id": 101,
            "type": "stream",
            "stream_id": 7,
            "display_recipient": "ops",
            "subject": topic,
            "sender_id": sender,
            "sender_full_name": "Ada",
            "content": "hi",
        },
    }


def test_mention_becomes_a_notification_with_a_url():
    n = pipeline().handle(event(["mentioned"]))
    assert n is not None
    assert n.reason == "mention"
    assert (
        n.url == "zulip://chat.example.com/#narrow/stream/7-ops/topic/deploys/near/101"
    )
    assert n.message.sender_name == "Ada"


def test_ordinary_channel_message_is_ignored():
    assert pipeline().handle(event()) is None


def test_mute_events_change_later_decisions():
    p = pipeline(channels=True)
    assert p.handle(event()) is not None
    p.handle(
        {
            "type": "user_topic",
            "stream_id": 7,
            "topic_name": "deploys",
            "visibility_policy": 1,
        }
    )
    assert p.handle(event()) is None


def test_malformed_and_unrelated_events_are_ignored():
    p = pipeline(channels=True)
    assert p.handle({"type": "message", "message": {}}) is None
    assert p.handle({"type": "heartbeat"}) is None
    assert p.handle({}) is None
    assert p.handle({"type": "user_topic"}) is None
