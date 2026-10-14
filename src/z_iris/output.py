"""Play sounds and show banners, or describe what would happen."""

from __future__ import annotations

import queue
import subprocess
import sys
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from z_iris.message import Message
from z_iris.notify import DesktopNotifierBackend, Notifier, in_bundle, log_problem
from z_iris.pipeline import Notification
from z_iris.plaintext import plain_text
from z_iris.settings import Settings

_ZERO_WIDTH_SPACE = "​"


def sound_command(player: tuple[str, ...], sound: str, volume: int) -> list[str]:
    # The vol effect, not the -v input option, which sox ignores for some input.
    gain = f"{volume / 100:.2f}"
    return [*player, sound, "vol", gain]


def banner_title(message: Message) -> str:
    if message.kind == "channel":
        return f"{message.sender_name} (#{message.channel_name} > {message.topic})"
    if len(message.dm_user_ids) > 1:
        return f"{message.sender_name} (group)"
    return message.sender_name


# terminal-notifier reads its values through NSUserDefaults. A leading "-" is
# taken for another option, and a leading ( { < [ " or ' is parsed as a
# property list, which drops or mangles the banner text.
_RISKY_FIRST_CHARACTERS = ("-", "(", "{", "<", "[", '"', "'")


def _safe_argument(text: str) -> str:
    if text.startswith(_RISKY_FIRST_CHARACTERS):
        return _ZERO_WIDTH_SPACE + text
    return text


def plain_body(message: Message, limit: int = 200) -> str:
    text = plain_text(message.content)
    if not text:
        return "(no text)"
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return text


def banner_body(message: Message, limit: int = 200) -> str:
    text = plain_body(message, limit)
    return text if not message.content.strip() else _safe_argument(text)


def banner_group(message: Message) -> str:
    return f"z-iris-{message.server}-{message.id}"


def terminal_notifier_command(
    notifier: str, title: str, body: str, url: str, group: str
) -> list[str]:
    return [
        notifier,
        "-title",
        _safe_argument(title),
        "-message",
        _safe_argument(body),
        "-open",
        url,
        "-group",
        group,
    ]


def notification_title(notification: Notification) -> str:
    """A batch summary's heading, else the sender and place."""
    return notification.summary or banner_title(notification.message)


def banner_command(notifier: str, notification: Notification) -> list[str]:
    message = notification.message
    body = (
        "New message"
        if notification.action.banner == "title"
        else plain_body(message)
    )
    return terminal_notifier_command(
        notifier, notification_title(notification), body, notification.url,
        banner_group(message),
    )


class Output(Protocol):
    """Where notifications go. deliver does everything; the engine (phase 3)
    calls the steps separately to silence, repeat or batch."""

    def deliver(self, notification: Notification) -> None: ...
    def banner(self, notification: Notification) -> None: ...
    def sound(self, notification: Notification, volume: int | None = None) -> None: ...
    def flash(self, notification: Notification) -> None: ...


class NullVisual:
    """Stands in for the screen flasher until visual.py provides one."""

    def flash(self, action) -> None:
        return None


def _spawn(command: list[str]) -> threading.Thread | None:
    """Run a command without waiting, and report a failure on stderr."""
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        log_problem(f"cannot run {command[0]}: {error}")
        return None

    def watch() -> None:
        _, error_text = process.communicate()
        if process.returncode:
            log_problem(
                f"{command[0]} exit {process.returncode}: {(error_text or '').strip()}"
            )

    thread = threading.Thread(target=watch, daemon=True)
    thread.start()
    return thread


def _audible(notification: Notification) -> bool:
    action = notification.action
    return action.sound != "none" and action.volume > 0


class TerminalNotifier:
    """The fallback backend: the terminal-notifier binary."""

    def __init__(
        self, spawn: Callable[[list[str]], object] = _spawn, binary: str = "terminal-notifier"
    ) -> None:
        self.spawn = spawn
        self.binary = binary

    def show(self, title, body, url, image=None, group=None, silent=True) -> None:
        self.spawn(
            terminal_notifier_command(self.binary, title, body, url, group or "z-iris")
        )

    def clear(self, group: str) -> None:
        self.spawn([self.binary, "-remove", group])


def make_notifier(
    spawn: Callable[[list[str]], object] = _spawn, binary: str = "terminal-notifier"
) -> Notifier:
    """Native banners inside the z-iris app bundle, terminal-notifier otherwise.
    binary is the [output] notifier setting: the fallback's command or path."""
    fallback = TerminalNotifier(spawn, binary)
    if in_bundle():
        return DesktopNotifierBackend(fallback)
    return fallback


class _BannerWorker:
    """One daemon thread that runs banner jobs in order, so a slow image fetch
    never blocks the caller. A bounded queue; a daemon thread, so a stuck fetch
    cannot hold the process open at exit."""

    def __init__(self, limit: int = 100) -> None:
        self._jobs: queue.Queue = queue.Queue(maxsize=limit)
        self._thread = threading.Thread(target=self._run, daemon=True, name="z-iris-banner")
        self._thread.start()

    def _run(self) -> None:
        while True:
            job = self._jobs.get()
            try:
                if job is None:
                    return
                job()
            except Exception as error:
                print(f"z-iris: banner failed: {error}", file=sys.stderr)
            finally:
                self._jobs.task_done()

    def submit(self, job: Callable[[], None]) -> bool:
        try:
            self._jobs.put_nowait(job)
            return True
        except queue.Full:
            return False

    def drain(self, timeout: float | None = None) -> None:
        done = threading.Event()
        try:
            self._jobs.put(done.set, timeout=timeout)
        except queue.Full:
            return
        done.wait(timeout)

    def close(self, timeout: float = 2.0) -> None:
        try:
            self._jobs.put(None, timeout=timeout)
        except queue.Full:
            return
        self._thread.join(timeout)


class RealOutput:
    def __init__(
        self,
        settings: Settings,
        spawn: Callable[[list[str]], object] = _spawn,
        notifier: Notifier | None = None,
        image_for: Callable[[Message], Path | None] | None = None,
    ) -> None:
        self.settings = settings
        self.spawn = spawn
        self.visual = NullVisual()
        self.notifier = notifier or make_notifier(spawn, settings.config.notifier)
        self.image_for = image_for
        self._worker: _BannerWorker | None = None

    def banner(self, notification: Notification) -> None:
        """Returns at once; the image lookup and the notifier call run on a worker."""
        if notification.action.banner == "off":
            return
        if self._worker is None:
            self._worker = _BannerWorker()
        if not self._worker.submit(lambda: self._show_banner(notification)):
            print("z-iris: banner queue full; banner dropped", file=sys.stderr)

    def _show_banner(self, notification: Notification) -> None:
        action = notification.action
        message = notification.message
        body = "New message" if action.banner == "title" else plain_body(message)
        image = None
        if self.image_for is not None and action.banner != "title":
            try:
                image = self.image_for(message)
            except Exception as error:
                log_problem(f"image lookup failed: {error}")
        self.notifier.show(
            notification_title(notification), body, notification.url, image,
            banner_group(message), True
        )

    def drain(self, timeout: float | None = 5.0) -> None:
        """Wait until every banner submitted so far has been shown."""
        if self._worker is not None:
            self._worker.drain(timeout)

    def close(self, timeout: float = 2.0) -> None:
        """Stop the banner worker, waiting at most timeout for it."""
        if self._worker is not None:
            self._worker.close(timeout)

    def sound(self, notification: Notification, volume: int | None = None) -> None:
        action = notification.action
        level = action.volume if volume is None else volume
        if action.sound != "none" and level > 0:
            self.spawn(sound_command(self.settings.config.player, action.sound, level))

    def flash(self, notification: Notification) -> None:
        if notification.action.flash != "none":
            self.visual.flash(notification.action)

    def deliver(self, notification: Notification) -> None:
        # banner last: a slow avatar fetch must not delay the sound or flash
        self.sound(notification)
        self.flash(notification)
        self.banner(notification)


class DryRunOutput:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def banner(self, notification: Notification) -> None:
        self.deliver(notification)

    def sound(self, notification: Notification, volume: int | None = None) -> None:
        return None

    def flash(self, notification: Notification) -> None:
        return None

    def deliver(self, notification: Notification) -> None:
        action = notification.action
        sound = (
            " ".join(
                sound_command(self.settings.config.player, action.sound, action.volume)
            )
            if _audible(notification)
            else "silent"
        )
        banner = "no banner" if action.banner == "off" else f"banner {action.banner}"
        flash = "" if action.flash == "none" else f", flash {action.flash}"
        print(
            f"[dry-run] {notification.message.server} ({notification.reason}): "
            f"{notification_title(notification)}\n"
            f"          {banner_body(notification.message, 80)}\n"
            f"          open {notification.url}\n"
            f"          rule {action.rule or 'default'}, {banner}, sound {sound}{flash}",
            flush=True,
        )
