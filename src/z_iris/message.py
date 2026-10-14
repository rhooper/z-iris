"""A Zulip message event, reduced to the fields z-iris needs."""

from __future__ import annotations

from dataclasses import dataclass


_WILDCARD_FLAGS = frozenset(
    {"wildcard_mentioned", "stream_wildcard_mentioned", "topic_wildcard_mentioned"}
)


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
        # Servers send the new per-kind flags and, for older clients, the first.
        return bool(self.flags & _WILDCARD_FLAGS)

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
