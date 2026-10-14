"""Load z-iris settings from a TOML file."""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from z_iris.rules import KINDS, Rule
from z_iris.sounds import library

DEFAULT_PATH = Path("~/.config/z-iris/config.toml").expanduser()


class ConfigError(Exception):
    """The configuration is missing or invalid."""


@dataclass(frozen=True)
class ServerConfig:
    name: str
    zuliprc: Path
    volume: int = 100


@dataclass(frozen=True)
class Config:
    servers: tuple[ServerConfig, ...]
    sound: str = "chime"
    volume: int = 60
    notify_channel_messages: bool = False
    player: tuple[str, ...] = ("play", "-q")
    notifier: str = "terminal-notifier"
    master_volume: int = 100
    rules: tuple[Rule, ...] = ()
    sounds: dict[str, Path] = field(default_factory=dict)


@dataclass(frozen=True)
class Action:
    sound: str
    volume: int
    banner: str
    rule: str | None


def resolve_action(config: Config, server: str, rule: Rule | None) -> Action:
    """Combine a rule with the defaults. Volume is rule x server x master."""
    server_volume = next((s.volume for s in config.servers if s.name == server), 100)
    base = rule.volume if rule and rule.volume is not None else config.volume
    sound = rule.sound if rule and rule.sound is not None else config.sound
    banner = rule.banner if rule and rule.banner is not None else "full"
    final = round(base * server_volume * config.master_volume / 10000)
    if sound in config.sounds:
        sound = str(config.sounds[sound])
    return Action(sound, final, banner, rule.name if rule else None)


def _sound(value: object, label: str, sounds: dict[str, Path]) -> str:
    """A sound is "none", a library name, or (older configs) a file path."""
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{label} must be a sound name, a file path or 'none'")
    if value == "none" or value in sounds:
        return value
    path = Path(value).expanduser()
    if path.is_file():
        return str(path)
    choices = ", ".join(sorted(sounds))
    raise ConfigError(f"{label}: unknown sound {value!r}; choose none or one of {choices}")


def _percent(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 100:
        raise ConfigError(f"{label} must be an integer from 0 to 100")
    return value


def _tables(data: dict, key: str) -> list[dict]:
    value = data.get(key, [])
    if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
        raise ConfigError(f"[[{key}]] must be a list of tables, written [[{key}]]")
    return value


def _table(data: dict, key: str) -> dict:
    value = data.get(key, {})
    if not isinstance(value, dict):
        raise ConfigError(f"[{key}] must be a table")
    return value


def _rules(
    data: dict, server_names: set[str], sounds: dict[str, Path]
) -> tuple[Rule, ...]:
    rules: list[Rule] = []
    for index, raw in enumerate(_tables(data, "rule")):
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            raise ConfigError(f"rule number {index + 1} needs a name")
        label = f"rule {name!r}"
        kind = raw.get("match")
        if kind not in KINDS:
            raise ConfigError(f"{label}: match must be one of {', '.join(KINDS)}")

        channel = raw.get("channel")
        if channel is not None and (not isinstance(channel, str) or not channel):
            raise ConfigError(f"{label}: channel must be a name")
        if channel is not None and kind not in ("channel", "topic"):
            raise ConfigError(f"{label}: channel only applies to channel and topic rules")
        if kind == "channel" and channel is None:
            raise ConfigError(f"{label}: a channel rule needs channel")

        pattern = None
        source = {"topic": raw.get("topic"), "keyword": raw.get("keyword")}.get(kind)
        if kind in ("topic", "keyword"):
            if not isinstance(source, str) or not source:
                raise ConfigError(f"{label}: a {kind} rule needs {kind}")
            try:
                pattern = re.compile(source, re.IGNORECASE)
            except (re.error, OverflowError, RecursionError, ValueError) as error:
                raise ConfigError(f"{label}: bad regular expression: {error}") from error

        server = raw.get("server")
        if server is not None and server not in server_names:
            raise ConfigError(f"{label}: unknown server {server!r}")

        volume = raw.get("volume")
        if volume is not None:
            volume = _percent(volume, f"{label}: volume")

        banner = raw.get("banner")
        if banner is not None and banner not in ("full", "title", "off"):
            raise ConfigError(f"{label}: banner must be full, title or off")

        sound = raw.get("sound")
        if sound is not None:
            sound = _sound(sound, label, sounds)

        priority = raw.get("priority", 0)
        if not isinstance(priority, int) or isinstance(priority, bool):
            raise ConfigError(f"{label}: priority must be an integer")

        rules.append(
            Rule(name, kind, channel, pattern, server, sound, volume, banner,
                 priority, index)
        )
    return tuple(rules)


def _servers(data: dict) -> tuple[ServerConfig, ...]:
    raw_servers = _tables(data, "server")
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
        volume = _percent(raw.get("volume", 100), f"server {name!r} volume")
        servers.append(ServerConfig(name, Path(zuliprc).expanduser(), volume))
    return tuple(servers)


def parse_config(text: str, sounds_dir: Path | None = None) -> Config:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"invalid TOML: {error}") from error

    servers = _servers(data)
    sounds = library(sounds_dir)
    defaults = _table(data, "defaults")
    output = _table(data, "output")

    volume = _percent(defaults.get("volume", 60), "volume")
    master_volume = _percent(defaults.get("master_volume", 100), "master_volume")

    sound = _sound(defaults.get("sound", "chime"), "default sound", sounds)

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
        master_volume=master_volume,
        rules=_rules(data, {server.name for server in servers}, sounds),
        sounds=sounds,
    )


def load_config(path: Path | None = None) -> Config:
    path = path or DEFAULT_PATH
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise ConfigError(
            f"no config at {path}; copy config.example.toml there and edit it"
        ) from None
    return parse_config(text, path.parent / "sounds")
