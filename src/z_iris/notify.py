"""Native banners through desktop-notifier (UNUserNotificationCenter).

That API only works from z-iris's own app bundle (scripts/claude/build_app.sh).
Anywhere else, or if the user has not allowed notifications, banners go to the
fallback notifier instead, so they never silently vanish.
"""

from __future__ import annotations

import asyncio
import logging
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, Protocol

BUNDLE_ID = "ca.toybox.z-iris"


class Notifier(Protocol):
    def show(
        self,
        title: str,
        body: str,
        url: str,
        image: Path | None = None,
        group: str | None = None,
        silent: bool = True,
    ) -> None: ...

    def clear(self, group: str) -> None: ...


def in_bundle() -> bool:
    """True when this process is the z-iris app bundle."""
    try:
        from Foundation import NSBundle

        return str(NSBundle.mainBundle().bundleIdentifier() or "") == BUNDLE_ID
    except Exception:
        return False


def open_url(url: str) -> None:
    # argv only; the url comes from message data.
    try:
        subprocess.Popen(
            ["open", url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as error:
        print(f"z-iris: cannot open {url}: {error}", file=sys.stderr)


def _warn(text: str) -> None:
    print(f"z-iris: {text}", file=sys.stderr)


def _default_factory() -> Any:
    from desktop_notifier import DesktopNotifier

    return DesktopNotifier(app_name="z-iris")


class _RefusalWatch(logging.Handler):
    """desktop-notifier never raises when macOS refuses a request; it only logs.
    This counts those log records so a send can tell it was refused."""

    def __init__(self) -> None:
        super().__init__(level=logging.WARNING)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        if record.levelno >= logging.ERROR or "Error when scheduling" in record.getMessage():
            self.count += 1


class DesktopNotifierBackend:
    """Runs desktop-notifier on its own asyncio loop in a daemon thread. show and
    clear return at once and never raise."""

    def __init__(
        self,
        fallback: Notifier,
        opener: Callable[[str], None] = open_url,
        factory: Callable[[], Any] = _default_factory,
        warn: Callable[[str], None] = _warn,
        auth_timeout: float = 10.0,
        recheck_seconds: float = 300.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.fallback = fallback
        self.opener = opener
        self.factory = factory
        self.warn = warn
        self.auth_timeout = auth_timeout
        self.recheck_seconds = recheck_seconds
        self.clock = clock
        self._notifier: Any = None
        self._authorised: bool | None = None
        self._checked: float | None = None
        self._auth_task: asyncio.Future | None = None
        self._deadline = 0.0
        self._state: str | None = None  # "native" or "fallback", for transition warnings
        self._watch = _RefusalWatch()
        logging.getLogger("desktop_notifier").addHandler(self._watch)
        self._loop = asyncio.new_event_loop()
        self._lock = asyncio.Lock()  # guards creating the one DesktopNotifier/auth task
        self._sends = asyncio.Lock()  # FIFO: one banner or clear at a time, in order
        self._thread = threading.Thread(target=self._run, daemon=True, name="notify")
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _submit(self, coroutine) -> None:
        asyncio.run_coroutine_threadsafe(coroutine, self._loop)

    def _transition(self, state: str, text: str) -> None:
        if self._state != state:
            self._state = state
            self.warn(text)

    async def _authorise(self) -> None:
        try:
            if self._notifier is None:
                self._notifier = self.factory()
            self._authorised = bool(await self._notifier.request_authorisation())
        except Exception as error:
            self._notifier = None
            self._authorised = False
            self._checked = self.clock()
            self._transition(
                "fallback",
                f"native notifications unavailable ({error}); using terminal-notifier",
            )
            return
        self._checked = self.clock()
        if not self._authorised:
            self._transition(
                "fallback",
                "notifications not allowed for z-iris; using terminal-notifier. "
                "Allow them in System Settings, Notifications, z-iris",
            )

    async def _ready(self) -> bool:
        """True when a native send may be tried. While the first permission prompt
        is unanswered, wait a bounded time and then use the fallback."""
        async with self._lock:
            stale = self._checked is None or self.clock() - self._checked >= self.recheck_seconds
            task = self._auth_task
            if task is None or (task.done() and stale):
                task = self._auth_task = asyncio.ensure_future(self._authorise())
                self._deadline = self.clock() + self.auth_timeout
        if not task.done():
            wait = max(0.0, self._deadline - self.clock())
            await asyncio.wait({task}, timeout=wait)
        if not task.done():
            self._transition(
                "fallback",
                "waiting for the notification permission prompt; using terminal-notifier meanwhile",
            )
            return False
        return bool(self._authorised)

    def show(
        self,
        title: str,
        body: str,
        url: str,
        image: Path | None = None,
        group: str | None = None,
        silent: bool = True,
    ) -> None:
        self._submit(self._show(title, body, url, image, group, silent))

    async def _show(self, title, body, url, image, group, silent) -> None:
        async with self._sends:  # FIFO: banners go out in submission order
            await self._show_locked(title, body, url, image, group, silent)

    async def _show_locked(self, title, body, url, image, group, silent) -> None:
        try:
            if await self._ready():
                from desktop_notifier import DEFAULT_SOUND, Attachment, Notification

                extra = {"identifier": group} if group else {}
                before = self._watch.count
                await self._notifier.send_notification(
                    Notification(
                        title,
                        body,
                        attachment=Attachment(path=image) if image else None,
                        sound=None if silent else DEFAULT_SOUND,
                        on_clicked=lambda: self.opener(url),
                        **extra,
                    )
                )
                refused = self._watch.count != before
                if not refused:
                    if self._state == "fallback":
                        self._transition("native", "native banners working again")
                    self._state = "native"
                    return
                self._checked = None  # look at the permission again next time
                self._transition(
                    "fallback", "macOS refused the notification; using terminal-notifier"
                )
        except Exception as error:
            self._checked = None
            self._transition(
                "fallback", f"native notification failed ({error}); using terminal-notifier"
            )
        self.fallback.show(title, body, url, image, group, silent)

    def clear(self, group: str) -> None:
        self._submit(self._clear(group))

    async def _clear(self, group: str) -> None:
        async with self._sends:
            try:
                if await self._ready():
                    await self._notifier.clear(group)
                    return
            except Exception as error:
                self.warn(f"cannot clear notification ({error})")
            self.fallback.clear(group)
