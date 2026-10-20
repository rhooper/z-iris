"""Play sounds and show banners, or describe what would happen."""

from __future__ import annotations

import queue
import subprocess
import sys
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from z_iris.media import MessageImages
from z_iris.message import Message
from z_iris.notify import DesktopNotifierBackend, Notifier, in_bundle, log_problem
from z_iris.pipeline import Notification
from z_iris.prioritylink import PriorityNotifier
from z_iris.sender import sender_for
from z_iris.plaintext import expand_emoji, plain_text
from z_iris.settings import Settings

_ZERO_WIDTH_SPACE = "​"


def sound_command(player: tuple[str, ...], sound: str, volume: int) -> list[str]:
    # The vol effect, not the -v input option, which sox ignores for some input.
    gain = f"{volume / 100:.2f}"
    return [*player, sound, "vol", gain]


def banner_title(message: Message) -> str:
    if message.kind == "channel":
        title = f"{message.sender_name} (#{message.channel_name} > {message.topic})"
    elif len(message.dm_user_ids) > 1:
        title = f"{message.sender_name} (group)"
    else:
        title = message.sender_name
    return expand_emoji(title)


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


def group_id(server: str, ident: int) -> str:
    """The id a message's banner or alert carries, so it can be cleared."""
    return f"z-iris-{server}-{ident}"


def banner_group(message: Message) -> str:
    return group_id(message.server, message.id)


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
    if notification.summary:
        return expand_emoji(notification.summary)
    return banner_title(notification.message)


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
    def clear_read(self, server: str, ids: set[int] | None) -> None: ...
    def clear_unless_unread(self, server: str, unread: set[int]) -> None: ...


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

    def show(self, title, body, url, image=None, group=None, silent=True, sender=None) -> None:
        self.spawn(
            terminal_notifier_command(self.binary, title, body, url, group or "z-iris")
        )

    def clear(self, group: str) -> None:
        self.spawn([self.binary, "-remove", group])


# Click urls for z-iris's own banners, kept so a click after a restart still opens Zulip.
BANNER_URLS = Path.home() / "Library" / "Application Support" / "z-iris" / "banner-urls.json"


def make_notifier(
    spawn: Callable[[list[str]], object] = _spawn, binary: str = "terminal-notifier"
) -> Notifier:
    """Native banners inside the z-iris app bundle, terminal-notifier otherwise.
    binary is the [output] notifier setting: the fallback's command or path."""
    fallback = TerminalNotifier(spawn, binary)
    if in_bundle():
        from z_iris.priority import UrlStore

        return DesktopNotifierBackend(fallback, urls=UrlStore(BANNER_URLS), eager=True)
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
        priority: PriorityNotifier | None = None,
        images_for: Callable[[Message], MessageImages] | None = None,
    ) -> None:
        self.images_for = images_for  # avatar and picture apart; wins over image_for
        self.settings = settings
        self.priority = priority  # sticky alerts; None outside the app bundle
        self.spawn = spawn
        self.visual = NullVisual()
        self.notifier = notifier or make_notifier(spawn, settings.config.notifier)
        self.image_for = image_for
        self._worker: _BannerWorker | None = None

    def banner(self, notification: Notification) -> None:
        """Returns at once; the image lookup and the notifier call run on a worker."""
        if notification.action.banner == "off":
            return
        if not self._submit(lambda: self._show_banner(notification)):
            print("z-iris: banner queue full; banner dropped", file=sys.stderr)

    def _submit(self, job: Callable[[], None]) -> bool:
        if self._worker is None:
            self._worker = _BannerWorker()
        return self._worker.submit(job)

    def _show_banner(self, notification: Notification) -> None:
        action = notification.action
        message = notification.message
        title_only = action.banner == "title"
        body = "New message" if title_only else plain_body(message)
        title = notification_title(notification)
        image = sender = None
        try:
            if self.images_for is not None:
                images = self.images_for(message)
                picture = None if title_only else images.picture
                image = None if title_only else (picture or images.avatar)
                if not notification.summary:  # a summary has no single sender
                    sender = sender_for(message, title, MessageImages(images.avatar, picture))
            elif self.image_for is not None and not title_only:
                image = self.image_for(message)
        except Exception as error:
            log_problem(f"image lookup failed: {error}")
        sticky = action.sticky and self.priority is not None
        (self.priority if sticky else self.notifier).show(
            title, body, notification.url, image, banner_group(message), True, sender=sender
        )

    # Clears run on the banner worker, so they stay ordered after the shows.

    def clear_read(self, server: str, ids: set[int] | None) -> None:
        """Remove sticky alerts for messages read (or deleted) elsewhere. A
        clear is sent by group even for alerts this run never showed."""
        priority = self.priority
        if priority is None:
            return
        if ids is None:
            self._submit(lambda: priority.clear_server(server, set()))
            return
        # One job per event: marking a channel read can list thousands of ids.
        groups = [group_id(server, ident) for ident in sorted(ids)]
        if not self._submit(lambda: priority.clear_groups(groups)):
            log_problem("banner queue full; sticky alerts not cleared")

    def clear_unless_unread(self, server: str, unread: set[int]) -> None:
        priority = self.priority
        if priority is not None:
            kept = set(unread)
            self._submit(lambda: priority.clear_server(server, kept))

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

    def clear_read(self, server: str, ids: set[int] | None) -> None:
        what = "all read messages" if ids is None else f"{len(ids)} read messages"
        print(f"[dry-run] {server}: clear sticky alerts for {what}", flush=True)

    def clear_unless_unread(self, server: str, unread: set[int]) -> None:
        print(f"[dry-run] {server}: clear sticky alerts except {len(unread)} unread", flush=True)

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
        sticky = "sticky " if action.sticky else ""
        banner = "no banner" if action.banner == "off" else f"{sticky}banner {action.banner}"
        flash = "" if action.flash == "none" else f", flash {action.flash}"
        print(
            f"[dry-run] {notification.message.server} ({notification.reason}): "
            f"{notification_title(notification)}\n"
            f"          {banner_body(notification.message, 80)}\n"
            f"          open {notification.url}\n"
            f"          rule {action.rule or 'default'}, {banner}, sound {sound}{flash}",
            flush=True,
        )
