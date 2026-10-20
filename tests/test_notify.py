import asyncio
import logging
import threading
from pathlib import Path

from z_iris.notify import DesktopNotifierBackend


class FakeCenter:
    def __init__(self, allowed=True, boom=False, refuse=False, hang=None):
        self.allowed, self.boom, self.refuse, self.hang = allowed, boom, refuse, hang
        self.sent, self.cleared, self.auth_calls = [], [], 0

    async def request_authorisation(self):
        self.auth_calls += 1
        if self.hang is not None:
            await self.hang.wait()
        return self.allowed

    async def send_notification(self, notification):
        if self.boom:
            raise RuntimeError("no centre")
        if self.refuse:
            logging.getLogger("desktop_notifier.backends.macos").warning(
                "Error when scheduling notification: domain=UNErrorDomain, code=1"
            )
            return None
        self.sent.append(notification)
        return notification.identifier

    async def clear(self, identifier):
        self.cleared.append(identifier)


class Recorder:
    def __init__(self):
        self.shown, self.cleared = [], []

    def show(self, *args):
        self.shown.append(args)

    def clear(self, group):
        self.cleared.append(group)


def make(center, **extra):
    fallback, warnings, opened = Recorder(), [], []
    extra.setdefault("entitled", lambda: True)  # this test process has no entitlements
    backend = DesktopNotifierBackend(
        fallback, opener=opened.append, factory=lambda: center, warn=warnings.append,
        **extra,
    )
    return backend, fallback, warnings, opened


def settle(backend):
    """Wait for everything submitted so far to finish on the backend loop."""
    done = threading.Event()
    backend._loop.call_soon_threadsafe(lambda: asyncio.ensure_future(_set(done)))
    assert done.wait(5)


async def _set(event):
    await asyncio.sleep(0.05)
    event.set()


def test_shows_natively_with_image_group_and_no_sound():
    center = FakeCenter()
    backend, fallback, warnings, _ = make(center)
    backend.show("T", "B", "zulip://x", Path("/a/b.png"), "g1")
    settle(backend)
    (sent,) = center.sent
    assert (sent.title, sent.message, sent.identifier) == ("T", "B", "g1")
    assert sent.attachment.path == Path("/a/b.png") and sent.sound is None
    assert not fallback.shown and not warnings


def test_click_opens_the_url():
    center = FakeCenter()
    backend, _, _, opened = make(center)
    backend.show("T", "B", "zulip://x", None, "g")
    settle(backend)
    center.sent[0].on_clicked()
    assert opened == ["zulip://x"]


def test_authorisation_is_requested_once():
    center = FakeCenter()
    backend, *_ = make(center)
    backend.show("a", "b", "u")
    backend.show("c", "d", "u")
    settle(backend)
    assert center.auth_calls == 1 and len(center.sent) == 2


def test_denied_authorisation_falls_back_with_one_warning():
    backend, fallback, warnings, _ = make(FakeCenter(allowed=False))
    backend.show("a", "b", "u1", None, "g")
    backend.show("c", "d", "u2", None, "h")
    settle(backend)
    assert [s[2] for s in fallback.shown] == ["u1", "u2"]
    assert len(warnings) == 1 and "not allowed" in warnings[0]


def test_a_failing_send_falls_back():
    backend, fallback, warnings, _ = make(FakeCenter(boom=True))
    backend.show("a", "b", "u")
    settle(backend)
    assert len(fallback.shown) == 1 and warnings


def test_factory_failure_falls_back_and_never_raises():
    fallback, warnings = Recorder(), []

    def broken():
        raise OSError("no bundle")

    backend = DesktopNotifierBackend(fallback, factory=broken, warn=warnings.append)
    backend.show("a", "b", "u")
    settle(backend)
    assert len(fallback.shown) == 1 and len(warnings) == 1


def test_clear_uses_the_group_as_identifier():
    center = FakeCenter()
    backend, fallback, *_ = make(center)
    backend.show("a", "b", "u", None, "g")
    backend.clear("g")
    settle(backend)
    assert center.cleared == ["g"] and not fallback.cleared


def test_one_desktop_notifier_is_created_for_concurrent_shows():
    created = []
    center = FakeCenter()

    def factory():
        created.append(1)
        return center

    fallback = Recorder()
    backend = DesktopNotifierBackend(fallback, factory=factory, warn=lambda t: None)
    for n in range(5):
        backend.show("a", str(n), "u")
    settle(backend)
    assert len(created) == 1 and len(center.sent) == 5


def test_refused_send_falls_back_with_one_warning_per_transition():
    center = FakeCenter(refuse=True)
    backend, fallback, warnings, _ = make(center)
    backend.show("a", "b", "u1")
    backend.show("c", "d", "u2")
    settle(backend)
    assert [s[2] for s in fallback.shown] == ["u1", "u2"]
    assert len(warnings) == 1


def test_pending_authorisation_times_out_to_the_fallback():
    gate = asyncio.Event()
    center = FakeCenter(hang=gate)
    backend, fallback, warnings, _ = make(center, auth_timeout=0.01)
    backend.show("a", "b", "u1")
    backend.show("c", "d", "u2")
    settle(backend)
    assert [s[2] for s in fallback.shown] == ["u1", "u2"]
    assert not center.sent
    assert len(warnings) == 1 and "waiting" in warnings[0]


def test_a_later_allow_is_picked_up_without_restart():
    now = [0.0]
    center = FakeCenter(allowed=False)
    backend, fallback, warnings, _ = make(center, clock=lambda: now[0], recheck_seconds=300)
    backend.show("a", "b", "u1")
    settle(backend)
    center.allowed = True
    backend.show("c", "d", "u2")  # inside the window: still the fallback
    settle(backend)
    assert not center.sent
    now[0] = 301
    backend.show("e", "f", "u3")
    settle(backend)
    assert [s[2] for s in fallback.shown] == ["u1", "u2"]
    assert [n.message for n in center.sent] == ["f"]


def test_permission_switched_off_later_is_noticed_after_a_refused_send():
    now = [0.0]
    center = FakeCenter()
    backend, fallback, warnings, _ = make(center, clock=lambda: now[0])
    backend.show("a", "b", "u1")
    settle(backend)
    center.allowed, center.refuse = False, True
    backend.show("c", "d", "u2")  # refused: falls back, authorisation re-checked
    backend.show("e", "f", "u3")
    settle(backend)
    assert [s[2] for s in fallback.shown] == ["u2", "u3"]
    assert center.auth_calls == 2


from z_iris.comms import CommsError
from z_iris.priority import UrlStore
from z_iris.sender import Sender

ADA = Sender("zulip:w:9", "Ada", Path("/c/av.png"), None, "w:dm:9")


class FakeComms:
    def __init__(self, fail=None):
        self.fail, self.sent = fail, []

    async def __call__(self, **kw):
        if self.fail:
            raise CommsError(self.fail)
        self.sent.append(kw)


def test_a_sender_goes_through_comms_not_desktop_notifier():
    center, comms = FakeCenter(), FakeComms()
    backend, fallback, warnings, _ = make(center, comms=comms)
    backend.show("Ada", "hi", "zulip://x", Path("/c/av.png"), "z-iris-w-1", sender=ADA)
    settle(backend)
    assert center.sent == [] and not fallback.shown and not warnings
    (sent,) = comms.sent
    assert (sent["identifier"], sent["title"], sent["body"], sent["sender"]) == (
        "z-iris-w-1", "Ada", "hi", ADA)
    assert sent["group_image"] is None


def test_comms_failure_sends_today_s_banner_and_warns_once():
    center = FakeCenter()
    backend, fallback, warnings, _ = make(center, comms=FakeComms(fail="no entitlement"))
    backend.show("Ada", "hi", "u", Path("/c/av.png"), "g1", sender=ADA)
    backend.show("Ada", "again", "u", Path("/c/av.png"), "g2", sender=ADA)
    settle(backend)
    assert [n.message for n in center.sent] == ["hi", "again"]
    assert center.sent[0].attachment.path == Path("/c/av.png")
    assert len([w for w in warnings if "no entitlement" in w]) == 1


def test_without_a_sender_nothing_changes():
    center, comms = FakeCenter(), FakeComms()
    backend, *_ = make(center, comms=comms)
    backend.show("T", "B", "u", None, "g")
    settle(backend)
    assert comms.sent == [] and len(center.sent) == 1


def test_a_click_after_a_restart_opens_the_stored_url(tmp_path):
    store = tmp_path / "urls.json"
    backend, *_ = make(FakeCenter(), comms=FakeComms(), urls=UrlStore(store))
    backend.show("Ada", "hi", "zulip://dm/9", None, "z-iris-w-1", sender=ADA)
    settle(backend)
    center = FakeCenter()
    again, _, _, opened = make(center, urls=UrlStore(store))
    again.show("x", "y", "zulip://other", None, "z-iris-w-2")  # creates the notifier
    settle(again)
    center.on_clicked("z-iris-w-1")  # the app-wide click handler
    assert opened == ["zulip://dm/9"]
    center.on_clicked("z-iris-w-1")
    assert opened == ["zulip://dm/9"]  # once


def test_a_group_sender_gets_a_group_picture(tmp_path):
    comms = FakeComms()
    backend, *_ = make(FakeCenter(), comms=comms, picture_dir=tmp_path)
    group = Sender("zulip:w:9", "Ada", None, None, "w:dm:3,9", "group", (("zulip:w:3", "Bob"),))
    backend.show("Ada (group)", "hi", "u", None, "g", sender=group)
    settle(backend)
    image = comms.sent[0]["group_image"]
    assert image is not None and image.parent == tmp_path and image.is_file()


def test_an_eager_backend_handles_clicks_before_any_banner(tmp_path):
    store = UrlStore(tmp_path / "urls.json")
    store.put("z-iris-w-1", "zulip://dm/9")
    center = FakeCenter()
    backend, _, _, opened = make(center, urls=store, eager=True)
    settle(backend)
    center.on_clicked("z-iris-w-1")
    assert opened == ["zulip://dm/9"] and center.auth_calls == 0


def test_without_the_entitlement_comms_is_skipped_with_one_warning():
    center, comms = FakeCenter(), FakeComms()
    backend, _, warnings, _ = make(center, comms=comms, entitled=lambda: False)
    backend.show("Ada", "hi", "u", Path("/c/av.png"), "g1", sender=ADA)
    backend.show("Ada", "again", "u", Path("/c/av.png"), "g2", sender=ADA)
    settle(backend)
    assert comms.sent == [] and len(center.sent) == 2
    assert center.sent[0].attachment.path == Path("/c/av.png")
    assert len([w for w in warnings if "entitlement" in w]) == 1
