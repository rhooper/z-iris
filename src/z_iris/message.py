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
    avatar_url: str | None = None  # the sender's avatar as the server gave it
    dm_names: tuple[str, ...] = ()  # full names in dm_user_ids order; "" if unknown

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
        "avatar_url": raw.get("avatar_url"),
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

    names = {person["id"]: person.get("full_name", "") for person in raw["display_recipient"]}
    others = sorted(set(names) - {self_id})
    ids = tuple(others) or (self_id,)
    return Message(
        **common,
        kind="dm",
        channel_id=None,
        channel_name=None,
        topic=None,
        dm_user_ids=ids,
        dm_names=tuple(names.get(i, "") for i in ids),
    )
