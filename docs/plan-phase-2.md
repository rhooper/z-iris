# z-iris phase 2a: rules, sounds and volume

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (native) or superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Per-rule sounds, volume and banner choices, matched by channel, topic, keyword, mention, DM and group DM, with live config reload.

**Architecture:** A pure `rules` module picks the winning rule for a message. `config` parses `[[rule]]` tables, a master volume and a per-server volume. The pipeline attaches a resolved `Action` (sound, final volume, banner mode, rule name) to each `Notification`, and output obeys it. A `Settings` holder lets the config reload without restarting streams.

**Tech Stack:** Python 3.13, pytest, tomllib, rumps. No new dependencies.

**Spec:** `~/Devel/zulip-desktop/docs/superpowers/specs/2026-10-13-custom-notification-sounds-design.md`, section "Rules (phase 2)".

## Scope

Phase 2a is the engine and the config file. Phase 2b, the settings window, gets its own plan after 2a has run on live traffic, as the user asked. The leading idea for 2b is a localhost-only web page that edits the TOML with comment-preserving writes, because AppKit forms for a rule list are costly. That choice is made in the 2b plan, not here.

Out of scope: repetition, intervals, intensity, batching, quiet hours (phase 3), per-sender DM rules, hot-adding servers (needs a restart).

## Global Constraints

- Sound plays through sox only. Never `afplay` or macOS system sounds.
- Never run a command through a shell. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- Own messages never notify. Muted topics and channels never notify, except a personal @-mention in a muted topic (phase 1 behaviour, keep it).
- Volume is 0 to 100, an integer. Final volume is `rule (or default) x server x master`, each as a percent.
- Precedence: higher `priority` first (default 0), then fixed kind order topic, keyword, mention, channel, group_dm, dm, then file order.
- Tests are TDD: watch each fail first. Run `uv run pytest -q`.

## Review Focus

1. A bad regex in a rule: config load fails with a message naming the rule, never a crash mid-stream.
2. A missing sound file: config load fails naming the rule and path.
3. A config edit that does not parse while running: keep the old settings, show the error in the menu, never stop streaming.
4. A `[[rule]]` for a channel that is muted: still silent (mute wins, except personal mention).
5. Volume math at the edges: 0 anywhere gives silence (no `play` spawned), values never exceed 100.

## Interfaces

```python
# rules.py
@dataclass(frozen=True)
class Rule:
    name: str; kind: str; channel: str | None; pattern: re.Pattern | None
    server: str | None; sound: str | None; volume: int | None
    banner: str | None; priority: int; index: int
def pick_rule(rules: Sequence[Rule], message: Message) -> Rule | None

# config.py (additions)
Config.master_volume: int; Config.rules: tuple[Rule, ...]; ServerConfig.volume: int
@dataclass(frozen=True)
class Action: sound: str; volume: int; banner: str; rule: str | None
def resolve_action(config: Config, server: str, rule: Rule | None) -> Action

# pipeline.py
Notification(message, url, reason, action: Action)
Pipeline(server, host, self_id, mutes, settings: Settings)

# settings.py
class Settings: .config (property); .reload() -> str | None   # error text or None
```

---

### Task 1: Rule matching and precedence

**Files:** Create `src/z_iris/rules.py`, `tests/test_rules.py`

- [ ] **Step 1: Failing tests** in `tests/test_rules.py`. Build messages with `message_from_event` (copy the `event()` helper from `tests/test_pipeline.py`, add a `dm_event(recipients)` helper). Cases:
  - `channel` rule matches only that channel name, case-insensitively.
  - `topic` rule: regex `search`, case-insensitive, optionally limited by `channel`.
  - `keyword` regex hits message content only.
  - `mention` matches `mentioned` or `wildcard_mentioned` flags, not `has_alert_word`.
  - `dm` matches a one-to-one DM; `group_dm` matches 3 or more participants (`len(dm_user_ids) > 1`); neither matches a channel message.
  - `server` limits a rule to that server name.
  - Precedence: a topic rule beats a channel rule on the same message; `priority=5` on the channel rule flips it; equal everything goes to the earlier `index`.
  - No match returns `None`.
- [ ] **Step 2:** `uv run pytest tests/test_rules.py -q`. Expected: FAIL, no module `z_iris.rules`.
- [ ] **Step 3: Implement.**

```python
"""Pick the rule that decides how a message sounds."""
from __future__ import annotations
import re
from collections.abc import Sequence
from dataclasses import dataclass
from z_iris.message import Message

KINDS = ("topic", "keyword", "mention", "channel", "group_dm", "dm")
_RANK = {kind: rank for rank, kind in enumerate(KINDS)}

@dataclass(frozen=True)
class Rule:
    name: str
    kind: str
    channel: str | None
    pattern: re.Pattern | None
    server: str | None
    sound: str | None
    volume: int | None
    banner: str | None
    priority: int
    index: int

def _matches(rule: Rule, message: Message) -> bool:
    if rule.server is not None and rule.server != message.server:
        return False
    if rule.kind == "channel":
        return message.kind == "channel" and (message.channel_name or "").lower() == (rule.channel or "").lower()
    if rule.kind == "topic":
        if message.kind != "channel":
            return False
        if rule.channel is not None and (message.channel_name or "").lower() != rule.channel.lower():
            return False
        return bool(rule.pattern and rule.pattern.search(message.topic or ""))
    if rule.kind == "keyword":
        return bool(rule.pattern and rule.pattern.search(message.content))
    if rule.kind == "mention":
        return message.is_mention or message.is_wildcard_mention
    if rule.kind == "dm":
        return message.kind == "dm" and len(message.dm_user_ids) == 1
    if rule.kind == "group_dm":
        return message.kind == "dm" and len(message.dm_user_ids) > 1
    return False

def pick_rule(rules: Sequence[Rule], message: Message) -> Rule | None:
    hits = [rule for rule in rules if _matches(rule, message)]
    if not hits:
        return None
    return min(hits, key=lambda rule: (-rule.priority, _RANK[rule.kind], rule.index))
```

- [ ] **Step 4:** run again. Expected: PASS.
- [ ] **Step 5: Commit** `rules: Pick the winning rule by priority and kind order.`

### Task 2: Config, volumes and action resolution

**Files:** Modify `src/z_iris/config.py`, `tests/test_config.py`; modify `config.example.toml`

- [ ] **Step 1: Failing tests** (extend `tests/test_config.py`):
  - `[[rule]]` with `match = "keyword"`, `keyword = "outage"` parses to a `Rule` with a compiled case-insensitive pattern and `index` in file order.
  - Errors, each a `ConfigError` whose text contains the rule name: unknown `match`; missing `channel` on a channel rule; missing `topic` on a topic rule; bad regex; volume 101 or non-int; `banner` not in `full`, `title`, `off`; unknown `server` name; `sound` path that does not exist (not for `synth` or `none`).
  - `master_volume` under `[defaults]` (default 100) and `volume` per `[[server]]` (default 100), range checked.
  - `resolve_action`: default sound and volume 60 with master 100 and server 100 gives 60; rule volume 80, server 50, master 50 gives 20 (`80*50*50/10000`, rounded); rule sound `none` gives sound `none`; no rule gives defaults and banner `full`.
- [ ] **Step 2:** run. Expected: FAIL on missing fields.
- [ ] **Step 3: Implement.** Add `volume: int = 100` to `ServerConfig`, `master_volume: int = 100` and `rules: tuple[Rule, ...] = ()` to `Config`. Add a shared `_percent(value, label)` validator used by every volume. Add `_rules(data, server_names)` that builds `Rule`s, wrapping `re.error` into `ConfigError(f"rule {name!r}: ...")`, and checks `Path(sound).expanduser().exists()` for file sounds. Add:

```python
@dataclass(frozen=True)
class Action:
    sound: str
    volume: int
    banner: str
    rule: str | None

def resolve_action(config: Config, server: str, rule: Rule | None) -> Action:
    server_volume = next((s.volume for s in config.servers if s.name == server), 100)
    base = rule.volume if rule and rule.volume is not None else config.volume
    sound = rule.sound if rule and rule.sound is not None else config.sound
    banner = rule.banner if rule and rule.banner is not None else "full"
    final = round(base * server_volume * config.master_volume / 10000)
    return Action(sound, final, banner, rule.name if rule else None)
```

  Rule `sound` values are stored expanded (`str(Path(...).expanduser())`) except `synth` and `none`.
- [ ] **Step 4:** run. Expected: PASS, whole suite green.
- [ ] **Step 5:** Update `config.example.toml` with a commented `[[rule]]` sample and `master_volume`. **Commit** `config: Parse rules, master volume and per-server volume.`

### Task 3: Pipeline applies rules

**Files:** Create `src/z_iris/settings.py`; modify `src/z_iris/pipeline.py`, `src/z_iris/policy.py`, `src/z_iris/stream.py`, `tests/test_pipeline.py`, `tests/test_policy.py`

- [ ] **Step 1: Failing tests.**
  - `Settings(config)` exposes `.config`; `Settings.reload()` is added in Task 5, so here it is a plain holder.
  - A channel message in an unmuted channel with a matching `channel` rule notifies even when `notify_channel_messages` is false, with `reason == "rule"` and `action.rule` set.
  - A matching rule on a muted topic stays silent. A personal mention in that muted topic still notifies.
  - Own messages stay silent even with a matching rule.
  - A DM with a `dm` rule carries that rule's sound and final volume.
  - A message with no rule behaves as in phase 1 and carries default action.
  - A rule with `sound = "none"` and `banner = "off"` produces no notification at all (fully silent rule is a way to ignore).
- [ ] **Step 2:** run. Expected: FAIL.
- [ ] **Step 3: Implement.** `decide` keeps its phase 1 job but returns early reasons for own and muted. Pipeline order: own, muted (unless personal mention), then `pick_rule`; if a rule picks and it is not fully silent, notify with reason `rule`; if fully silent, return `None`; otherwise fall back to `decide`'s phase 1 notify and reasons. `Pipeline` reads `self.settings.config` on every event, so a reload takes effect on the next message. `stream.py` passes the shared `Settings`. Update call sites in tests.
- [ ] **Step 4:** run. Expected: PASS, suite green.
- [ ] **Step 5: Commit** `pipeline: Apply rules and attach a resolved action.`

### Task 4: Output obeys the action

**Files:** Modify `src/z_iris/output.py`, `tests/test_output.py`

- [ ] **Step 1: Failing tests.**
  - `RealOutput.deliver` with action volume 0 or sound `none` spawns no player; the banner still spawns.
  - Action `banner = "off"` spawns no banner; sound still plays.
  - `banner = "title"` builds a banner whose body is empty-safe placeholder `New message` and never carries message text.
  - Action sound path and final volume reach `sound_command`.
  - `DryRunOutput` prints the rule name (or `default`), sound and volume.
  - Inject a fake spawner so tests spawn nothing (give `RealOutput` a `spawn` parameter defaulting to `_spawn`).
- [ ] **Step 2:** run. Expected: FAIL.
- [ ] **Step 3: Implement** the above. `banner_command` takes the banner mode. Keep `_safe_argument` on every text argument.
- [ ] **Step 4:** run. Expected: PASS.
- [ ] **Step 5: Commit** `output: Honour per-rule sound, volume and banner.`

### Task 5: Live reload

**Files:** Modify `src/z_iris/settings.py`, `src/z_iris/menubar.py`, `src/z_iris/__main__.py`, `tests/test_settings.py` (new)

- [ ] **Step 1: Failing tests** with a temp config file:
  - `reload()` after a valid edit swaps `.config` and returns `None`.
  - After an invalid edit it returns the error text, keeps the old config, and a later valid edit recovers.
  - `reload()` returns `None` and does nothing when the file mtime has not changed (`reload(force=True)` overrides).
  - Server list changes are ignored with the message `servers changed, restart z-iris` while the other settings still apply.
- [ ] **Step 2:** run. Expected: FAIL.
- [ ] **Step 3: Implement.** `Settings(path)` loads on init, guards swaps with a lock, and tracks mtime. The menubar refresh timer calls `reload()` each second, shows the error as a disabled menu item at the top (cleared on success), and adds a `Reload config` item that forces it. `__main__` builds one `Settings` and gives it to streams, output and the menubar. Output reads `settings.config` for the player and notifier on each delivery.
- [ ] **Step 4:** run. Expected: PASS, suite green.
- [ ] **Step 5: Commit** `settings: Reload the config live and keep the old one on error.`

### Task 6: Documentation and live check

**Files:** Modify `README.md`, `CLAUDE.md`, `docs/design.md`

- [ ] **Step 1:** Document the rule syntax with one example per kind, the precedence rule, and the volume formula. Replace the CLAUDE.md line "Phase 1 only: no rules..." with "Phase 2a: rules, sounds and volume. No repetition, intervals or batching yet." Add `rules`, `settings` to the module list.
- [ ] **Step 2:** Run `uv run pytest -q`. Expected: all pass.
- [ ] **Step 3: Commit** `docs: Document rules and volume.`
- [ ] **Step 4 (user):** add two rules to `~/.config/z-iris/config.toml`, run `uv run z-iris --dry-run` for a minute, and check the printed rule, sound and volume against real traffic.
