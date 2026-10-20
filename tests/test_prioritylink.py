import json
import queue
import time
from datetime import datetime
from pathlib import Path

from z_iris.prioritylink import PriorityNotifier, executable, profile_days_left

OK_STATUS = {"ok": True, "allowed": True, "style": "alert"}


class FakeChild:
    """A z-iris-priority stand-in. script maps an op to a reply dict, "hang"
    (never answers) or "die" (exits without answering)."""

    def __init__(self, script=None):
        self.script = {"status": OK_STATUS, "show": {"ok": True}, "clear": {"ok": True},
                       "clear_server": {"ok": True}, **(script or {})}
        self.requests = []
        self.lines = []
        self.returncode = None
        self._out = queue.Queue()
        child = self

        class In:
            def write(self, text):
                if child.returncode is not None:
                    raise BrokenPipeError
                child.lines.append(text)
                request = json.loads(text)
                child.requests.append(request)
                reply = child.script[request["op"]]
                if reply == "die":
                    child.returncode = 1
                    child._out.put("")
                elif reply != "hang":
                    child._out.put(json.dumps(reply) + "\n")

            def flush(self):
                pass

            def close(self):
                pass

        class Out:
            def readline(self):
                return child._out.get()

        self.stdin, self.stdout = In(), Out()

    def poll(self):
        return self.returncode

    def kill(self):
        self.returncode = -9
        self._out.put("")

    def wait(self, timeout=None):
        return self.returncode


class FakeFallback:
    def __init__(self):
        self.shown = []

    def show(self, title, body, url, image=None, group=None, silent=True, sender=None):
        self.shown.append((title, body, url, image, group))

    def clear(self, group):
        pass


def make_app(tmp_path):
    app = tmp_path / "z-iris-priority.app"
    exe = app / "Contents" / "MacOS" / "z-iris-priority"
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    return app


def notifier(tmp_path, children, timeout=1.0, app=None):
    fallback, warnings, started = FakeFallback(), [], []

    def start(argv):
        started.append(argv)
        return children.pop(0)

    link = PriorityNotifier(
        fallback, app=app or make_app(tmp_path), start=start, warn=warnings.append,
        timeout=timeout,
    )
    return link, fallback, warnings, started


BODY = '-x "q"\nline2 🎉'


def test_executable_is_inside_the_bundle(tmp_path):
    assert executable(tmp_path / "z-iris-priority.app") == (
        tmp_path / "z-iris-priority.app" / "Contents" / "MacOS" / "z-iris-priority"
    )


def test_show_sends_one_json_line_and_text_arrives_intact(tmp_path):
    child = FakeChild()
    link, fallback, _, started = notifier(tmp_path, [child])
    link.show("Ada", BODY, "zulip://h/#narrow/dm/9", Path("/a.png"), "z-iris-work-7")
    show_lines = [line for line in child.lines if '"show"' in line]
    assert len(show_lines) == 1 and show_lines[0].count("\n") == 1
    assert json.loads(show_lines[0]) == {
        "op": "show", "title": "Ada", "body": BODY, "url": "zulip://h/#narrow/dm/9",
        "group": "z-iris-work-7", "image": "/a.png",
    }
    assert fallback.shown == [] and len(started) == 1
    link.show("Bob", "x", "u", None, "z-iris-work-8")
    assert len(started) == 1  # the same child serves later requests


def test_refusal_falls_back_to_a_banner(tmp_path):
    child = FakeChild({"show": {"ok": False, "reason": "not allowed"}})
    link, fallback, warnings, _ = notifier(tmp_path, [child])
    link.show("Ada", BODY, "u", None, "z-iris-work-7")
    assert fallback.shown == [("Ada", BODY, "u", None, "z-iris-work-7")]
    assert any("not allowed" in w for w in warnings)


def test_a_hung_child_times_out_into_the_fallback(tmp_path):
    child = FakeChild({"show": "hang"})
    link, fallback, _, _ = notifier(tmp_path, [child], timeout=0.05)
    began = time.monotonic()
    link.show("Ada", "x", "u", None, "z-iris-work-7")
    assert time.monotonic() - began < 1.0
    assert fallback.shown and child.returncode == -9  # killed, so replies cannot drift


def test_a_dead_child_is_restarted_once(tmp_path):
    first, second = FakeChild({"show": "die"}), FakeChild()
    link, fallback, _, started = notifier(tmp_path, [first, second])
    link.show("Ada", "x", "u", None, "z-iris-work-7")
    assert len(started) == 2 and fallback.shown == []
    assert [r["op"] for r in second.requests] == ["status", "show"]


def test_a_child_that_dies_twice_falls_back(tmp_path):
    link, fallback, _, started = notifier(
        tmp_path, [FakeChild({"show": "die"}), FakeChild({"show": "die"})]
    )
    link.show("Ada", "x", "u", None, "z-iris-work-7")
    assert len(started) == 2 and len(fallback.shown) == 1


def test_missing_app_falls_back_without_starting(tmp_path):
    link, fallback, warnings, started = notifier(
        tmp_path, [], app=tmp_path / "nowhere" / "z-iris-priority.app"
    )
    link.show("Ada", "x", "u", None, "z-iris-work-7")
    link.show("Ada", "y", "u", None, "z-iris-work-8")
    assert started == [] and len(fallback.shown) == 2
    assert len(warnings) == 1


def test_style_warning_once(tmp_path):
    child = FakeChild({"status": {"ok": True, "allowed": True, "style": "banner"}})
    link, _, warnings, _ = notifier(tmp_path, [child])
    link.show("Ada", "x", "u", None, "z-iris-work-7")
    link.show("Ada", "y", "u", None, "z-iris-work-8")
    style = [w for w in warnings if "set to banner" in w]
    assert len(style) == 1
    assert "set Alerts in System Settings, Notifications, z-iris priority" in style[0]


def test_clear_and_clear_server_send_their_requests(tmp_path):
    child = FakeChild()
    link, fallback, _, _ = notifier(tmp_path, [child])
    link.clear("z-iris-w-1")
    link.clear_server("w", {5, 2})
    assert child.requests[1:] == [
        {"op": "clear", "groups": ["z-iris-w-1"]},
        {"op": "clear_server", "server": "w", "keep": [2, 5]},
    ]
    assert fallback.shown == []


def test_a_failed_clear_is_warned_not_shown(tmp_path):
    link, fallback, warnings, _ = notifier(tmp_path, [FakeChild({"clear": "hang"})], timeout=0.05)
    link.clear("z-iris-w-1")
    assert fallback.shown == [] and warnings


def test_profile_days_left_none_without_profile(tmp_path):
    assert profile_days_left(make_app(tmp_path), datetime(2026, 10, 20)) is None


def test_clears_without_the_app_are_quiet(tmp_path):
    link, _, warnings, started = notifier(
        tmp_path, [], app=tmp_path / "nowhere" / "z-iris-priority.app"
    )
    link.clear("z-iris-w-1")
    link.clear_server("w", set())
    assert started == [] and warnings == []


def test_clear_groups_is_one_request(tmp_path):
    child = FakeChild()
    link, _, _, _ = notifier(tmp_path, [child])
    link.clear_groups(["z-iris-w-1", "z-iris-w-2"])
    assert child.requests[1:] == [{"op": "clear", "groups": ["z-iris-w-1", "z-iris-w-2"]}]


def test_repeated_clear_failures_warn_once(tmp_path):
    children = [FakeChild({"clear": {"ok": False, "reason": "boom"}})]
    link, _, warnings, _ = notifier(tmp_path, children)
    for _ in range(3):
        link.clear("z-iris-w-1")
    assert len([w for w in warnings if "could not clear" in w]) == 1


from z_iris.sender import Sender

ADA = Sender("zulip:w:9", 'Ada "x"\n🎉', Path("/c/av.png"), None, "w:dm:9")


def test_show_sends_the_sender_intact(tmp_path):
    child = FakeChild()
    link, fallback, _, _ = notifier(tmp_path, [child])
    link.show("Ada", "x", "u", None, "z-iris-w-1", sender=ADA)
    (request,) = [r for r in child.requests if r["op"] == "show"]
    assert Sender.from_json(request["sender"]) == ADA


def test_the_fallback_banner_keeps_the_sender(tmp_path):
    class Fallback(FakeFallback):
        def show(self, title, body, url, image=None, group=None, silent=True, sender=None):
            self.shown.append((title, sender))

    child = FakeChild({"show": {"ok": False, "reason": "not allowed"}})
    fallback, warnings = Fallback(), []
    link = PriorityNotifier(fallback, app=make_app(tmp_path), start=lambda argv: child,
                            warn=warnings.append, timeout=1.0)
    link.show("Ada", "x", "u", None, "g", sender=ADA)
    assert fallback.shown == [("Ada", ADA)]


def test_plain_replies_warn_once(tmp_path):
    child = FakeChild({"show": {"ok": True, "plain": "no entitlement"}})
    link, fallback, warnings, _ = notifier(tmp_path, [child])
    link.show("Ada", "x", "u", None, "g1", sender=ADA)
    link.show("Ada", "y", "u", None, "g2", sender=ADA)
    assert fallback.shown == []
    assert len([w for w in warnings if "no entitlement" in w]) == 1
