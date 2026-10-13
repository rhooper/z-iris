from z_iris.mutes import MuteState


def register(**extra):
    base = {
        "subscriptions": [
            {"stream_id": 1, "name": "ops", "is_muted": False},
            {"stream_id": 2, "name": "random", "is_muted": True},
        ],
        "user_topics": [
            {"stream_id": 1, "topic_name": "Noise", "visibility_policy": 1},
            {"stream_id": 2, "topic_name": "important", "visibility_policy": 2},
            {"stream_id": 2, "topic_name": "watched", "visibility_policy": 3},
            {"stream_id": 1, "topic_name": "plain", "visibility_policy": 0},
        ],
    }
    base.update(extra)
    return base


def test_initial_state():
    m = MuteState.from_register(register())
    assert not m.is_muted(1, "anything")
    assert m.is_muted(1, "noise")  # case-insensitive
    assert m.is_muted(2, "chatter")
    assert not m.is_muted(2, "IMPORTANT")
    assert not m.is_muted(2, "watched")
    assert not m.is_muted(1, "plain")


def test_legacy_muted_topics_list():
    response = {
        "subscriptions": [{"stream_id": 1, "name": "ops", "is_muted": False}],
        "muted_topics": [["ops", "Noise", 1700000000]],
    }
    m = MuteState.from_register(response)
    assert m.is_muted(1, "noise")
    assert not m.is_muted(1, "other")


def test_subscription_events():
    m = MuteState.from_register(register())
    m.apply(
        {
            "type": "subscription",
            "op": "update",
            "stream_id": 1,
            "property": "is_muted",
            "value": True,
        }
    )
    assert m.is_muted(1, "anything")
    m.apply(
        {
            "type": "subscription",
            "op": "update",
            "stream_id": 1,
            "property": "color",
            "value": "#fff",
        }
    )
    assert m.is_muted(1, "anything")
    m.apply(
        {
            "type": "subscription",
            "op": "add",
            "subscriptions": [{"stream_id": 3, "name": "new", "is_muted": True}],
        }
    )
    assert m.is_muted(3, "x")
    m.apply(
        {
            "type": "subscription",
            "op": "remove",
            "subscriptions": [{"stream_id": 3}],
        }
    )
    assert not m.is_muted(3, "x")


def test_user_topic_event():
    m = MuteState.from_register(register())
    m.apply(
        {
            "type": "user_topic",
            "stream_id": 1,
            "topic_name": "Fresh",
            "visibility_policy": 1,
        }
    )
    assert m.is_muted(1, "fresh")
    m.apply(
        {
            "type": "user_topic",
            "stream_id": 1,
            "topic_name": "fresh",
            "visibility_policy": 0,
        }
    )
    assert not m.is_muted(1, "fresh")


def test_legacy_muted_topics_event_replaces_the_list():
    m = MuteState.from_register(register(user_topics=[], muted_topics=[]))
    m.apply({"type": "muted_topics", "muted_topics": [["ops", "Noise", 1]]})
    assert m.is_muted(1, "noise")
    m.apply({"type": "muted_topics", "muted_topics": []})
    assert not m.is_muted(1, "noise")


def test_unknown_events_are_ignored():
    m = MuteState.from_register(register())
    m.apply({"type": "heartbeat"})
    m.apply({"type": "subscription", "op": "peer_add"})


def test_two_instances_do_not_share_state():
    a = MuteState.from_register(register())
    b = MuteState()
    assert a.is_muted(1, "noise")
    assert not b.is_muted(1, "noise")
