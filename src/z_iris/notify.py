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

from z_iris.comms import CommsError, group_picture, send_communication
from z_iris.sender import Sender

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
        sender: Sender | None = None,
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


LOG_PATH = Path.home() / "Library" / "Logs" / "z-iris.log"
LOG_CAP = 256 * 1024


def _stderr_is_tty() -> bool:
    try:
        return sys.stderr.isatty()
    except Exception:
        return False


def log_problem(
    text: str, path: Path | None = None, tty: bool | None = None, cap: int = LOG_CAP
) -> None:
    """Report a problem on stderr; when stderr goes nowhere (Finder, login item)
    also append it to ~/Library/Logs/z-iris.log, keeping one .1 backup."""
    print(f"z-iris: {text}", file=sys.stderr)
    if (_stderr_is_tty() if tty is None else tty):
        return
    target = path or LOG_PATH
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size >= cap:
            target.replace(target.with_name(target.name + ".1"))
        with target.open("a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {text}\n")
    except OSError:
        pass


def _warn(text: str) -> None:
    log_problem(text)


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


class _MemoryUrls:
    """Click urls by group, for this run only. The app passes a priority.UrlStore
    so a click after a restart still opens Zulip."""

    def __init__(self) -> None:
        self._urls: dict[str, str] = {}

    def put(self, group: str, url: str) -> None:
        self._urls[group] = url

    def pop(self, group: str) -> str | None:
        return self._urls.pop(group, None)

    def drop(self, groups) -> None:
        for group in list(groups):
            self._urls.pop(group, None)


GROUP_PICTURES = Path.home() / "Library" / "Caches" / "z-iris" / "groups"


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
        comms: Callable[..., Any] = send_communication,
        urls: Any = None,
        picture_dir: Path = GROUP_PICTURES,
    ) -> None:
        self.comms = comms
        self.urls = urls if urls is not None else _MemoryUrls()
        self.picture_dir = picture_dir
        self._comms_warned = False
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
                # Sender notifications and clicks after a restart reach only the
                # app-wide handler, which gets just the identifier.
                self._notifier.on_clicked = self._clicked
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

    def _clicked(self, group: str) -> None:
        url = self.urls.pop(group)
        if url:
            self.opener(url)

    def show(
        self,
        title: str,
        body: str,
        url: str,
        image: Path | None = None,
        group: str | None = None,
        silent: bool = True,
        sender: Sender | None = None,
    ) -> None:
        self._submit(self._show(title, body, url, image, group, silent, sender))

    async def _show(self, title, body, url, image, group, silent, sender=None) -> None:
        async with self._sends:  # FIFO: banners go out in submission order
            await self._show_locked(title, body, url, image, group, silent, sender)

    async def _send_from(self, sender: Sender, title, body, url, group, silent) -> bool:
        """The sender's face as the icon. False (and one warning) if macOS
        cannot: the caller then sends today's notification."""
        try:
            group_image = (group_picture(sender, self.picture_dir)
                           if sender.group_name is not None else None)
            await self.comms(identifier=group or "z-iris", title=title, body=body,
                             sender=sender, urgency="active", group_image=group_image)
        except CommsError as error:
            if not self._comms_warned:
                self._comms_warned = True
                self.warn(f"sender icons unavailable ({error}); plain banners")
            return False
        return True

    async def _show_locked(self, title, body, url, image, group, silent, sender=None) -> None:
        try:
            if await self._ready():
                if group:
                    self.urls.put(group, url)
                if sender is not None and await self._send_from(
                    sender, title, body, url, group, silent
                ):
                    if self._state == "fallback":
                        self._transition("native", "native banners working again")
                    self._state = "native"
                    return
                from desktop_notifier import DEFAULT_SOUND, Attachment, Notification

                extra = {"identifier": group} if group else {}
                before = self._watch.count
                await self._notifier.send_notification(
                    Notification(
                        title,
                        body,
                        attachment=Attachment(path=image) if image else None,
                        sound=None if silent else DEFAULT_SOUND,
                        on_clicked=lambda: self._clicked(group) if group else self.opener(url),
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
                    self.urls.drop([group])
                    return
            except Exception as error:
                self.warn(f"cannot clear notification ({error})")
            self.fallback.clear(group)
