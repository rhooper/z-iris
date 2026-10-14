"""Decide whether a message deserves a notification."""

from __future__ import annotations

from dataclasses import dataclass

from z_iris.message import Message
from z_iris.mutes import MuteState


@dataclass(frozen=True)
class Decision:
    notify: bool
    reason: str


def blocked(message: Message, mutes: MuteState, self_id: int) -> str | None:
    """Why a message must stay silent whatever any rule says, or None."""
    if message.sender_id == self_id:
        return "own message"
    if (
        message.kind == "channel"
        and mutes.is_muted(message.channel_id or 0, message.topic or "")
        and not message.is_mention
    ):
        return "muted"
    return None


def decide(
    message: Message, mutes: MuteState, self_id: int, notify_channel_messages: bool
) -> Decision:
    reason = blocked(message, mutes, self_id)
    if reason is not None:
        return Decision(False, reason)

    if message.kind == "dm":
        return Decision(True, "dm")
    if message.is_mention or message.is_wildcard_mention:
        return Decision(True, "mention")
    if message.has_alert_word:
        return Decision(True, "alert word")
    if notify_channel_messages:
        return Decision(True, "channel")
    return Decision(False, "channel messages not enabled")
