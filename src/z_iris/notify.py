"""Native banners through desktop-notifier (UNUserNotificationCenter).

That API only works from z-iris's own app bundle (scripts/claude/build_app.sh).
Anywhere else, or if the user has not allowed notifications, banners go to the
fallback notifier instead, so they never silently vanish.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import threading
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


class DesktopNotifierBackend:
    """Runs desktop-notifier on its own asyncio loop in a daemon thread. show and
    clear return at once and never raise."""

    def __init__(
        self,
        fallback: Notifier,
        opener: Callable[[str], None] = open_url,
        factory: Callable[[], Any] = _default_factory,
        warn: Callable[[str], None] = _warn,
    ) -> None:
        self.fallback = fallback
        self.opener = opener
        self.factory = factory
        self.warn = warn
        self._notifier: Any = None
        self._authorised: bool | None = None
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, daemon=True, name="notify")
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _submit(self, coroutine) -> None:
        asyncio.run_coroutine_threadsafe(coroutine, self._loop)

    async def _ready(self) -> bool:
        if self._authorised is None:
            try:
                self._notifier = self.factory()
                self._authorised = bool(await self._notifier.request_authorisation())
            except Exception as error:
                self.warn(f"native notifications unavailable ({error}); using terminal-notifier")
                self._authorised = False
            else:
                if not self._authorised:
                    self.warn(
                        "notifications not allowed for z-iris; using terminal-notifier. "
                        "Allow them in System Settings, Notifications, z-iris"
                    )
        return self._authorised

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
        try:
            if await self._ready():
                from desktop_notifier import DEFAULT_SOUND, Attachment, Notification

                extra = {"identifier": group} if group else {}
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
                return
        except Exception as error:
            self.warn(f"native notification failed ({error}); using terminal-notifier")
        self.fallback.show(title, body, url, image, group, silent)

    def clear(self, group: str) -> None:
        self._submit(self._clear(group))

    async def _clear(self, group: str) -> None:
        try:
            if self._authorised:
                await self._notifier.clear(group)
                return
        except Exception as error:
            self.warn(f"cannot clear notification ({error})")
        self.fallback.clear(group)
