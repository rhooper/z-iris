"""z-iris priority: the second app that shows sticky alerts.

macOS sets banner or alert style once per app, so persistent notifications
come from this app (ca.toybox.z-iris.priority, style Alerts) while z-iris
keeps its banners. z-iris runs it as a child and sends one JSON request per
line; each gets one JSON reply. See docs/superpowers/specs/
2026-10-19-sticky-alerts-design.md.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from collections.abc import Callable, Iterable
from pathlib import Path

from z_iris.comms import CommsError, group_picture, send_communication
from z_iris.notify import GROUP_PICTURES, open_url
from z_iris.sender import Sender

DEFAULT_URLS = Path.home() / "Library" / "Application Support" / "z-iris" / "priority-urls.json"


class UrlStore:
    """Each alert's click url by group id, on disk, so a click that relaunches
    this app after z-iris quit still opens the right conversation."""

    def __init__(self, path: Path = DEFAULT_URLS) -> None:
        self.path = path

    def _read(self) -> dict[str, str]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _write(self, data: dict[str, str]) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd, temp = tempfile.mkstemp(dir=self.path.parent, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle)
            Path(temp).replace(self.path)
        except OSError:
            pass

    def put(self, group: str, url: str) -> None:
        data = self._read()
        data[group] = url
        self._write(data)

    def pop(self, group: str) -> str | None:
        data = self._read()
        url = data.pop(group, None)
        if url is not None:
            self._write(data)
        return url if isinstance(url, str) else None

    def drop(self, groups: Iterable[str]) -> None:
        data = self._read()
        if any(data.pop(group, None) is not None for group in list(groups)):
            self._write(data)


def _bad(reason: str) -> dict:
    return {"ok": False, "reason": reason}


class PriorityService:
    """Answers z-iris's requests. Never raises: a bad request gets ok false."""

    def __init__(
        self,
        notifier,
        urls: UrlStore,
        opener: Callable[[str], None] = open_url,
        comms: Callable = send_communication,
        picture_dir: Path = GROUP_PICTURES,
    ) -> None:
        self.notifier = notifier
        self.urls = urls
        self.opener = opener
        self.comms = comms
        self.picture_dir = picture_dir
        self._prompt = None  # the background permission request, once started

    async def handle(self, request: object) -> dict:
        try:
            if not isinstance(request, dict):
                return _bad("request must be an object")
            op = request.get("op")
            if op == "status":
                # Never the prompt: it waits for the user, and z-iris would
                # take the silence for a hang.
                return {
                    "ok": True,
                    "allowed": await self.notifier.authorisation_status() == "allowed",
                    "style": await self.notifier.alert_style(),
                }
            if op == "show":
                return await self._show(request)
            if op == "clear":
                groups = request.get("groups")
                if not isinstance(groups, list) or not all(isinstance(g, str) for g in groups):
                    return _bad("groups must be a list of strings")
                await self._clear(groups)
                return {"ok": True}
            if op == "clear_server":
                return await self._clear_server(request)
            return _bad(f"unknown op {op!r}")
        except Exception as error:
            return _bad(str(error) or type(error).__name__)

    async def _show(self, request: dict) -> dict:
        from desktop_notifier import Attachment, Notification, Urgency

        fields = {key: request.get(key) for key in ("title", "body", "url", "group")}
        if not all(isinstance(value, str) for value in fields.values()):
            return _bad("show needs title, body, url and group strings")
        status = await self.notifier.authorisation_status()
        if status == "undetermined":
            # Ask in the background; z-iris shows a banner until it is answered.
            if self._prompt is None or self._prompt.done():
                import asyncio

                self._prompt = asyncio.ensure_future(self.notifier.request_authorisation())
            return _bad("waiting for permission")
        if status != "allowed":
            return _bad("not allowed")
        image = request.get("image")
        attachment = (
            Attachment(path=Path(image))
            if isinstance(image, str) and Path(image).is_file()
            else None
        )
        self.urls.put(fields["group"], fields["url"])
        plain = None
        sender = Sender.from_json(request.get("sender"))
        if sender is not None:
            try:
                group_image = (group_picture(sender, self.picture_dir)
                               if sender.group_name is not None else None)
                await self.comms(identifier=fields["group"], title=fields["title"],
                                 body=fields["body"], sender=sender,
                                 urgency="time-sensitive", group_image=group_image)
                return {"ok": True}
            except CommsError as error:
                plain = str(error)  # z-iris warns once; the alert still goes out
            attachment = attachment or (
                Attachment(path=sender.avatar) if sender.avatar and sender.avatar.is_file() else None)
        # Time-sensitive needs an entitlement; without it macOS delivers the
        # alert as an ordinary one, so asking is always safe.
        await self.notifier.send_notification(
            Notification(
                fields["title"],
                fields["body"],
                urgency=Urgency.Critical,
                attachment=attachment,
                sound=None,  # z-iris plays the sound
                identifier=fields["group"],
            )
        )
        return {"ok": True, "plain": plain} if plain else {"ok": True}

    async def _clear(self, groups: list[str]) -> None:
        # Only what is on screen: a bulk read can name thousands of groups.
        delivered = set(await self.notifier.get_current_notifications())
        for group in groups:
            if group in delivered:
                await self.notifier.clear(group)
        self.urls.drop(groups)

    async def _clear_server(self, request: dict) -> dict:
        server, keep = request.get("server"), request.get("keep")
        if not isinstance(server, str) or not isinstance(keep, list) or not all(
            isinstance(i, int) and not isinstance(i, bool) for i in keep
        ):
            return _bad("clear_server needs a server string and a list of ids")
        pattern = re.compile(rf"z-iris-{re.escape(server)}-(\d+)")
        kept = set(keep)
        doomed = []
        for identifier in await self.notifier.get_current_notifications():
            match = pattern.fullmatch(identifier)
            if match and int(match.group(1)) not in kept:
                doomed.append(identifier)
        await self._clear(doomed)
        return {"ok": True}

    def clicked(self, group: str) -> None:
        url = self.urls.pop(group)
        if url:
            self.opener(url)


def serve(
    lines: Iterable[str],
    service: PriorityService,
    write: Callable[[str], None],
    run: Callable,
) -> None:
    """One reply line per request line, in order. Blank lines are skipped."""
    for line in lines:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except ValueError:
            reply = _bad("bad json")
        else:
            reply = run(service.handle(request))
        write(json.dumps(reply) + "\n")


# The app. Everything below needs macOS and the z-iris-priority.app bundle.

_STYLES = {0: "none", 1: "banner", 2: "alert"}
# UNAuthorizationStatus: not determined, denied, authorized, provisional, ephemeral
_AUTH = {0: "undetermined", 1: "denied", 2: "allowed", 3: "allowed", 4: "allowed"}
IDLE_EXIT = 30.0  # seconds after z-iris goes away (or a click relaunch) before quitting


class MacNotifier:
    """desktop-notifier plus the alert style, which it does not expose."""

    def __init__(self, on_clicked: Callable[[str], None]) -> None:
        from desktop_notifier import DesktopNotifier

        self._notifier = DesktopNotifier(app_name="z-iris priority")
        # Per-notification callbacks are lost when a click relaunches the app;
        # the app-wide one always gets the identifier.
        self._notifier.on_clicked = on_clicked

    def __getattr__(self, name):
        return getattr(self._notifier, name)

    async def _settings(self) -> tuple[int, int]:
        """(authorizationStatus, alertStyle), without ever prompting."""
        import asyncio
        from concurrent.futures import Future

        from rubicon.objc import Block, ObjCClass, ObjCInstance, objc_id
        from rubicon.objc.runtime import load_library

        load_library("UserNotifications")
        center = ObjCClass("UNUserNotificationCenter").currentNotificationCenter()
        future: Future = Future()

        def handler(settings: objc_id) -> None:
            found = ObjCInstance(settings)
            future.set_result((int(found.authorizationStatus), int(found.alertStyle)))

        center.getNotificationSettingsWithCompletionHandler(Block(handler, None, objc_id))
        return await asyncio.wrap_future(future)

    async def authorisation_status(self) -> str:
        status, _style = await self._settings()
        return _AUTH.get(status, "denied")

    async def alert_style(self) -> str:
        _status, style = await self._settings()
        return _STYLES.get(style, "none")


def main(argv: list[str] | None = None) -> int:
    import asyncio
    import sys
    import threading
    import time

    from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
    from PyObjCTools import AppHelper

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    loop = asyncio.new_event_loop()
    threading.Thread(target=loop.run_forever, daemon=True, name="notify").start()
    last_activity = [time.monotonic()]

    def clicked(group: str) -> None:
        last_activity[0] = time.monotonic()
        service.clicked(group)

    service = PriorityService(MacNotifier(clicked), UrlStore())

    def run(coroutine):
        return asyncio.run_coroutine_threadsafe(coroutine, loop).result()

    def write(text: str) -> None:
        sys.stdout.write(text)
        sys.stdout.flush()

    def read() -> None:
        serve(sys.stdin, service, write, run)
        # z-iris has gone, or macOS launched this app only to deliver a click.
        last_activity[0] = time.monotonic()
        while time.monotonic() - last_activity[0] < IDLE_EXIT:
            time.sleep(1)
        AppHelper.callAfter(app.terminate_, None)

    threading.Thread(target=read, daemon=True, name="requests").start()
    AppHelper.runEventLoop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
