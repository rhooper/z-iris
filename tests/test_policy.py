import pytest

from z_iris.message import Message
from z_iris.mutes import MuteState
from z_iris.policy import decide

SELF = 5


def mutes(muted_channel=False, muted_topic=False):
    return MuteState.from_register(
        {
            "subscriptions": [
                {"stream_id": 1, "name": "ops", "is_muted": muted_channel}
            ],
            "user_topics": (
                [{"stream_id": 1, "topic_name": "t", "visibility_policy": 1}]
                if muted_topic
                else []
            ),
        }
    )


def channel_msg(flags=(), sender=9):
    return Message(
        "w", "h", 1, "channel", sender, "A", "x", frozenset(flags), 1, "ops", "t", ()
    )


def dm_msg(sender=9):
    return Message(
        "w", "h", 1, "dm", sender, "A", "x", frozenset(), None, None, None, (sender,)
    )


@pytest.mark.parametrize(
    "message, state, channels, notify, reason",
    [
        (channel_msg(sender=SELF, flags=["mentioned"]), mutes(), False, False, "own"),
        (dm_msg(sender=SELF), mutes(), False, False, "own"),
        (dm_msg(), mutes(), False, True, "dm"),
        (channel_msg(["mentioned"]), mutes(), False, True, "mention"),
        (channel_msg(["wildcard_mentioned"]), mutes(), False, True, "wildcard mention"),
        (channel_msg(["stream_wildcard_mentioned"]), mutes(), False, True, "wildcard mention"),
        (channel_msg(["has_alert_word"]), mutes(), False, True, "alert word"),
        (channel_msg(), mutes(), False, False, "not enabled"),
        (channel_msg(), mutes(), True, True, "channel"),
        (channel_msg(), mutes(muted_channel=True), True, False, "muted"),
        (channel_msg(), mutes(muted_topic=True), True, False, "muted"),
        (channel_msg(["mentioned"]), mutes(muted_topic=True), False, True, "mention"),
        (
            channel_msg(["wildcard_mentioned"]),
            mutes(muted_channel=True),
            False,
            False,
            "muted",
        ),
    ],
)
def test_decide(message, state, channels, notify, reason):
    decision = decide(message, state, SELF, channels)
    assert decision.notify is notify
    assert reason in decision.reason
