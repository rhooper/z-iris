# z-iris Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menubar app, z-iris, that streams messages from one or more Zulip servers, shows a banner and plays one default sound for messages that matter, and opens the right chat in Zulip Desktop when a banner is clicked.

**Architecture:** One thread per server runs a Zulip event-queue loop. Each event goes through a pure `Pipeline` that tracks mute state, decides whether to notify, and builds a `zulip://` narrow URL. A `Notification` goes to an `Output` that runs sox for sound and terminal-notifier for the banner. A rumps menubar app shows connection state and a pause switch. All logic lives in small pure modules so it can be tested without a network or a screen.

**Tech Stack:** Python 3.13 via uv, the official `zulip` client, `rumps` for the menubar, `pytest`, sox, terminal-notifier.

**Spec:** `docs/superpowers/specs/2026-10-13-custom-notification-sounds-design.md` (Piece 2, phase 1). Written in the zulip-desktop repo, and copied to `~/Devel/z-iris/docs/` in Task 1.

## Global Constraints

- macOS only. Python, `requires-python = ">=3.11"`, developed on 3.13.
- Sound plays through sox (`play`). Never `afplay` and never the macOS system sounds.
- Banners use terminal-notifier, and a click opens a `zulip://<host>/#narrow/...` URL.
- No shell is ever used to run a command. Message text is only ever passed as a separate argv element.
- The menubar app has no Dock icon and no main window.
- Phase 1 settings come from a TOML file at `~/.config/z-iris/config.toml`. There is no settings window yet.
- Phase 1 plays one default sound at one configured volume. Rules, per-rule sounds, repetition, intervals, intensity and batching are phases 2 and 3 and are not built here.
- Credentials stay in each server's zuliprc. z-iris never reads, logs or prints their contents.
- Dev workflow: commit after each task. The z-iris repo is new, so it has no pre-commit hook.

## Review Focus

- A topic or channel name containing `.`, `/`, `#`, `%`, spaces, accents or emoji must produce a `zulip://` URL that Zulip Desktop accepts and Zulip decodes to the same topic.
- A 1:1 DM, a group DM and a DM to yourself must each build a narrow URL naming the right people.
- A personal @-mention inside a muted topic must still notify. A wildcard mention in a muted channel must not.
- Message text such as `-open foo`, text with newlines, an empty body and a 5,000-character body must produce a sane banner and never be read as a terminal-notifier option.
- A server dropping, an expired event queue, and a missing `play` or `terminal-notifier` binary must never kill the app. Each shows up as a status line, and recovery is automatic.

---

## File Structure

```
z-iris/
  pyproject.toml
  README.md
  CLAUDE.md
  config.example.toml
  src/z_iris/__init__.py
  src/z_iris/config.py      TOML to Config
  src/z_iris/message.py     Zulip event to Message
  src/z_iris/narrow.py      Message to zulip:// URL
  src/z_iris/mutes.py       mute state from register response and events
  src/z_iris/policy.py      should this message notify, and why
  src/z_iris/pipeline.py    event in, Notification or None out
  src/z_iris/output.py      sound and banner commands, real and dry-run
  src/z_iris/stream.py      per-server event loop, status board, controls
  src/z_iris/menubar.py     rumps app
  src/z_iris/__main__.py    command line
  tests/test_*.py
```

### Task 1: Scaffold the repository

**Files:**

- Create: `~/Devel/z-iris/` with `pyproject.toml`, `.gitignore`, `README.md`, `CLAUDE.md`, `config.example.toml`, `src/z_iris/__init__.py`, `tests/test_smoke.py`, `docs/` copies of the spec and this plan.

- [ ] **Step 1: Create the repo and layout**

```bash
mkdir -p ~/Devel/z-iris/src/z_iris ~/Devel/z-iris/tests ~/Devel/z-iris/docs
cd ~/Devel/z-iris && git init -b main
cp ~/Devel/zulip-desktop/docs/superpowers/specs/2026-10-13-custom-notification-sounds-design.md docs/design.md
cp ~/Devel/zulip-desktop/docs/superpowers/plans/2026-10-13-z-iris-phase-1.md docs/plan-phase-1.md
```

- [ ] **Step 2: Write `pyproject.toml`**

```toml
[project]
name = "z-iris"
version = "0.1.0"
description = "Menubar notifier for Zulip with custom sounds"
requires-python = ">=3.11"
dependencies = ["zulip>=0.9.0", "rumps>=0.4.0"]

[project.scripts]
z-iris = "z_iris.__main__:main"

[dependency-groups]
dev = ["pytest>=8"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/z_iris"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
```

- [ ] **Step 3: Write the remaining small files**

`.gitignore`:

```
.venv/
__pycache__/
*.egg-info/
.pytest_cache/
```

`src/z_iris/__init__.py`:

```python
"""z-iris: a menubar notifier for Zulip."""

__version__ = "0.1.0"
```

`tests/test_smoke.py`:

```python
import z_iris


def test_version():
    assert z_iris.__version__ == "0.1.0"
```

`config.example.toml`:

```toml
# Copy to ~/.config/z-iris/config.toml

[[server]]
name = "work"
zuliprc = "~/.zuliprc"

[defaults]
# "synth" is a built-in chime. Or give a path to any sound file sox can play.
sound = "synth"
# Percent of the system output level, 0 to 100.
volume = 60
# Phase 1 notifies for DMs and mentions. Set true to also notify for every
# unmuted channel message, which is noisy on a busy server.
notify_channel_messages = false

[output]
player = ["play", "-q"]
notifier = "terminal-notifier"
```

`README.md`: a short description, install (`uv sync --python 3.13`, `brew install sox terminal-notifier`), usage (`uv run z-iris`, `--dry-run`, `probe`), and the config location. `CLAUDE.md`: the build and test commands (`uv sync --python 3.13`, `uv run pytest`), the module map from this plan's File Structure, and the global constraints above.

- [ ] **Step 4: Install and run the smoke test**

Run: `uv sync --python 3.13 && uv run pytest -q`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Scaffold z-iris with design docs and a smoke test."
```

### Task 2: Config

**Files:**

- Create: `src/z_iris/config.py`
- Test: `tests/test_config.py`

**Interfaces:**

- Produces: `ConfigError(Exception)`, `ServerConfig(name: str, zuliprc: Path)`, `Config(servers: tuple[ServerConfig, ...], sound: str, volume: int, notify_channel_messages: bool, player: tuple[str, ...], notifier: str)`, `parse_config(text: str) -> Config`, `load_config(path: Path | None = None) -> Config`, `DEFAULT_PATH: Path`.

- [ ] **Step 1: Write the failing tests**

```python
from pathlib import Path

import pytest

from z_iris.config import ConfigError, load_config, parse_config

MINIMAL = """
[[server]]
name = "work"
zuliprc = "~/.zuliprc"
"""


def test_minimal_config_gets_defaults():
    config = parse_config(MINIMAL)
    assert [s.name for s in config.servers] == ["work"]
    assert config.servers[0].zuliprc == Path("~/.zuliprc").expanduser()
    assert config.sound == "synth"
    assert config.volume == 60
    assert config.notify_channel_messages is False
    assert config.player == ("play", "-q")
    assert config.notifier == "terminal-notifier"


def test_overrides_and_sound_path_expansion():
    config = parse_config(
        MINIMAL
        + """
[defaults]
sound = "~/Sounds/a.wav"
volume = 30
notify_channel_messages = true
[output]
player = ["play"]
notifier = "/opt/homebrew/bin/terminal-notifier"
"""
    )
    assert config.sound == str(Path("~/Sounds/a.wav").expanduser())
    assert config.volume == 30
    assert config.notify_channel_messages is True
    assert config.player == ("play",)
    assert config.notifier == "/opt/homebrew/bin/terminal-notifier"


@pytest.mark.parametrize(
    "text, message",
    [
        ("", "at least one"),
        ("not = [valid", "invalid TOML"),
        ('[[server]]\nzuliprc = "x"', "needs a name"),
        ('[[server]]\nname = "a"', "needs a zuliprc"),
        (MINIMAL + MINIMAL, "duplicate"),
        (MINIMAL + "[defaults]\nvolume = 101", "volume"),
        (MINIMAL + "[defaults]\nvolume = -1", "volume"),
        (MINIMAL + "[defaults]\nvolume = true", "volume"),
        (MINIMAL + '[defaults]\nvolume = "loud"', "volume"),
        (MINIMAL + "[defaults]\nsound = 3", "sound"),
        (MINIMAL + '[defaults]\nnotify_channel_messages = "yes"', "notify_channel"),
        (MINIMAL + "[output]\nplayer = []", "player"),
        (MINIMAL + '[output]\nplayer = "play"', "player"),
    ],
)
def test_bad_config_is_rejected(text, message):
    with pytest.raises(ConfigError, match=message):
        parse_config(text)


def test_missing_file_explains_itself(tmp_path):
    with pytest.raises(ConfigError, match="config.example.toml"):
        load_config(tmp_path / "nope.toml")


def test_load_reads_a_file(tmp_path):
    path = tmp_path / "c.toml"
    path.write_text(MINIMAL)
    assert load_config(path).servers[0].name == "work"
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_config.py -q`
Expected: FAIL, `z_iris.config` not found.

- [ ] **Step 3: Implement**

```python
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
    if not isinstance(volume, int) or isinstance(volume, bool) or not 0 <= volume <= 100:
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
```

- [ ] **Step 4: Run to verify pass**

Run: `uv run pytest tests/test_config.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add TOML config loading with validation."
```

### Task 3: Messages and narrow URLs

**Files:**

- Create: `src/z_iris/message.py`, `src/z_iris/narrow.py`
- Test: `tests/test_message.py`, `tests/test_narrow.py`

**Interfaces:**

- Produces: `Message` frozen dataclass with fields `server: str, host: str, id: int, kind: str, sender_id: int, sender_name: str, content: str, flags: frozenset[str], channel_id: int | None, channel_name: str | None, topic: str | None, dm_user_ids: tuple[int, ...]`, properties `is_mention`, `is_wildcard_mention`, `has_alert_word`; `message_from_event(server: str, host: str, self_id: int, event: dict) -> Message` (raises `KeyError` or `TypeError` on malformed input); `encode_component(text: str) -> str`; `narrow_url(message: Message) -> str`.

- [ ] **Step 1: Write the failing tests**

`tests/test_message.py`:

```python
from z_iris.message import message_from_event

SELF = 5


def channel_event(**overrides):
    message = {
        "id": 101,
        "type": "stream",
        "stream_id": 7,
        "display_recipient": "ops",
        "subject": "deploys",
        "sender_id": 9,
        "sender_full_name": "Ada",
        "content": "hello",
    }
    message.update(overrides)
    return {"type": "message", "message": message, "flags": ["mentioned"]}


def test_channel_message():
    m = message_from_event("work", "chat.example.com", SELF, channel_event())
    assert (m.kind, m.channel_id, m.channel_name, m.topic) == ("channel", 7, "ops", "deploys")
    assert (m.id, m.sender_id, m.sender_name, m.content) == (101, 9, "Ada", "hello")
    assert m.is_mention and not m.is_wildcard_mention and not m.has_alert_word
    assert m.dm_user_ids == ()


def test_topic_key_fallback():
    event = channel_event()
    event["message"]["topic"] = event["message"].pop("subject")
    assert message_from_event("w", "h", SELF, event).topic == "deploys"


def dm_event(people):
    return {
        "type": "message",
        "message": {
            "id": 5,
            "type": "private",
            "display_recipient": [{"id": i, "full_name": f"p{i}"} for i in people],
            "sender_id": people[0],
            "sender_full_name": "p",
            "content": "x",
        },
        "flags": [],
    }


def test_one_to_one_dm_names_the_other_person():
    m = message_from_event("w", "h", SELF, dm_event([9, SELF]))
    assert (m.kind, m.dm_user_ids) == ("dm", (9,))


def test_group_dm_lists_everyone_but_me_sorted():
    m = message_from_event("w", "h", SELF, dm_event([12, SELF, 3]))
    assert m.dm_user_ids == (3, 12)


def test_dm_to_self():
    m = message_from_event("w", "h", SELF, dm_event([SELF]))
    assert m.dm_user_ids == (SELF,)


def test_malformed_event_raises():
    import pytest

    with pytest.raises((KeyError, TypeError)):
        message_from_event("w", "h", SELF, {"type": "message", "message": {}})
```

`tests/test_narrow.py`:

```python
import pytest

from z_iris.message import Message
from z_iris.narrow import encode_component, narrow_url


def channel(name="ops", topic="deploys"):
    return Message("w", "chat.example.com", 101, "channel", 9, "Ada", "x",
                   frozenset(), 7, name, topic, ())


def dm(ids):
    return Message("w", "chat.example.com", 101, "dm", 9, "Ada", "x",
                   frozenset(), None, None, None, tuple(ids))


@pytest.mark.parametrize(
    "text, expected",
    [
        ("deploys", "deploys"),
        ("two words", "two.20words"),
        ("a.b", "a.2Eb"),
        ("a/b", "a.2Fb"),
        ("c#1", "c.231"),
        ("100%", "100.25"),
        ("café", "caf.C3.A9"),
        ("🚀", ".F0.9F.9A.80"),
    ],
)
def test_encode_component_matches_zulip(text, expected):
    assert encode_component(text) == expected


def test_channel_url():
    assert narrow_url(channel()) == (
        "zulip://chat.example.com/#narrow/stream/7-ops/topic/deploys/near/101"
    )


def test_channel_url_encodes_names():
    url = narrow_url(channel("my team", "q&a: 1.0"))
    assert url == (
        "zulip://chat.example.com/#narrow/stream/7-my.20team"
        "/topic/q.26a.3A.201.2E0/near/101"
    )


def test_one_to_one_dm_url():
    assert narrow_url(dm([9])) == "zulip://chat.example.com/#narrow/dm/9-pm/near/101"


def test_group_dm_url():
    assert narrow_url(dm([3, 12])) == (
        "zulip://chat.example.com/#narrow/dm/3,12-group/near/101"
    )


def test_url_only_contains_characters_the_desktop_handler_accepts():
    import re

    url = narrow_url(channel("a b/c", "x.y#z 🚀"))
    fragment = url.split("#", 1)[1]
    assert re.fullmatch(r"narrow/[\w.~/,:+\-]+", fragment)
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_message.py tests/test_narrow.py -q`
Expected: FAIL, modules not found.

- [ ] **Step 3: Implement `message.py`**

```python
"""A Zulip message event, reduced to the fields z-iris needs."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Message:
    server: str
    host: str
    id: int
    kind: str  # "channel" or "dm"
    sender_id: int
    sender_name: str
    content: str
    flags: frozenset[str]
    channel_id: int | None
    channel_name: str | None
    topic: str | None
    dm_user_ids: tuple[int, ...]  # everyone but me, sorted; just me for a self-DM

    @property
    def is_mention(self) -> bool:
        return "mentioned" in self.flags

    @property
    def is_wildcard_mention(self) -> bool:
        return "wildcard_mentioned" in self.flags

    @property
    def has_alert_word(self) -> bool:
        return "has_alert_word" in self.flags


def message_from_event(server: str, host: str, self_id: int, event: dict) -> Message:
    """Build a Message. Raises KeyError or TypeError if the event is malformed."""
    raw = event["message"]
    flags = frozenset(event.get("flags", ()))
    common = {
        "server": server,
        "host": host,
        "id": raw["id"],
        "sender_id": raw["sender_id"],
        "sender_name": raw["sender_full_name"],
        "content": raw["content"],
        "flags": flags,
    }
    if raw["type"] == "stream":
        return Message(
            **common,
            kind="channel",
            channel_id=raw["stream_id"],
            channel_name=raw["display_recipient"],
            topic=raw["subject"] if "subject" in raw else raw["topic"],
            dm_user_ids=(),
        )

    others = sorted({person["id"] for person in raw["display_recipient"]} - {self_id})
    return Message(
        **common,
        kind="dm",
        channel_id=None,
        channel_name=None,
        topic=None,
        dm_user_ids=tuple(others) or (self_id,),
    )
```

- [ ] **Step 4: Implement `narrow.py`**

```python
"""Build zulip:// links that Zulip Desktop opens in the right chat."""

from __future__ import annotations

from urllib.parse import quote

from z_iris.message import Message


def encode_component(text: str) -> str:
    """Encode text the way Zulip does in narrow hashes.

    Zulip percent-encodes everything, then writes "." instead of "%", so a real
    "." must be encoded first.
    """
    return quote(text, safe="").replace(".", "%2E").replace("%", ".")


def narrow_url(message: Message) -> str:
    base = f"zulip://{message.host}/#narrow"
    if message.kind == "channel":
        channel = f"{message.channel_id}-{encode_component(message.channel_name or '')}"
        topic = encode_component(message.topic or "")
        return f"{base}/stream/{channel}/topic/{topic}/near/{message.id}"

    ids = ",".join(str(i) for i in message.dm_user_ids)
    suffix = "group" if len(message.dm_user_ids) > 1 else "pm"
    return f"{base}/dm/{ids}-{suffix}/near/{message.id}"
```

- [ ] **Step 5: Run to verify pass, then commit**

Run: `uv run pytest tests/test_message.py tests/test_narrow.py -q`
Expected: all pass.

```bash
git add -A && git commit -m "Parse message events and build zulip:// narrow URLs."
```

### Task 4: Mute state

**Files:**

- Create: `src/z_iris/mutes.py`
- Test: `tests/test_mutes.py`

**Interfaces:**

- Produces: `MuteState` with `from_register(response: dict) -> MuteState` (classmethod), `apply(event: dict) -> None`, `is_muted(channel_id: int, topic: str) -> bool`.

Zulip semantics used: a topic's `visibility_policy` is 1 muted, 2 unmuted, 3 followed, 0 inherit. A topic explicitly muted is muted. An unmuted or followed topic is not muted even in a muted channel. Otherwise the channel's `is_muted` decides. Topic names compare case-insensitively. Older servers send `muted_topics` as `[channel_name, topic, timestamp]` lists instead of `user_topics`.

- [ ] **Step 1: Write the failing tests**

```python
from z_iris.mutes import MuteState


def register(**extra):
    base = {
        "subscriptions": [
            {"stream_id": 1, "name": "ops", "is_muted": False},
            {"stream_id": 2, "name": "random", "is_muted": True},
        ],
        "user_topics": [
            {"stream_id": 1, "topic_name": "Noise", "visibility_policy": 1},
            {"stream_id": 2, "topic_name": "important", "visibility_policy": 2},
            {"stream_id": 2, "topic_name": "watched", "visibility_policy": 3},
            {"stream_id": 1, "topic_name": "plain", "visibility_policy": 0},
        ],
    }
    base.update(extra)
    return base


def test_initial_state():
    m = MuteState.from_register(register())
    assert not m.is_muted(1, "anything")
    assert m.is_muted(1, "noise")  # case-insensitive
    assert m.is_muted(2, "chatter")
    assert not m.is_muted(2, "IMPORTANT")
    assert not m.is_muted(2, "watched")
    assert not m.is_muted(1, "plain")


def test_legacy_muted_topics_list():
    response = {
        "subscriptions": [{"stream_id": 1, "name": "ops", "is_muted": False}],
        "muted_topics": [["ops", "Noise", 1700000000]],
    }
    m = MuteState.from_register(response)
    assert m.is_muted(1, "noise")
    assert not m.is_muted(1, "other")


def test_subscription_events():
    m = MuteState.from_register(register())
    m.apply({"type": "subscription", "op": "update", "stream_id": 1,
             "property": "is_muted", "value": True})
    assert m.is_muted(1, "anything")
    m.apply({"type": "subscription", "op": "update", "stream_id": 1,
             "property": "color", "value": "#fff"})
    assert m.is_muted(1, "anything")
    m.apply({"type": "subscription", "op": "add",
             "subscriptions": [{"stream_id": 3, "name": "new", "is_muted": True}]})
    assert m.is_muted(3, "x")
    m.apply({"type": "subscription", "op": "remove",
             "subscriptions": [{"stream_id": 3}]})
    assert not m.is_muted(3, "x")


def test_user_topic_event():
    m = MuteState.from_register(register())
    m.apply({"type": "user_topic", "stream_id": 1, "topic_name": "Fresh",
             "visibility_policy": 1})
    assert m.is_muted(1, "fresh")
    m.apply({"type": "user_topic", "stream_id": 1, "topic_name": "fresh",
             "visibility_policy": 0})
    assert not m.is_muted(1, "fresh")


def test_legacy_muted_topics_event_replaces_the_list():
    m = MuteState.from_register(register(user_topics=[], muted_topics=[]))
    m.apply({"type": "muted_topics", "muted_topics": [["ops", "Noise", 1]]})
    assert m.is_muted(1, "noise")
    m.apply({"type": "muted_topics", "muted_topics": []})
    assert not m.is_muted(1, "noise")


def test_unknown_events_are_ignored():
    m = MuteState.from_register(register())
    m.apply({"type": "heartbeat"})
    m.apply({"type": "subscription", "op": "peer_add"})
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_mutes.py -q`
Expected: FAIL, module not found.

- [ ] **Step 3: Implement**

```python
"""Track which channels and topics the user has muted."""

from __future__ import annotations

_MUTED, _UNMUTED, _FOLLOWED = 1, 2, 3


class MuteState:
    def __init__(self) -> None:
        self._muted_channels: set[int] = set()
        self._channel_ids_by_name: dict[str, int] = {}
        self._topic_policy: dict[tuple[int, str], int] = {}
        # Topics that came from the legacy muted_topics list, so a new legacy
        # list can replace them without touching user_topic state.
        self._legacy_topics: set[tuple[int, str]] = set()

    @classmethod
    def from_register(cls, response: dict) -> MuteState:
        state = cls()
        for subscription in response.get("subscriptions", ()):
            state._add_subscription(subscription)
        for entry in response.get("user_topics", ()):
            state._set_policy(
                entry["stream_id"], entry["topic_name"], entry["visibility_policy"]
            )
        state._set_legacy_muted_topics(response.get("muted_topics", ()))
        return state

    def is_muted(self, channel_id: int, topic: str) -> bool:
        policy = self._topic_policy.get((channel_id, topic.lower()), 0)
        if policy == _MUTED:
            return True
        if policy in (_UNMUTED, _FOLLOWED):
            return False
        return channel_id in self._muted_channels

    def apply(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "subscription":
            self._apply_subscription(event)
        elif kind == "user_topic":
            self._set_policy(
                event["stream_id"], event["topic_name"], event["visibility_policy"]
            )
        elif kind == "muted_topics":
            self._set_legacy_muted_topics(event.get("muted_topics", ()))

    def _add_subscription(self, subscription: dict) -> None:
        channel_id = subscription["stream_id"]
        self._channel_ids_by_name[subscription.get("name", "")] = channel_id
        if subscription.get("is_muted"):
            self._muted_channels.add(channel_id)
        else:
            self._muted_channels.discard(channel_id)

    def _apply_subscription(self, event: dict) -> None:
        op = event.get("op")
        if op == "add":
            for subscription in event.get("subscriptions", ()):
                self._add_subscription(subscription)
        elif op == "remove":
            for subscription in event.get("subscriptions", ()):
                self._muted_channels.discard(subscription["stream_id"])
        elif op == "update" and event.get("property") == "is_muted":
            if event["value"]:
                self._muted_channels.add(event["stream_id"])
            else:
                self._muted_channels.discard(event["stream_id"])

    def _set_policy(self, channel_id: int, topic: str, policy: int) -> None:
        key = (channel_id, topic.lower())
        self._legacy_topics.discard(key)
        if policy == 0:
            self._topic_policy.pop(key, None)
        else:
            self._topic_policy[key] = policy

    def _set_legacy_muted_topics(self, entries) -> None:
        for key in self._legacy_topics:
            self._topic_policy.pop(key, None)
        self._legacy_topics = set()
        for channel_name, topic, *_ in entries:
            channel_id = self._channel_ids_by_name.get(channel_name)
            if channel_id is None:
                continue
            key = (channel_id, topic.lower())
            self._topic_policy[key] = _MUTED
            self._legacy_topics.add(key)
```

- [ ] **Step 4: Run to verify pass, then commit**

Run: `uv run pytest tests/test_mutes.py -q`
Expected: all pass.

```bash
git add -A && git commit -m "Track channel and topic mutes from the register response and events."
```

### Task 5: Policy and pipeline

**Files:**

- Create: `src/z_iris/policy.py`, `src/z_iris/pipeline.py`
- Test: `tests/test_policy.py`, `tests/test_pipeline.py`

**Interfaces:**

- Consumes: `Message`, `message_from_event`, `narrow_url`, `MuteState`.
- Produces: `Decision(notify: bool, reason: str)`; `decide(message: Message, mutes: MuteState, self_id: int, notify_channel_messages: bool) -> Decision`; `Notification(message: Message, url: str, reason: str)`; `Pipeline(server: str, host: str, self_id: int, mutes: MuteState, notify_channel_messages: bool)` with `handle(event: dict) -> Notification | None`.

Rules, in order: own messages never notify. A message in a muted channel or topic notifies only for a personal `mentioned` flag. DMs notify. Personal mention, wildcard mention and alert words notify. Other channel messages notify only when `notify_channel_messages` is true.

- [ ] **Step 1: Write the failing tests**

`tests/test_policy.py`:

```python
import pytest

from z_iris.message import Message
from z_iris.mutes import MuteState
from z_iris.policy import decide

SELF = 5


def mutes(muted_channel=False, muted_topic=False):
    return MuteState.from_register({
        "subscriptions": [{"stream_id": 1, "name": "ops", "is_muted": muted_channel}],
        "user_topics": [{"stream_id": 1, "topic_name": "t", "visibility_policy": 1}]
        if muted_topic else [],
    })


def channel_msg(flags=(), sender=9):
    return Message("w", "h", 1, "channel", sender, "A", "x", frozenset(flags), 1, "ops", "t", ())


def dm_msg(sender=9):
    return Message("w", "h", 1, "dm", sender, "A", "x", frozenset(), None, None, None, (sender,))


@pytest.mark.parametrize(
    "message, state, channels, notify, reason",
    [
        (channel_msg(sender=SELF, flags=["mentioned"]), mutes(), False, False, "own"),
        (dm_msg(sender=SELF), mutes(), False, False, "own"),
        (dm_msg(), mutes(), False, True, "dm"),
        (channel_msg(["mentioned"]), mutes(), False, True, "mention"),
        (channel_msg(["wildcard_mentioned"]), mutes(), False, True, "mention"),
        (channel_msg(["has_alert_word"]), mutes(), False, True, "mention"),
        (channel_msg(), mutes(), False, False, "not enabled"),
        (channel_msg(), mutes(), True, True, "channel"),
        (channel_msg(), mutes(muted_channel=True), True, False, "muted"),
        (channel_msg(), mutes(muted_topic=True), True, False, "muted"),
        (channel_msg(["mentioned"]), mutes(muted_topic=True), False, True, "mention"),
        (channel_msg(["wildcard_mentioned"]), mutes(muted_channel=True), False, False, "muted"),
    ],
)
def test_decide(message, state, channels, notify, reason):
    decision = decide(message, state, SELF, channels)
    assert decision.notify is notify
    assert reason in decision.reason
```

`tests/test_pipeline.py`:

```python
from z_iris.mutes import MuteState
from z_iris.pipeline import Pipeline

SELF = 5


def pipeline(channels=False):
    mutes = MuteState.from_register({
        "subscriptions": [{"stream_id": 7, "name": "ops", "is_muted": False}],
        "user_topics": [],
    })
    return Pipeline("work", "chat.example.com", SELF, mutes, channels)


def event(flags=(), topic="deploys", sender=9):
    return {"type": "message", "flags": list(flags), "message": {
        "id": 101, "type": "stream", "stream_id": 7, "display_recipient": "ops",
        "subject": topic, "sender_id": sender, "sender_full_name": "Ada", "content": "hi"}}


def test_mention_becomes_a_notification_with_a_url():
    n = pipeline().handle(event(["mentioned"]))
    assert n is not None
    assert n.reason == "mention"
    assert n.url == "zulip://chat.example.com/#narrow/stream/7-ops/topic/deploys/near/101"
    assert n.message.sender_name == "Ada"


def test_ordinary_channel_message_is_ignored():
    assert pipeline().handle(event()) is None


def test_mute_events_change_later_decisions():
    p = pipeline(channels=True)
    assert p.handle(event()) is not None
    p.handle({"type": "user_topic", "stream_id": 7, "topic_name": "deploys",
              "visibility_policy": 1})
    assert p.handle(event()) is None


def test_malformed_and_unrelated_events_are_ignored():
    p = pipeline(channels=True)
    assert p.handle({"type": "message", "message": {}}) is None
    assert p.handle({"type": "heartbeat"}) is None
    assert p.handle({}) is None
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_policy.py tests/test_pipeline.py -q`
Expected: FAIL, modules not found.

- [ ] **Step 3: Implement `policy.py`**

```python
"""Decide whether a message deserves a notification."""

from __future__ import annotations

from dataclasses import dataclass

from z_iris.message import Message
from z_iris.mutes import MuteState


@dataclass(frozen=True)
class Decision:
    notify: bool
    reason: str


def decide(
    message: Message, mutes: MuteState, self_id: int, notify_channel_messages: bool
) -> Decision:
    if message.sender_id == self_id:
        return Decision(False, "own message")

    if (
        message.kind == "channel"
        and mutes.is_muted(message.channel_id, message.topic or "")
        and not message.is_mention
    ):
        return Decision(False, "muted")

    if message.kind == "dm":
        return Decision(True, "dm")
    if message.is_mention or message.is_wildcard_mention or message.has_alert_word:
        return Decision(True, "mention")
    if notify_channel_messages:
        return Decision(True, "channel")
    return Decision(False, "channel messages not enabled")
```

- [ ] **Step 4: Implement `pipeline.py`**

```python
"""Turn raw Zulip events into notifications."""

from __future__ import annotations

from dataclasses import dataclass

from z_iris.message import Message, message_from_event
from z_iris.mutes import MuteState
from z_iris.narrow import narrow_url
from z_iris.policy import decide


@dataclass(frozen=True)
class Notification:
    message: Message
    url: str
    reason: str


class Pipeline:
    def __init__(
        self,
        server: str,
        host: str,
        self_id: int,
        mutes: MuteState,
        notify_channel_messages: bool,
    ) -> None:
        self.server = server
        self.host = host
        self.self_id = self_id
        self.mutes = mutes
        self.notify_channel_messages = notify_channel_messages

    def handle(self, event: dict) -> Notification | None:
        if event.get("type") != "message":
            try:
                self.mutes.apply(event)
            except (KeyError, TypeError):
                pass
            return None

        try:
            message = message_from_event(self.server, self.host, self.self_id, event)
        except (KeyError, TypeError):
            return None

        decision = decide(
            message, self.mutes, self.self_id, self.notify_channel_messages
        )
        if not decision.notify:
            return None
        return Notification(message, narrow_url(message), decision.reason)
```

- [ ] **Step 5: Run to verify pass, then commit**

Run: `uv run pytest -q`
Expected: all pass.

```bash
git add -A && git commit -m "Decide which messages notify and build notifications."
```

### Task 6: Output commands

**Files:**

- Create: `src/z_iris/output.py`
- Test: `tests/test_output.py`

**Interfaces:**

- Consumes: `Config`, `Notification`, `Message`.
- Produces: `sound_command(player: tuple[str, ...], sound: str, volume: int) -> list[str]`; `banner_title(message: Message) -> str`; `banner_body(message: Message, limit: int = 200) -> str`; `banner_command(notifier: str, notification: Notification) -> list[str]`; `Output` protocol with `deliver(notification: Notification) -> None`; `RealOutput(config: Config)`; `DryRunOutput(config: Config)` with the same method.

- [ ] **Step 1: Write the failing tests**

```python
from z_iris.message import Message
from z_iris.output import (
    banner_body, banner_command, banner_title, sound_command,
)
from z_iris.pipeline import Notification


def channel(content="hello", sender="Ada"):
    return Message("work", "h", 101, "channel", 9, sender, content,
                   frozenset(), 7, "ops", "deploys", ())


def dm(ids=(9,)):
    return Message("work", "h", 102, "dm", 9, "Ada", "x", frozenset(),
                   None, None, None, tuple(ids))


def test_sound_command_for_synth_and_files():
    assert sound_command(("play", "-q"), "synth", 60) == [
        "play", "-q", "-v", "0.60", "-n", "synth", "0.15", "sine", "880"]
    assert sound_command(("play",), "/a/b.wav", 5) == ["play", "-v", "0.05", "/a/b.wav"]


def test_titles():
    assert banner_title(channel()) == "Ada (#ops > deploys)"
    assert banner_title(dm()) == "Ada"
    assert banner_title(dm((3, 12))) == "Ada (group)"


def test_body_collapses_whitespace_and_truncates():
    assert banner_body(channel("a\n\n  b\tc")) == "a b c"
    body = banner_body(channel("x" * 5000))
    assert len(body) == 200 and body.endswith("…")
    assert banner_body(channel("")) == "(no text)"
    assert banner_body(channel("   \n ")) == "(no text)"


def test_body_that_looks_like_an_option_is_neutralised():
    assert not banner_body(channel("-open evil")).startswith("-")
    assert "-open evil" in banner_body(channel("-open evil"))


def test_banner_command_is_argv_only():
    n = Notification(channel("-open x"), "zulip://h/#narrow/x", "mention")
    command = banner_command("terminal-notifier", n)
    assert command[0] == "terminal-notifier"
    assert command[command.index("-open") + 1] == "zulip://h/#narrow/x"
    assert command[command.index("-group") + 1] == "z-iris-work-101"
    assert command[command.index("-title") + 1] == "Ada (#ops > deploys)"
    assert not command[command.index("-message") + 1].startswith("-")
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_output.py -q`
Expected: FAIL, module not found.

- [ ] **Step 3: Implement**

```python
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
        "-title", _safe_argument(banner_title(message)),
        "-message", banner_body(message),
        "-open", notification.url,
        "-group", f"z-iris-{message.server}-{message.id}",
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
```

- [ ] **Step 4: Run to verify pass, then commit**

Run: `uv run pytest -q`
Expected: all pass.

```bash
git add -A && git commit -m "Build sound and banner commands with real and dry-run output."
```

### Task 7: Streaming from a server

**Files:**

- Create: `src/z_iris/stream.py`, `src/z_iris/__main__.py`
- Test: `tests/test_stream.py`

**Interfaces:**

- Consumes: `Config`, `ServerConfig`, `Pipeline`, `MuteState`, `Output`.
- Produces: `host_of(site: str) -> str`; `StatusBoard` with `set(name: str, text: str)` and `snapshot() -> dict[str, str]`; `Controls` with `paused: threading.Event`; `ServerStream(server, config, output, controls, board)` a daemon `Thread` with `stop()`; CLI `z-iris [--config PATH] [--dry-run] [--headless]` and `z-iris probe`.

- [ ] **Step 1: Write the failing tests**

```python
import threading
import time
from pathlib import Path

from z_iris.config import Config, ServerConfig
from z_iris.stream import Controls, ServerStream, StatusBoard, host_of


def test_host_of():
    assert host_of("https://Chat.Example.com/") == "chat.example.com"
    assert host_of("http://localhost:9991") == "localhost:9991"


def test_status_board_snapshot_is_a_copy():
    board = StatusBoard()
    board.set("a", "connected")
    snap = board.snapshot()
    board.set("a", "error")
    assert snap == {"a": "connected"}


class FakeClient:
    base_url = "https://chat.example.com/"

    def __init__(self, scripts):
        self.scripts = list(scripts)
        self.registered = 0
        self.calls = 0

    def register(self, **kwargs):
        self.registered += 1
        return {"result": "success", "queue_id": f"q{self.registered}",
                "last_event_id": -1, "user_id": 5,
                "subscriptions": [], "user_topics": []}

    def get_events(self, queue_id, last_event_id):
        self.calls += 1
        if not self.scripts:
            time.sleep(0.01)
            return {"result": "success", "events": []}
        step = self.scripts.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def dm_event(event_id):
    return {"id": event_id, "type": "message", "flags": [], "message": {
        "id": 40 + event_id, "type": "private",
        "display_recipient": [{"id": 9}, {"id": 5}],
        "sender_id": 9, "sender_full_name": "Ada", "content": "yo"}}


class Collect:
    def __init__(self, want):
        self.want = want
        self.items = []
        self.done = threading.Event()

    def deliver(self, notification):
        self.items.append(notification)
        if len(self.items) >= self.want:
            self.done.set()


def make_stream(client, output, controls=None):
    config = Config(servers=(ServerConfig("w", Path("/x")),))
    stream = ServerStream(config.servers[0], config, output,
                          controls or Controls(), StatusBoard(),
                          client_factory=lambda path: client)
    stream.backoff_start = 0.01
    return stream


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.005)


def test_events_flow_and_queue_expiry_reregisters():
    client = FakeClient([
        {"result": "success", "events": [dm_event(0)]},
        {"result": "error", "code": "BAD_EVENT_QUEUE_ID", "msg": "expired"},
        {"result": "success", "events": [dm_event(1)]},
    ])
    out = Collect(want=2)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert client.registered == 2
    assert [n.message.id for n in out.items] == [40, 41]


def test_errors_are_reported_and_streaming_resumes():
    client = FakeClient([
        RuntimeError("network down"),
        {"result": "success", "events": [dm_event(0)]},
    ])
    out = Collect(want=1)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert client.registered == 2
    assert stream.board.snapshot()["w"] == "connected"


def test_pause_suppresses_delivery_until_resumed():
    client = FakeClient([{"result": "success", "events": [dm_event(0)]}])
    controls = Controls()
    controls.paused.set()
    out = Collect(want=1)
    stream = make_stream(client, out, controls)
    stream.start()
    wait_until(lambda: client.calls >= 3)  # the paused event was consumed
    assert out.items == []
    controls.paused.clear()
    client.scripts.append({"result": "success", "events": [dm_event(1)]})
    assert out.done.wait(5)
    stream.stop()
    assert [n.message.id for n in out.items] == [41]
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_stream.py -q`
Expected: FAIL, module not found.

- [ ] **Step 3: Implement `stream.py`**

```python
"""Stream messages from one Zulip server and hand notifications to an Output."""

from __future__ import annotations

import threading
from urllib.parse import urlparse

from z_iris.config import Config, ServerConfig
from z_iris.mutes import MuteState
from z_iris.output import Output
from z_iris.pipeline import Pipeline

EVENT_TYPES = ["message", "subscription", "user_topic", "muted_topics"]


def host_of(site: str) -> str:
    return urlparse(site).netloc.lower()


class StatusBoard:
    """Thread-safe per-server status text for the menubar."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._status: dict[str, str] = {}

    def set(self, name: str, text: str) -> None:
        with self._lock:
            self._status[name] = text

    def snapshot(self) -> dict[str, str]:
        with self._lock:
            return dict(self._status)


class Controls:
    def __init__(self) -> None:
        self.paused = threading.Event()


def _default_client(zuliprc):
    import zulip

    return zulip.Client(config_file=str(zuliprc))


class ServerStream(threading.Thread):
    backoff_start = 1.0
    backoff_max = 60.0

    def __init__(
        self,
        server: ServerConfig,
        config: Config,
        output: Output,
        controls: Controls,
        board: StatusBoard,
        client_factory=_default_client,
    ) -> None:
        super().__init__(daemon=True, name=f"z-iris-{server.name}")
        self.server = server
        self.config = config
        self.output = output
        self.controls = controls
        self.board = board
        self.client_factory = client_factory
        self._stop_requested = threading.Event()

    def stop(self) -> None:
        self._stop_requested.set()

    def run(self) -> None:
        backoff = self.backoff_start
        self.board.set(self.server.name, "connecting")
        while not self._stop_requested.is_set():
            try:
                self._session()
                backoff = self.backoff_start
            except Exception as error:  # noqa: BLE001 - keep streaming whatever happens
                self.board.set(self.server.name, f"error: {error}")
                self._stop_requested.wait(backoff)
                backoff = min(backoff * 2, self.backoff_max)

    def _session(self) -> None:
        client = self.client_factory(self.server.zuliprc)
        registered = client.register(event_types=EVENT_TYPES, apply_markdown=False)
        if registered.get("result") != "success":
            raise RuntimeError(registered.get("msg", "register failed"))

        pipeline = Pipeline(
            self.server.name,
            host_of(client.base_url),
            registered["user_id"],
            MuteState.from_register(registered),
            self.config.notify_channel_messages,
        )
        queue_id = registered["queue_id"]
        last_event_id = registered["last_event_id"]
        self.board.set(self.server.name, "connected")

        while not self._stop_requested.is_set():
            response = client.get_events(queue_id=queue_id, last_event_id=last_event_id)
            if response.get("result") != "success":
                if response.get("code") == "BAD_EVENT_QUEUE_ID":
                    return  # the queue expired; register a new one
                raise RuntimeError(response.get("msg", "get_events failed"))
            self.board.set(self.server.name, "connected")
            for event in response["events"]:
                last_event_id = max(last_event_id, event.get("id", last_event_id))
                notification = pipeline.handle(event)
                if notification is not None and not self.controls.paused.is_set():
                    self.output.deliver(notification)
```

- [ ] **Step 4: Implement `__main__.py`**

```python
"""z-iris command line."""

from __future__ import annotations

import argparse
import sys
import threading
from pathlib import Path

from z_iris.config import ConfigError, DEFAULT_PATH, load_config
from z_iris.output import DryRunOutput, RealOutput
from z_iris.stream import Controls, ServerStream, StatusBoard


def _probe(config) -> int:
    import zulip

    for server in config.servers:
        client = zulip.Client(config_file=str(server.zuliprc))
        reply = client.register(
            event_types=["message", "subscription", "user_topic", "muted_topics"],
            apply_markdown=False,
        )
        print(f"{server.name}: result={reply.get('result')} base_url={client.base_url}")
        if reply.get("result") == "success":
            print("  keys:", ", ".join(sorted(reply)))
            for key in ("subscriptions", "user_topics", "muted_topics"):
                if key in reply:
                    print(f"  {key}: {len(reply[key])}")
            client.deregister(reply["queue_id"])
        else:
            print("  error:", reply.get("msg"))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="z-iris")
    parser.add_argument("--config", type=Path, default=DEFAULT_PATH)
    parser.add_argument("--dry-run", action="store_true",
                        help="print what would notify, play nothing; implies --headless")
    parser.add_argument("--headless", action="store_true", help="no menubar app")
    parser.add_argument("command", nargs="?", choices=["probe"])
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
    except ConfigError as error:
        print(f"z-iris: {error}", file=sys.stderr)
        return 2

    if args.command == "probe":
        return _probe(config)

    controls = Controls()
    board = StatusBoard()
    output = DryRunOutput(config) if args.dry_run else RealOutput(config)
    streams = [ServerStream(s, config, output, controls, board) for s in config.servers]
    for stream in streams:
        stream.start()

    if args.dry_run or args.headless:
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            return 0
        return 0

    from z_iris.menubar import run_menubar

    run_menubar(config, args.config, controls, board)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Run to verify pass**

Run: `uv run pytest -q`
Expected: all pass. If the pause test is flaky, tighten it: assert on `out.items` after unpausing and sending one more event rather than on timing.

- [ ] **Step 6: Probe the real server, then watch it stream**

The user's `~/.zuliprc` exists. Write `~/.config/z-iris/config.toml` from `config.example.toml` pointing at it. Never print or read the zuliprc.

Run: `uv run z-iris probe`
Expected: `result=success`, and the key list. If `user_topics` is absent and `muted_topics` is present, the legacy path is in use and nothing needs to change. If `result=error`, the msg says why. Record the key list in the README under "Verified server shape".

Run: `uv run z-iris --dry-run`, then have the user send a DM or an @-mention to themselves from another client.
Expected: a `[dry-run]` block with the title, the body, an `open zulip://...` line and a sound command. Stop with Ctrl-C.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Stream events per server with reconnect, status and pause."
```

### Task 8: Prove banner click-through

This is the riskiest part of phase 1. Do it before the menubar.

**Files:** none (verification), plus a README note.

- [ ] **Step 1: Install terminal-notifier**

Run: `brew install terminal-notifier`
Expected: `which terminal-notifier` prints a path.

- [ ] **Step 2: Banner appears and click opens a URL**

Run: `terminal-notifier -title "z-iris test" -message "click me" -open "https://example.com"`
Expected: a banner. If none appears, macOS needs notification permission for terminal-notifier in System Settings, Notifications. Clicking the banner opens the page. Report this to the user as an action item if it fails.

- [ ] **Step 3: Custom scheme opens Zulip Desktop**

With the zulip-desktop handler from the other plan built and running (`node --run dev` in a worktree), run:
`terminal-notifier -title "z-iris test" -message "click me" -open "zulip://<your-host>/#narrow/is/starred"`
Expected: clicking focuses Zulip Desktop on that server's starred narrow. If the app is a dev build, the OS may not route the scheme to it. Then test with `open` directly and, failing that, with a packaged build from `node --run pack`.

- [ ] **Step 4: Real banner for a real message**

Run: `uv run z-iris --headless` and have the user @-mention themselves from another client.
Expected: a banner titled with the sender and place, a short sound, and a click that lands on that message. Test one topic with a space, a dot and an accent in its name.

- [ ] **Step 5: Record and commit**

Add the findings (what worked, what needed a permission) to the README under "Click-through". Commit: `git commit -am "Document verified banner click-through."`

### Task 9: Menubar app

**Files:**

- Create: `src/z_iris/menubar.py`

**Interfaces:**

- Consumes: `Config`, `Controls`, `StatusBoard`.
- Produces: `run_menubar(config: Config, config_path: Path, controls: Controls, board: StatusBoard) -> None`.

- [ ] **Step 1: Implement**

```python
"""The z-iris menubar app. No Dock icon and no main window."""

from __future__ import annotations

import subprocess
from pathlib import Path

import rumps
from AppKit import NSApplication, NSApplicationActivationPolicyAccessory

from z_iris.config import Config
from z_iris.stream import Controls, StatusBoard

_ACTIVE_TITLE = "◉"
_PAUSED_TITLE = "◌"


class IrisApp(rumps.App):
    def __init__(
        self, config: Config, config_path: Path, controls: Controls, board: StatusBoard
    ) -> None:
        super().__init__("z-iris", title=_ACTIVE_TITLE, quit_button=None)
        self.controls = controls
        self.board = board
        self.config_path = config_path
        self.server_items = {
            server.name: rumps.MenuItem(f"{server.name}: connecting")
            for server in config.servers
        }
        self.pause_item = rumps.MenuItem("Pause", callback=self.toggle_pause)
        self.menu = [
            *self.server_items.values(),
            None,
            self.pause_item,
            rumps.MenuItem("Open config file", callback=self.open_config),
            None,
            rumps.MenuItem("Quit z-iris", callback=rumps.quit_application),
        ]
        self.refresh_timer = rumps.Timer(self.refresh, 1)
        self.refresh_timer.start()

    def refresh(self, _timer) -> None:
        for name, text in self.board.snapshot().items():
            item = self.server_items.get(name)
            if item is not None:
                item.title = f"{name}: {text}"
        self.title = _PAUSED_TITLE if self.controls.paused.is_set() else _ACTIVE_TITLE

    def toggle_pause(self, sender) -> None:
        if self.controls.paused.is_set():
            self.controls.paused.clear()
            sender.title = "Pause"
        else:
            self.controls.paused.set()
            sender.title = "Resume"
        self.title = _PAUSED_TITLE if self.controls.paused.is_set() else _ACTIVE_TITLE

    def open_config(self, _sender) -> None:
        subprocess.run(["open", str(self.config_path)], check=False)


def run_menubar(
    config: Config, config_path: Path, controls: Controls, board: StatusBoard
) -> None:
    NSApplication.sharedApplication().setActivationPolicy_(
        NSApplicationActivationPolicyAccessory
    )
    IrisApp(config, config_path, controls, board).run()
```

- [ ] **Step 2: Verify by running it**

Run: `uv run z-iris`
Expected: a ◉ icon in the menubar and no Dock icon. The menu lists each server as `name: connected`. Pause turns the icon to ◌ and the item to Resume, and an @-mention while paused produces no banner or sound. Resume restores them. Open config file opens the TOML. Quit exits. If a Dock icon appears, set the policy again inside `IrisApp.__init__` after `super().__init__`, and re-test.

- [ ] **Step 3: Failure modes**

Rename the sox player in config to `nonexistent` and mention yourself. Expected: no crash, a message on stderr, and the banner still appears. Restore it. Point a server at a missing zuliprc. Expected: the menu shows `error: ...` and the app keeps running.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "Add the menubar app with status and pause."
```

### Task 10: Finish documentation

**Files:**

- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Update docs**

README: what z-iris is, requirements (`brew install sox terminal-notifier`, a zuliprc, Zulip Desktop with the `zulip://` handler), setup (`uv sync --python 3.13`, copy `config.example.toml`), usage (`uv run z-iris`, `--dry-run`, `--headless`, `probe`), the notification rules in phase 1 (DMs, mentions, alert words, optional channel messages, muted topics and channels respected), the verified server shape and click-through notes, and the phase 2 and 3 roadmap pointing at `docs/design.md`. CLAUDE.md: commands, module map, constraints, and the open items from the design's risks section.

- [ ] **Step 2: Full test run and commit**

Run: `uv run pytest -q`
Expected: all pass.

```bash
git add -A && git commit -m "Document setup, usage and verified behaviour."
```
