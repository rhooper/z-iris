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


def _same(a: str | None, b: str | None) -> bool:
    return (a or "").lower() == (b or "").lower()


def _matches(rule: Rule, message: Message) -> bool:
    if rule.server is not None and rule.server != message.server:
        return False
    if rule.kind == "channel":
        return message.kind == "channel" and _same(message.channel_name, rule.channel)
    if rule.kind == "topic":
        if message.kind != "channel":
            return False
        if rule.channel is not None and not _same(message.channel_name, rule.channel):
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
