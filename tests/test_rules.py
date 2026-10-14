import re

from z_iris.message import Message
from z_iris.rules import Rule, pick_rule


def channel(name="ops", topic="deploys", content="hello", flags=(), server="work"):
    return Message(
        server, "h", 1, "channel", 9, "Ada", content, frozenset(flags), 7, name,
        topic, (),
    )


def dm(ids=(9,), flags=()):
    return Message(
        "work", "h", 2, "dm", 9, "Ada", "x", frozenset(flags), None, None, None,
        tuple(ids),
    )


def rule(kind, index=0, name=None, channel=None, pattern=None, server=None,
         priority=0):
    return Rule(
        name or f"{kind}{index}", kind, channel,
        re.compile(pattern, re.IGNORECASE) if pattern else None,
        server, None, None, None, priority, index,
    )


def test_channel_rule_is_case_insensitive():
    assert pick_rule([rule("channel", channel="OPS")], channel()) is not None
    assert pick_rule([rule("channel", channel="dev")], channel()) is None
    assert pick_rule([rule("channel", channel="ops")], dm()) is None


def test_topic_rule_uses_regex_and_optional_channel():
    r = rule("topic", pattern="^dep")
    assert pick_rule([r], channel()) is r
    assert pick_rule([r], channel(topic="chat")) is None
    limited = rule("topic", pattern="dep", channel="dev")
    assert pick_rule([limited], channel()) is None
    assert pick_rule([r], dm()) is None


def test_keyword_rule_matches_content():
    r = rule("keyword", pattern=r"\boutage\b")
    assert pick_rule([r], channel(content="Big OUTAGE now")) is r
    assert pick_rule([r], channel(content="outages")) is None


def test_mention_rule_is_you_only_and_wildcard_rule_is_all_only():
    you, everyone = rule("mention"), rule("wildcard", index=1)
    assert pick_rule([you], channel(flags=["mentioned"])) is you
    assert pick_rule([you], channel(flags=["wildcard_mentioned"])) is None
    assert pick_rule([you], channel(flags=["has_alert_word"])) is None
    for flag in ("wildcard_mentioned", "stream_wildcard_mentioned", "topic_wildcard_mentioned"):
        assert pick_rule([everyone], channel(flags=[flag])) is everyone
    assert pick_rule([everyone], channel(flags=["mentioned"])) is None
    assert pick_rule([everyone], channel()) is None


def test_a_message_that_mentions_you_and_everyone_prefers_the_mention_rule():
    you, everyone = rule("mention", index=1), rule("wildcard", index=0)
    both = channel(flags=["mentioned", "wildcard_mentioned"])
    assert pick_rule([everyone, you], both) is you


def test_dm_and_group_dm_rules():
    one, group = rule("dm"), rule("group_dm", index=1)
    assert pick_rule([one, group], dm((9,))) is one
    assert pick_rule([one, group], dm((3, 9))) is group
    assert pick_rule([one, group], channel()) is None


def test_server_limits_a_rule():
    r = rule("channel", channel="ops", server="other")
    assert pick_rule([r], channel()) is None
    assert pick_rule([r], channel(server="other")) is r


def test_precedence_kind_then_priority_then_file_order():
    topic = rule("topic", 0, pattern="dep")
    chan = rule("channel", 1, channel="ops")
    assert pick_rule([chan, topic], channel()) is topic
    boosted = rule("channel", 1, channel="ops", priority=5)
    assert pick_rule([topic, boosted], channel()) is boosted
    a = rule("channel", 0, name="a", channel="ops")
    b = rule("channel", 1, name="b", channel="ops")
    assert pick_rule([b, a], channel()) is a


def test_no_match_returns_none():
    assert pick_rule([], channel()) is None


def test_alert_word_rule_matches_only_alert_word_messages():
    r = rule("alert_word")
    assert pick_rule([r], channel(flags=["has_alert_word"])) is r
    assert pick_rule([r], dm(flags=["has_alert_word"])) is r
    assert pick_rule([r], channel(flags=["mentioned"])) is None
    assert pick_rule([r], channel()) is None


def test_disabled_rules_never_match_and_keep_their_index():
    off = Rule("off", "mention", None, None, None, None, None, None, 9, 0, enabled=False)
    on = rule("mention", index=1)
    assert pick_rule([off, on], channel(flags=["mentioned"])) is on
    assert pick_rule([off], channel(flags=["mentioned"])) is None
