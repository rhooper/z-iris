"""Play sounds and show banners, or describe what would happen."""

from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path
from collections.abc import Callable
from typing import Protocol

from z_iris.message import Message
from z_iris.config import Config
from z_iris.loudness import Loudness
from z_iris.pipeline import Notification
from z_iris.settings import Settings

_ZERO_WIDTH_SPACE = "​"


def sound_command(
    player: tuple[str, ...], sound: str, volume: int, gain: float = 1.0
) -> list[str]:
    # The vol effect, not the -v input option, which sox ignores for some input.
    # gain is the file's loudness correction, see loudness.py.
    return [*player, sound, "vol", f"{volume / 100 * gain:.3f}"]


def playback_gain(config: Config, sound: str, loudness: Loudness) -> float:
    if not config.normalize or sound == "none":
        return 1.0
    return loudness.gain(Path(sound))


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


def banner_body(message: Message, limit: int = 200) -> str:
    text = " ".join(message.content.split())
    if not text:
        return "(no text)"
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return _safe_argument(text)


def banner_command(notifier: str, notification: Notification) -> list[str]:
    message = notification.message
    body = (
        "New message"
        if notification.action.banner == "title"
        else banner_body(message)
    )
    return [
        notifier,
        "-title",
        _safe_argument(banner_title(message)),
        "-message",
        body,
        "-open",
        notification.url,
        "-group",
        f"z-iris-{message.server}-{message.id}",
    ]


class Output(Protocol):
    def deliver(self, notification: Notification) -> None: ...


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
        print(f"z-iris: cannot run {command[0]}: {error}", file=sys.stderr)
        return None

    def watch() -> None:
        _, error_text = process.communicate()
        if process.returncode:
            print(
                f"z-iris: {command[0]} exit {process.returncode}: "
                f"{(error_text or '').strip()}",
                file=sys.stderr,
            )

    thread = threading.Thread(target=watch, daemon=True)
    thread.start()
    return thread


def _audible(notification: Notification) -> bool:
    action = notification.action
    return action.sound != "none" and action.volume > 0


class RealOutput:
    def __init__(
        self,
        settings: Settings,
        spawn: Callable[[list[str]], object] = _spawn,
        loudness: Loudness | None = None,
    ) -> None:
        self.settings = settings
        self.spawn = spawn
        self.loudness = loudness or Loudness()

    def deliver(self, notification: Notification) -> None:
        config = self.settings.config
        action = notification.action
        if action.banner != "off":
            self.spawn(banner_command(config.notifier, notification))
        if _audible(notification):
            gain = playback_gain(config, action.sound, self.loudness)
            self.spawn(sound_command(config.player, action.sound, action.volume, gain))


class DryRunOutput:
    def __init__(self, settings: Settings, loudness: Loudness | None = None) -> None:
        self.settings = settings
        self.loudness = loudness or Loudness()

    def deliver(self, notification: Notification) -> None:
        action = notification.action
        config = self.settings.config
        sound = "silent"
        if _audible(notification):
            gain = playback_gain(config, action.sound, self.loudness)
            sound = " ".join(
                sound_command(config.player, action.sound, action.volume, gain)
            )
        banner = "no banner" if action.banner == "off" else f"banner {action.banner}"
        print(
            f"[dry-run] {notification.message.server} ({notification.reason}): "
            f"{banner_title(notification.message)}\n"
            f"          {banner_body(notification.message, 80)}\n"
            f"          open {notification.url}\n"
            f"          rule {action.rule or 'default'}, {banner}, sound {sound}",
            flush=True,
        )
