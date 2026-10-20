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

from z_iris.notify import open_url

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
        self, notifier, urls: UrlStore, opener: Callable[[str], None] = open_url
    ) -> None:
        self.notifier = notifier
        self.urls = urls
        self.opener = opener

    async def handle(self, request: object) -> dict:
        try:
            if not isinstance(request, dict):
                return _bad("request must be an object")
            op = request.get("op")
            if op == "status":
                return {
                    "ok": True,
                    "allowed": bool(await self.notifier.request_authorisation()),
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
        if not await self.notifier.request_authorisation():
            return _bad("not allowed")
        image = request.get("image")
        attachment = (
            Attachment(path=Path(image))
            if isinstance(image, str) and Path(image).is_file()
            else None
        )
        self.urls.put(fields["group"], fields["url"])
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
        return {"ok": True}

    async def _clear(self, groups: list[str]) -> None:
        for group in groups:
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
