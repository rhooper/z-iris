import threading
import time
from pathlib import Path

from z_iris.config import Config, ServerConfig
from z_iris.settings import Settings
from z_iris.stream import Controls, ServerStream, StatusBoard, host_of


def test_host_of():
    assert host_of("https://Chat.Example.com/") == "chat.example.com"
    assert host_of("http://localhost:9991") == "localhost:9991"


def test_status_board_snapshot_is_a_copy():
    board = StatusBoard()
    board.set("a", "connected")
    snap = board.snapshot()
    board.set("a", "error")
    assert snap == {"a": "connected"}


class FakeClient:
    base_url = "https://chat.example.com/"

    def __init__(self, scripts):
        self.scripts = list(scripts)
        self.registered = 0
        self.calls = 0

    def register(self, **kwargs):
        self.registered += 1
        return {
            "result": "success",
            "queue_id": f"q{self.registered}",
            "last_event_id": -1,
            # The real server returns no user_id from register.
            "subscriptions": [],
            "user_topics": [],
        }

    def get_profile(self):
        return {"result": "success", "user_id": 5}

    def get_events(self, queue_id, last_event_id):
        self.calls += 1
        if not self.scripts:
            time.sleep(0.01)
            return {"result": "success", "events": []}
        step = self.scripts.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def dm_event(event_id):
    return {
        "id": event_id,
        "type": "message",
        "flags": [],
        "message": {
            "id": 40 + event_id,
            "type": "private",
            "display_recipient": [{"id": 9}, {"id": 5}],
            "sender_id": 9,
            "sender_full_name": "Ada",
            "content": "yo",
        },
    }


class Collect:
    def __init__(self, want):
        self.want = want
        self.items = []
        self.done = threading.Event()

    def deliver(self, notification):
        self.items.append(notification)
        if len(self.items) >= self.want:
            self.done.set()

    def clear_read(self, server, ids):
        pass

    def clear_unless_unread(self, server, unread):
        pass


def make_stream(client, output, controls=None):
    config = Config(servers=(ServerConfig("w", Path("/x")),))
    stream = ServerStream(
        config.servers[0],
        Settings(config),
        output,
        controls or Controls(),
        StatusBoard(),
        client_factory=lambda path: client,
    )
    stream.backoff_start = 0.01
    return stream


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.005)


def test_events_flow_and_queue_expiry_reregisters():
    client = FakeClient(
        [
            {"result": "success", "events": [dm_event(0)]},
            {"result": "error", "code": "BAD_EVENT_QUEUE_ID", "msg": "expired"},
            {"result": "success", "events": [dm_event(1)]},
        ]
    )
    out = Collect(want=2)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert client.registered == 2
    assert [n.message.id for n in out.items] == [40, 41]


def test_a_register_failure_is_reported_and_retried():
    class FlakyRegister(FakeClient):
        def register(self, **kwargs):
            if self.registered == 0:
                self.registered += 1
                raise RuntimeError("network down")
            return super().register(**kwargs)

    client = FlakyRegister([{"result": "success", "events": [dm_event(0)]}])
    out = Collect(want=1)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert client.registered == 2


def test_a_network_drop_keeps_the_queue_so_missed_events_still_arrive():
    client = FakeClient(
        [
            {"result": "success", "events": [dm_event(0)]},
            RuntimeError("network down"),
            {"result": "success", "events": [dm_event(1)]},
        ]
    )
    out = Collect(want=2)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert client.registered == 1  # same queue, nothing re-registered
    assert [n.message.id for n in out.items] == [40, 41]
    assert stream.board.snapshot()["w"] == "connected"


def test_a_failing_output_does_not_kill_the_stream():
    class Broken:
        def __init__(self):
            self.calls = 0

        def deliver(self, notification):
            self.calls += 1
            raise OSError("no sound card")

    client = FakeClient(
        [
            {"result": "success", "events": [dm_event(0)]},
            {"result": "success", "events": [dm_event(1)]},
        ]
    )
    out = Broken()
    stream = make_stream(client, out)
    stream.start()
    wait_until(lambda: out.calls >= 2)
    stream.stop()
    assert client.registered == 1


def test_pause_suppresses_delivery_until_resumed():
    client = FakeClient([{"result": "success", "events": [dm_event(0)]}])
    controls = Controls()
    controls.paused.set()
    out = Collect(want=1)
    stream = make_stream(client, out, controls)
    stream.start()
    wait_until(lambda: client.calls >= 3)  # the paused event was consumed
    assert out.items == []
    controls.paused.clear()
    client.scripts.append({"result": "success", "events": [dm_event(1)]})
    assert out.done.wait(5)
    stream.stop()
    assert [n.message.id for n in out.items] == [41]


def test_read_events_reach_the_engine_and_register_asks_for_them():
    from z_iris.stream import EVENT_TYPES

    assert {"update_message_flags", "delete_message"} <= set(EVENT_TYPES)
    seen = []

    class Spy:
        def submit(self, notification):
            seen.append(("submit", notification.message.id))

        def handle_event(self, server, event):
            seen.append((server, event["type"]))

    read = {"id": 2, "type": "update_message_flags", "op": "add", "flag": "read",
            "messages": [40]}
    client = FakeClient([{"result": "success", "events": [dm_event(0), read]}])
    stream = make_stream(client, Collect(want=99))
    stream.engine = Spy()
    stream.start()
    wait_until(lambda: len(seen) >= 2)
    stream.stop()
    assert seen == [("submit", 40), ("w", "update_message_flags")]


def test_unread_ids_from_register():
    from z_iris.stream import unread_ids

    registered = {"unread_msgs": {
        "pms": [{"other_user_id": 9, "unread_message_ids": [1, 2]}],
        "streams": [{"stream_id": 7, "topic": "t", "unread_message_ids": [3]}],
        "huddles": [{"user_ids_string": "5,9,12", "unread_message_ids": [4]}],
        "mentions": [5, 3],
        "count": 5,
    }}
    assert unread_ids(registered) == {1, 2, 3, 4, 5}
    newer = {"unread_msgs": {"direct_message": [{"unread_message_ids": [8]}],
                             "streams": [], "huddles": [], "mentions": []}}
    assert unread_ids(newer) == {8}
    assert unread_ids({}) is None
    assert unread_ids({"unread_msgs": {**registered["unread_msgs"],
                                       "old_unreads_missing": True}}) is None


def test_each_register_reconciles_unread():
    class UnreadClient(FakeClient):
        def __init__(self, scripts, unread):
            super().__init__(scripts)
            self.unread = list(unread)

        def register(self, **kwargs):
            reply = super().register(**kwargs)
            unread = self.unread.pop(0) if self.unread else None
            if unread is not None:
                reply["unread_msgs"] = {"pms": [], "streams": [], "huddles": [],
                                        "mentions": unread}
            return reply

    class FakeEngine:
        def __init__(self):
            self.reconciled = []

        def submit(self, notification):
            pass

        def handle_event(self, server, event):
            pass

        def reconcile_unread(self, server, unread):
            self.reconciled.append((server, unread))

    client = UnreadClient(
        [{"result": "error", "code": "BAD_EVENT_QUEUE_ID", "msg": "expired"},
         {"result": "error", "code": "BAD_EVENT_QUEUE_ID", "msg": "expired"}],
        [[1, 2], None, [3]],
    )
    engine = FakeEngine()
    config = Config(servers=(ServerConfig("w", Path("/x")),))
    stream = ServerStream(config.servers[0], Settings(config), Collect(want=1), Controls(),
                          StatusBoard(), client_factory=lambda path: client, engine=engine)
    stream.backoff_start = 0.01
    stream.start()
    wait_until(lambda: client.registered >= 3)
    stream.stop()
    wait_until(lambda: len(engine.reconciled) >= 2)
    assert engine.reconciled == [("w", {1, 2}), ("w", {3})]
