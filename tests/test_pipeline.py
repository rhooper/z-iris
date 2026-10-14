from z_iris.config import parse_config
from z_iris.mutes import MuteState
from z_iris.pipeline import Pipeline
from z_iris.settings import Settings

SELF = 5


def pipeline(channels=False, rules=""):
    config = parse_config(
        '[[server]]\nname = "work"\nzuliprc = "/x"\n'
        f"[defaults]\nnotify_channel_messages = {str(channels).lower()}\n" + rules
    )
    mutes = MuteState.from_register(
        {
            "subscriptions": [{"stream_id": 7, "name": "ops", "is_muted": False}],
            "user_topics": [],
        }
    )
    return Pipeline("work", "chat.example.com", SELF, mutes, Settings(config))


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


OPS_RULE = '[[rule]]\nname = "ops"\nmatch = "channel"\nchannel = "ops"\nvolume = 80\n'


def test_channel_rule_notifies_without_the_global_channel_switch():
    n = pipeline(rules=OPS_RULE).handle(event())
    assert n is not None
    assert n.reason == "rule"
    assert (n.action.rule, n.action.volume) == ("ops", 80)


def test_rule_cannot_override_a_muted_topic_but_a_mention_still_wins():
    p = pipeline(rules=OPS_RULE)
    p.handle(
        {
            "type": "user_topic",
            "stream_id": 7,
            "topic_name": "deploys",
            "visibility_policy": 1,
        }
    )
    assert p.handle(event()) is None
    assert p.handle(event(["mentioned"])) is not None


def test_rule_cannot_notify_for_own_messages():
    assert pipeline(rules=OPS_RULE).handle(event(sender=SELF)) is None


def test_dm_rule_carries_its_sound_and_volume():
    rules = '[[rule]]\nname = "dm"\nmatch = "dm"\nsound = "none"\nvolume = 10\n'
    dm_event = {
        "type": "message",
        "flags": [],
        "message": {
            "id": 5, "type": "private", "sender_id": 9,
            "sender_full_name": "Ada", "content": "hi",
            "display_recipient": [{"id": 9}, {"id": SELF}],
        },
    }
    n = pipeline(rules=rules).handle(dm_event)
    assert (n.action.sound, n.action.volume, n.action.rule) == ("none", 10, "dm")


def test_no_rule_uses_the_default_action():
    n = pipeline().handle(event(["mentioned"]))
    assert (n.action.sound, n.action.volume, n.action.rule) == ("synth", 60, None)


def test_a_fully_silent_rule_drops_the_message():
    rules = (
        '[[rule]]\nname = "quiet"\nmatch = "channel"\nchannel = "ops"\n'
        'sound = "none"\nbanner = "off"\n'
    )
    assert pipeline(rules=rules).handle(event(["mentioned"])) is None
