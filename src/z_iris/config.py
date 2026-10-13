"""Load z-iris settings from a TOML file."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path

DEFAULT_PATH = Path("~/.config/z-iris/config.toml").expanduser()


class ConfigError(Exception):
    """The configuration is missing or invalid."""


@dataclass(frozen=True)
class ServerConfig:
    name: str
    zuliprc: Path


@dataclass(frozen=True)
class Config:
    servers: tuple[ServerConfig, ...]
    sound: str = "synth"
    volume: int = 60
    notify_channel_messages: bool = False
    player: tuple[str, ...] = ("play", "-q")
    notifier: str = "terminal-notifier"


def _servers(data: dict) -> tuple[ServerConfig, ...]:
    raw_servers = data.get("server", [])
    if not raw_servers:
        raise ConfigError("at least one [[server]] is required")
    servers: list[ServerConfig] = []
    seen: set[str] = set()
    for raw in raw_servers:
        name = raw.get("name")
        zuliprc = raw.get("zuliprc")
        if not isinstance(name, str) or not name:
            raise ConfigError("each [[server]] needs a name")
        if not isinstance(zuliprc, str) or not zuliprc:
            raise ConfigError(f"server {name!r} needs a zuliprc path")
        if name in seen:
            raise ConfigError(f"duplicate server name {name!r}")
        seen.add(name)
        servers.append(ServerConfig(name, Path(zuliprc).expanduser()))
    return tuple(servers)


def parse_config(text: str) -> Config:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"invalid TOML: {error}") from error

    servers = _servers(data)
    defaults = data.get("defaults", {})
    output = data.get("output", {})

    volume = defaults.get("volume", 60)
    if (
        not isinstance(volume, int)
        or isinstance(volume, bool)
        or not 0 <= volume <= 100
    ):
        raise ConfigError("volume must be an integer from 0 to 100")

    sound = defaults.get("sound", "synth")
    if not isinstance(sound, str) or not sound:
        raise ConfigError("sound must be 'synth' or a file path")
    if sound != "synth":
        sound = str(Path(sound).expanduser())

    notify_channel_messages = defaults.get("notify_channel_messages", False)
    if not isinstance(notify_channel_messages, bool):
        raise ConfigError("notify_channel_messages must be true or false")

    player = output.get("player", ["play", "-q"])
    if (
        not isinstance(player, list)
        or not player
        or not all(isinstance(part, str) for part in player)
    ):
        raise ConfigError("player must be a non-empty list of strings")

    notifier = output.get("notifier", "terminal-notifier")
    if not isinstance(notifier, str) or not notifier:
        raise ConfigError("notifier must be a command name or path")

    return Config(
        servers=servers,
        sound=sound,
        volume=volume,
        notify_channel_messages=notify_channel_messages,
        player=tuple(player),
        notifier=notifier,
    )


def load_config(path: Path | None = None) -> Config:
    path = path or DEFAULT_PATH
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise ConfigError(
            f"no config at {path}; copy config.example.toml there and edit it"
        ) from None
    return parse_config(text)
