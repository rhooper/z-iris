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

    def __init__(self, messages, mentions=()):
        self.messages = messages
        self.mentions = list(mentions)
        self.requests = []

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
        self.requests.append(request)
        if request.get("narrow") == [{"operator": "is", "operand": "mentioned"}]:
            return {"result": "success", "messages": self.mentions}
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


def test_older_mentions_outside_the_recent_window_are_included_once():
    recent = [stream_message(10), stream_message(11, flags=["mentioned"])]
    older = [stream_message(2, flags=["mentioned"]), stream_message(11, flags=["mentioned"])]
    src = PreviewSource(lambda _rc: FakeClient(recent, older))
    entries = src.preview(settings())["servers"][0]["messages"]
    assert [e["id"] for e in entries] == [11, 10, 2]
    assert entries[2]["why"] == "rule" or entries[2]["why"] == "mention"


def test_fetch_more_pages_back_from_the_oldest_message_and_keeps_the_cache():
    class Paging(FakeClient):
        def get_messages(self, request):
            if request.get("narrow"):
                return {"result": "success", "messages": []}
            self.requests.append(request)
            if request["anchor"] == "newest":
                return {"result": "success", "messages": [stream_message(10), stream_message(11)],
                        "found_oldest": False}
            assert request["anchor"] == 10 and request["include_anchor"] is False
            return {"result": "success", "messages": [stream_message(8), stream_message(9)],
                    "found_oldest": True}

    clients = []
    def factory(_rc):
        clients.append(Paging([]))
        return clients[-1]

    src = PreviewSource(factory)
    first = src.preview(settings())["servers"][0]
    assert (first["fetched"], first["complete"]) == (2, False)
    more = src.preview(settings(), more=True)["servers"][0]
    assert [e["id"] for e in more["messages"]] == [11, 10, 9, 8]
    assert (more["fetched"], more["complete"]) == (4, True)
    # once the oldest message is reached another request changes nothing
    again = src.preview(settings(), more=True)["servers"][0]
    assert again["fetched"] == 4
    assert not any(r["anchor"] == 8 for c in clients for r in c.requests)


def test_a_failed_page_keeps_what_was_already_fetched():
    src = source([stream_message(1)])
    src.preview(settings())
    src.client_factory = lambda _rc: (_ for _ in ()).throw(OSError("offline"))
    result = src.preview(settings(), more=True)["servers"][0]
    assert result["fetched"] == 1 and "offline" in result["error"]
    assert [e["id"] for e in result["messages"]] == [1]


def test_paging_continues_from_the_window_not_from_an_old_mention():
    class Mixed(FakeClient):
        def get_messages(self, request):
            self.requests.append(request)
            if request.get("narrow"):
                return {"result": "success", "messages": [stream_message(2, flags=["mentioned"])]}
            if request["anchor"] == "newest":
                return {"result": "success", "messages": [stream_message(10), stream_message(11)],
                        "found_oldest": False}
            assert request["anchor"] == 10
            return {"result": "success", "messages": [stream_message(9)], "found_oldest": True}

    src = PreviewSource(lambda _rc: Mixed([]))
    src.preview(settings())
    ids = [e["id"] for e in src.preview(settings(), more=True)["servers"][0]["messages"]]
    assert ids == [11, 10, 9, 2]
