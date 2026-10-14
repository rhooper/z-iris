import asyncio
import threading
from pathlib import Path

from z_iris.notify import DesktopNotifierBackend


class FakeCenter:
    def __init__(self, allowed=True, boom=False):
        self.allowed, self.boom = allowed, boom
        self.sent, self.cleared, self.auth_calls = [], [], 0

    async def request_authorisation(self):
        self.auth_calls += 1
        return self.allowed

    async def send_notification(self, notification):
        if self.boom:
            raise RuntimeError("no centre")
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


def make(center):
    fallback, warnings, opened = Recorder(), [], []
    backend = DesktopNotifierBackend(
        fallback, opener=opened.append, factory=lambda: center, warn=warnings.append
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
