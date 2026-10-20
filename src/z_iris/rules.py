"""Pick the rule that decides how a message sounds."""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass, field

from z_iris.message import Message

KINDS = ("topic", "keyword", "mention", "wildcard", "alert_word", "channel", "group_dm", "dm")
_RANK = {kind: rank for rank, kind in enumerate(KINDS)}


_KIND_LABELS = {
    "topic": "Topic", "keyword": "Keyword", "mention": "Mention", "wildcard": "Wildcard mention",
    "alert_word": "Alert word", "channel": "Channel", "group_dm": "Group DM", "dm": "Direct message",
}


def compile_channel(source: str) -> re.Pattern:
    """A channel entry is a regular expression for the whole channel name, so
    a plain name ("ops") means exactly that channel. Raises re.error."""
    return re.compile(source, re.IGNORECASE)


@dataclass(frozen=True)
class Rule:
    description: str | None  # optional; the label falls back to what it matches
    kind: str
    channels: tuple[str, ...] | str | None  # channel names or patterns; a str or None is normalised
    pattern: re.Pattern | None
    server: str | None
    sound: str | None
    volume: int | None
    banner: str | None
    priority: int
    index: int
    enabled: bool = True
    # Optional per-rule overrides of visual and phase 3 settings; see config.BEHAVIOUR.
    behaviour: dict = field(default_factory=dict, compare=False)
    channel_patterns: tuple[re.Pattern, ...] = field(init=False, compare=False, repr=False)

    def __post_init__(self) -> None:
        channels = self.channels
        if channels is None:
            channels = ()
        elif isinstance(channels, str):
            channels = (channels,)
        object.__setattr__(self, "channels", tuple(channels))
        object.__setattr__(
            self, "channel_patterns", tuple(compile_channel(c) for c in self.channels)
        )

    @property
    def label(self) -> str:
        """The description, else what the rule matches ("Channel #ops, #deploys")."""
        if self.description:
            return self.description
        kind = _KIND_LABELS[self.kind]
        where = ", ".join(f"#{c}" for c in self.channels)
        if self.kind == "channel":
            return f"{kind} {where}"
        if self.kind in ("topic", "keyword") and self.pattern is not None:
            text = f"{kind} /{self.pattern.pattern}/"
            return f"{text} in {where}" if where else text
        return kind


def _in_channels(rule: Rule, channel: str | None) -> bool:
    return any(p.fullmatch(channel or "") for p in rule.channel_patterns)


def _matches(rule: Rule, message: Message) -> bool:
    if rule.server is not None and rule.server != message.server:
        return False
    if rule.kind == "channel":
        return message.kind == "channel" and _in_channels(rule, message.channel_name)
    if rule.kind == "topic":
        if message.kind != "channel":
            return False
        if rule.channels and not _in_channels(rule, message.channel_name):
            return False
        return bool(rule.pattern and rule.pattern.search(message.topic or ""))
    if rule.kind == "keyword":
        return bool(rule.pattern and rule.pattern.search(message.content))
    if rule.kind == "mention":
        return message.is_mention
    if rule.kind == "wildcard":
        return message.is_wildcard_mention
    if rule.kind == "alert_word":
        return message.has_alert_word
    if rule.kind == "dm":
        return message.kind == "dm" and len(message.dm_user_ids) == 1
    if rule.kind == "group_dm":
        return message.kind == "dm" and len(message.dm_user_ids) > 1
    return False


def pick_rule(rules: Sequence[Rule], message: Message) -> Rule | None:
    hits = [rule for rule in rules if rule.enabled and _matches(rule, message)]
    if not hits:
        return None
    return min(hits, key=lambda rule: (-rule.priority, _RANK[rule.kind], rule.index))
