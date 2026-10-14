from z_iris.config import parse_config
from z_iris.preview import PreviewSource
from z_iris.settings import Settings

CONFIG = """
[[server]]
name = "work"
zuliprc = "/x/zuliprc"
[[rule]]
name = "ops"
match = "channel"
channel = "ops"
volume = 80
sound = "bell"
"""


def stream_message(id, channel="ops", topic="t", sender=9, content="hi", flags=()):
    return {"id": id, "type": "stream", "stream_id": 7, "display_recipient": channel,
            "subject": topic, "sender_id": sender, "sender_full_name": "Ada",
            "content": content, "flags": list(flags)}


def dm_message(id, flags=()):
    return {"id": id, "type": "private", "sender_id": 9, "sender_full_name": "Ada",
            "content": "psst", "display_recipient": [{"id": 9}, {"id": 5}],
            "flags": list(flags)}


class FakeClient:
    base_url = "https://chat.example.com/"
    calls = 0

    def __init__(self, messages):
        self.messages = messages

    def register(self, **kwargs):
        FakeClient.calls += 1
        return {"result": "success", "queue_id": "q", "last_event_id": 1,
                "subscriptions": [{"stream_id": 7, "name": "ops", "is_muted": False}],
                "user_topics": [{"stream_id": 7, "topic_name": "noise", "visibility_policy": 1}]}

    def deregister(self, queue_id):
        return {"result": "success"}

    def get_profile(self):
        return {"result": "success", "user_id": 5}

    def get_messages(self, request):
        assert request["anchor"] == "newest" and request["num_after"] == 0
        return {"result": "success", "messages": self.messages}


def source(messages, clock=lambda: 0.0):
    return PreviewSource(lambda _rc: FakeClient(messages), now=clock)


def settings():
    return Settings(parse_config(CONFIG))


def test_preview_reports_the_winning_rule_and_why_for_each_message():
    messages = [
        stream_message(1),
        stream_message(2, channel="dev"),
        stream_message(3, sender=5),
        stream_message(4, topic="noise"),
        dm_message(5),
    ]
    result = source(messages).preview(settings())
    entries = result["servers"][0]["messages"]
    assert [e["id"] for e in entries] == [5, 4, 3, 2, 1]  # newest first
    by_id = {e["id"]: e for e in entries}
    assert (by_id[1]["why"], by_id[1]["rule_index"]) == ("rule", 0)
    assert by_id[1]["sound"] == "bell" and by_id[1]["volume"] == 80
    assert by_id[2]["why"] == "channel messages not enabled"
    assert by_id[3]["why"] == "own message"
    assert by_id[4]["why"] == "muted"
    assert by_id[5]["why"] == "dm" and by_id[5]["rule_index"] is None
    assert by_id[1]["where"] == "#ops > t" and by_id[5]["where"] == "DM"
    assert result["servers"][0]["fetched"] == 5


def test_snippets_are_short_and_single_line():
    long = stream_message(1, content="a\n" + "b" * 500)
    entry = source([long]).preview(settings())["servers"][0]["messages"][0]
    assert "\n" not in entry["text"] and len(entry["text"]) <= 200


def test_snapshot_is_cached_until_it_expires_or_refresh_is_asked():
    now = [0.0]
    FakeClient.calls = 0
    src = source([stream_message(1)], clock=lambda: now[0])
    src.preview(settings())
    src.preview(settings())
    assert FakeClient.calls == 1
    src.preview(settings(), refresh=True)
    assert FakeClient.calls == 2
    now[0] = 1000.0
    src.preview(settings())
    assert FakeClient.calls == 3


def test_a_failing_server_reports_an_error_not_a_crash():
    def broken(_rc):
        raise OSError("no network")

    result = PreviewSource(broken).preview(settings())
    assert "no network" in result["servers"][0]["error"]
    assert result["servers"][0]["messages"] == []


def test_a_malformed_message_is_skipped():
    result = source([{"id": 1}, stream_message(2)]).preview(settings())
    assert [e["id"] for e in result["servers"][0]["messages"]] == [2]
