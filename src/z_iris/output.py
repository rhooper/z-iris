"""Play sounds and show banners, or describe what would happen."""

from __future__ import annotations

import subprocess
import sys
import threading
from typing import Protocol

from z_iris.config import Config
from z_iris.message import Message
from z_iris.pipeline import Notification

_ZERO_WIDTH_SPACE = "​"


def sound_command(player: tuple[str, ...], sound: str, volume: int) -> list[str]:
    gain = f"{volume / 100:.2f}"
    if sound == "synth":
        return [*player, "-v", gain, "-n", "synth", "0.15", "sine", "880"]
    return [*player, "-v", gain, sound]


def banner_title(message: Message) -> str:
    if message.kind == "channel":
        return f"{message.sender_name} (#{message.channel_name} > {message.topic})"
    if len(message.dm_user_ids) > 1:
        return f"{message.sender_name} (group)"
    return message.sender_name


def _safe_argument(text: str) -> str:
    # terminal-notifier would read a value starting with "-" as another option.
    return _ZERO_WIDTH_SPACE + text if text.startswith("-") else text


def banner_body(message: Message, limit: int = 200) -> str:
    text = " ".join(message.content.split())
    if not text:
        return "(no text)"
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return _safe_argument(text)


def banner_command(notifier: str, notification: Notification) -> list[str]:
    message = notification.message
    return [
        notifier,
        "-title",
        _safe_argument(banner_title(message)),
        "-message",
        banner_body(message),
        "-open",
        notification.url,
        "-group",
        f"z-iris-{message.server}-{message.id}",
    ]


class Output(Protocol):
    def deliver(self, notification: Notification) -> None: ...


def _spawn(command: list[str]) -> None:
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as error:
        print(f"z-iris: cannot run {command[0]}: {error}", file=sys.stderr)
        return
    threading.Thread(target=process.wait, daemon=True).start()


class RealOutput:
    def __init__(self, config: Config) -> None:
        self.config = config

    def deliver(self, notification: Notification) -> None:
        _spawn(banner_command(self.config.notifier, notification))
        _spawn(sound_command(self.config.player, self.config.sound, self.config.volume))


class DryRunOutput:
    def __init__(self, config: Config) -> None:
        self.config = config

    def deliver(self, notification: Notification) -> None:
        sound = sound_command(self.config.player, self.config.sound, self.config.volume)
        print(
            f"[dry-run] {notification.message.server} ({notification.reason}): "
            f"{banner_title(notification.message)}\n"
            f"          {banner_body(notification.message, 80)}\n"
            f"          open {notification.url}\n"
            f"          sound {' '.join(sound)}",
            flush=True,
        )
