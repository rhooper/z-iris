"""Hand sticky alerts to z-iris-priority.app.

z-iris runs the priority app's executable as a child and writes one JSON
request per line to its stdin, reading one JSON reply per line. Anything that
goes wrong (no app, no permission, a hang, a crash) shows an ordinary banner
instead, so a sticky message is never lost.
"""

from __future__ import annotations

import json
import plistlib
import queue
import subprocess
import threading
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from z_iris.notify import Notifier, log_problem

PRIORITY_APP = Path.home() / "Applications" / "z-iris-priority.app"


def executable(app: Path = PRIORITY_APP) -> Path:
    return app / "Contents" / "MacOS" / "z-iris-priority"


def _popen(argv: list[str]):
    return subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        bufsize=1,
    )


def profile_days_left(app: Path, now: datetime) -> float | None:
    """Days until the app's development profile expires; None without one."""
    profile = app / "Contents" / "embedded.provisionprofile"
    if not profile.is_file():
        return None
    try:
        decoded = subprocess.run(
            ["security", "cms", "-D", "-i", str(profile)],
            capture_output=True, check=True, timeout=10,
        ).stdout
        expires = plistlib.loads(decoded)["ExpirationDate"]
        return (expires - now).total_seconds() / 86400
    except Exception:
        return None


class _Child:
    """One running priority app and a reader thread for its replies."""

    def __init__(self, process) -> None:
        self.process = process
        self.replies: queue.Queue = queue.Queue()
        self.hung = False  # killed for not answering; restarting would not help
        threading.Thread(target=self._read, daemon=True, name="z-iris-priority").start()

    def _read(self) -> None:
        try:
            while line := self.process.stdout.readline():
                self.replies.put(line)
        except Exception:
            pass
        self.replies.put(None)  # end of output

    def alive(self) -> bool:
        return self.process.poll() is None

    def ask(self, request: dict, timeout: float) -> dict | None:
        """The reply, or None if the child died, hung or answered nonsense."""
        try:
            self.process.stdin.write(json.dumps(request) + "\n")
            self.process.stdin.flush()
            line = self.replies.get(timeout=timeout)
        except queue.Empty:
            self.hung = True
            self.kill()  # a late reply would answer the next request
            return None
        except (OSError, ValueError):
            return None  # the pipe is closed: it died
        if line is None:
            return None
        try:
            reply = json.loads(line)
        except ValueError:
            self.hung = True
            self.kill()
            return None
        return reply if isinstance(reply, dict) else None

    def kill(self) -> None:
        try:
            self.process.kill()
        except Exception:
            pass


class PriorityNotifier:
    """A Notifier that shows persistent alerts through z-iris-priority, plus
    clear_server. show and clear block for at most about two timeouts; call
    them from the banner worker, never the engine."""

    def __init__(
        self,
        fallback: Notifier,
        app: Path = PRIORITY_APP,
        start: Callable[[list[str]], object] = _popen,
        warn: Callable[[str], None] = log_problem,
        timeout: float = 2.0,
    ) -> None:
        self.fallback = fallback
        self.app = app
        self.start = start
        self.warn = warn
        self.timeout = timeout
        self._child: _Child | None = None
        self._lock = threading.Lock()
        self._state: str | None = None  # for warnings on changes only
        self._style_warned = False
        self._why = "no reply"  # why the last request failed, for the warning
        self._clear_failing = False  # warn about failed clears once per run of them

    def _transition(self, state: str, text: str) -> None:
        if self._state != state:
            self._state = state
            self.warn(text)

    def _running(self) -> _Child | None:
        if self._child is not None and self._child.alive():
            return self._child
        path = executable(self.app)
        if not path.is_file():
            self._why = f"no z-iris priority at {self.app}"
            return None
        try:
            child = _Child(self.start([str(path)]))
        except OSError as error:
            self._why = f"cannot start it: {error}"
            return None
        status = child.ask({"op": "status"}, self.timeout)
        if status is None:
            self._why = "no reply"
            return None
        self._child = child
        style = status.get("style")
        if status.get("allowed") and style != "alert" and not self._style_warned:
            self._style_warned = True
            self.warn(
                f"z-iris priority alerts are set to {style}; set Alerts in "
                "System Settings, Notifications, z-iris priority"
            )
        return child

    def _request(self, request: dict) -> dict | None:
        with self._lock:
            for _attempt in range(2):  # one restart if the child has died
                child = self._running()
                if child is None:
                    return None
                reply = child.ask(request, self.timeout)
                if reply is not None:
                    return reply
                self._why = "no reply"
                if child.hung:  # restarting would only hang again
                    return None
            return None

    def show(
        self,
        title: str,
        body: str,
        url: str,
        image: Path | None = None,
        group: str | None = None,
        silent: bool = True,
        sender=None,  # Task 6 sends it on
    ) -> None:
        reply = self._request({
            "op": "show", "title": title, "body": body, "url": url,
            "group": group or "z-iris", "image": str(image) if image else None,
        })
        if reply is not None and reply.get("ok"):
            if self._state not in (None, "native"):
                self._transition("native", "z-iris priority alerts working again")
            self._state = "native"
            return
        reason = reply.get("reason") if reply else self._why
        self._transition("fallback", f"z-iris priority did not show an alert ({reason}); using a banner")
        self.fallback.show(title, body, url, image, group, silent)

    def clear(self, group: str) -> None:
        self.clear_groups([group])

    def clear_groups(self, groups: list[str]) -> None:
        self._clear({"op": "clear", "groups": list(groups)})

    def clear_server(self, server: str, keep: set[int]) -> None:
        self._clear({"op": "clear_server", "server": server, "keep": sorted(keep)})

    def _clear(self, request: dict) -> None:
        if not executable(self.app).is_file():
            return  # no app, so no alerts to clear
        reply = self._request(request)
        if reply is not None and reply.get("ok"):
            self._clear_failing = False
        elif not self._clear_failing:
            self._clear_failing = True
            reason = reply.get("reason") if reply else self._why
            self.warn(f"z-iris priority could not clear alerts ({reason})")
