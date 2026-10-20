"""Load z-iris settings from a TOML file."""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from z_iris.rules import KINDS, Rule, compile_channel
from z_iris.sounds import library

DEFAULT_PATH = Path("~/.config/z-iris/config.toml").expanduser()


class ConfigError(Exception):
    """The configuration is missing or invalid."""


def _number(low: float, high: float, integer: bool):
    def check(value: object, label: str) -> int | float:
        if isinstance(value, bool) or not isinstance(value, int if integer else (int, float)):
            kind = "an integer" if integer else "a number"
            raise ConfigError(f"{label} must be {kind} from {low} to {high}")
        if not low <= value <= high:
            raise ConfigError(f"{label} must be from {low} to {high}")
        return value

    return check


def _choice(*choices: str):
    def check(value: object, label: str) -> str:
        if value not in choices:
            raise ConfigError(f"{label} must be one of {', '.join(choices)}")
        return value  # type: ignore[return-value]

    return check


def _bool(value: object, label: str) -> bool:
    if not isinstance(value, bool):
        raise ConfigError(f"{label} must be true or false")
    return value


def _color(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        raise ConfigError(f"{label} must be a colour like #ff3b30")
    return value.lower()


# Settings a rule may override and [defaults] may set: name -> (check, built-in).
BEHAVIOUR: dict[str, tuple] = {
    "flash": (_choice("none", "screen", "top", "bottom", "left", "right"), "none"),
    "flash_color": (_color, "#ff3b30"),
    "flash_seconds": (_number(0.1, 10, False), 0.6),
    "repeat": (_number(0, 20, True), 0),
    "repeat_every": (_number(1, 3600, True), 30),
    "repeat_boost": (_number(0, 100, True), 0),
    "min_gap": (_number(0, 3600, True), 0),
    "batch_window": (_number(0, 300, True), 0),
    "sticky": (_bool, False),
}


def _behaviour(raw: dict, label: str) -> dict:
    found = {}
    for key, (check, _default) in BEHAVIOUR.items():
        if key in raw:
            found[key] = check(raw[key], f"{label}: {key}" if label else key)
    return found


@dataclass(frozen=True)
class FocusConfig:
    mode: str = "off"  # off, mentions_and_dms, or silent
    quiet_hours: tuple[tuple[int, int], ...] = ()  # (start, end) minutes after midnight
    quiet_mode: str = "silent"  # what quiet hours do: mentions_and_dms or silent


def _focus(data: dict) -> FocusConfig:
    table = _table(data, "focus")
    modes = ("off", "mentions_and_dms", "silent")
    mode = table.get("mode", "off")
    if mode not in modes:
        raise ConfigError(f"focus: mode must be one of {', '.join(modes)}")
    quiet_mode = table.get("quiet_mode", "silent")
    if quiet_mode not in modes[1:]:
        raise ConfigError(f"focus: quiet_mode must be one of {', '.join(modes[1:])}")
    raw_hours = table.get("quiet_hours", [])
    if not isinstance(raw_hours, list):
        raise ConfigError("focus: quiet_hours must be a list like [\"22:00-07:00\"]")
    hours = []
    for entry in raw_hours:
        match = re.fullmatch(r"(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})", str(entry))
        if not match:
            raise ConfigError(f"focus: bad quiet hours {entry!r}, use HH:MM-HH:MM")
        a, b, c, d = (int(g) for g in match.groups())
        if not (a < 24 and c < 24 and b < 60 and d < 60):
            raise ConfigError(f"focus: bad time in quiet hours {entry!r}")
        if (a, b) == (c, d):
            raise ConfigError(
                f"focus: quiet hours {entry!r} start and end together, so it would "
                "never be quiet; use 00:00-23:59 for all day"
            )
        hours.append((a * 60 + b, c * 60 + d))
    return FocusConfig(mode, tuple(hours), quiet_mode)


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
    external_images: bool = False
    master_volume: int = 100
    rules: tuple[Rule, ...] = ()
    behaviour: dict = field(default_factory=dict)  # [defaults] overrides of BEHAVIOUR
    focus: FocusConfig = FocusConfig()
    sounds: dict[str, Path] = field(default_factory=dict)


@dataclass(frozen=True)
class Action:
    sound: str
    volume: int
    banner: str
    rule: str | None  # the rule's label, for people
    flash: str = "none"
    flash_color: str = "#ff3b30"
    flash_seconds: float = 0.6
    repeat: int = 0
    repeat_every: int = 30
    repeat_boost: int = 0
    min_gap: int = 0
    batch_window: int = 0
    sticky: bool = False
    rule_index: int | None = None  # which rule, for per-rule state (labels can repeat)


def resolve_action(config: Config, server: str, rule: Rule | None) -> Action:
    """Combine a rule with the defaults. Volume is rule x server x master."""
    server_volume = next((s.volume for s in config.servers if s.name == server), 100)
    base = rule.volume if rule and rule.volume is not None else config.volume
    sound = rule.sound if rule and rule.sound is not None else config.sound
    banner = rule.banner if rule and rule.banner is not None else "full"
    final = round(base * server_volume * config.master_volume / 10000)
    if sound in config.sounds:
        sound = str(config.sounds[sound])
    merged = {key: default for key, (_check, default) in BEHAVIOUR.items()}
    merged.update(config.behaviour)
    if rule:
        merged.update(rule.behaviour)
    return Action(sound, final, banner, rule.label if rule else None,
                  rule_index=rule.index if rule else None, **merged)


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
        # An optional description; older configs called it name.
        description = raw.get("description", raw.get("name"))
        if description is not None and not isinstance(description, str):
            raise ConfigError(f"rule number {index + 1}: description must be text")
        description = description or None
        label = f"rule {description!r}" if description else f"rule number {index + 1}"
        kind = raw.get("match")
        if kind not in KINDS:
            raise ConfigError(f"{label}: match must be one of {', '.join(KINDS)}")

        # One channel or a list; each a pattern for the whole channel name.
        channel = raw.get("channel")
        channels = [channel] if isinstance(channel, str) else channel
        if channels is not None and (
            not isinstance(channels, list) or not channels
            or not all(isinstance(c, str) and c for c in channels)
        ):
            raise ConfigError(f"{label}: channel must be a channel name or a list of them")
        if channels is not None and kind not in ("channel", "topic"):
            raise ConfigError(f"{label}: channel only applies to channel and topic rules")
        if kind == "channel" and channels is None:
            raise ConfigError(f"{label}: a channel rule needs channel")
        for source in channels or ():
            try:
                compile_channel(source)
            except (re.error, OverflowError, RecursionError, ValueError) as error:
                raise ConfigError(f"{label}: bad channel pattern {source!r}: {error}") from error

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

        enabled = raw.get("enabled", True)
        if not isinstance(enabled, bool):
            raise ConfigError(f"{label}: enabled must be true or false")

        priority = raw.get("priority", 0)
        if not isinstance(priority, int) or isinstance(priority, bool):
            raise ConfigError(f"{label}: priority must be an integer")

        rules.append(
            Rule(description, kind, tuple(channels or ()), pattern, server, sound, volume, banner,
                 priority, index, enabled, _behaviour(raw, label))
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

    external_images = output.get("external_images", False)
    if not isinstance(external_images, bool):
        raise ConfigError("external_images must be true or false")

    return Config(
        servers=servers,
        sound=sound,
        volume=volume,
        notify_channel_messages=notify_channel_messages,
        player=tuple(player),
        notifier=notifier,
        external_images=external_images,
        master_volume=master_volume,
        rules=_rules(data, {server.name for server in servers}, sounds),
        behaviour=_behaviour(defaults, ""),
        focus=_focus(data),
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
