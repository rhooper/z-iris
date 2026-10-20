"""Who a notification is from, for macOS communication notifications.

macOS shows the sender's picture as the main icon. For one person it uses the
sender's display name as the title, so `name` is today's whole title
("Ada (#ops > deploys)"). For a group it shows the sender's name and then the
group's name, so a group is name "Ada" with group_name "group", which reads
like today's "Ada (group)". See docs/sender-icons-spike.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from z_iris.media import MessageImages
from z_iris.message import Message

GROUP_NAME = "group"


@dataclass(frozen=True)
class Sender:
    handle: str  # zulip:<server>:<user id>
    name: str  # what macOS shows as the sender
    avatar: Path | None
    picture: Path | None  # the message's own image, the thumbnail
    conversation: str
    group_name: str | None = None  # set for group DMs only
    members: tuple[tuple[str, str], ...] = ()  # (handle, name) of a group's people

    def to_json(self) -> dict:
        return {
            "handle": self.handle, "name": self.name,
            "avatar": str(self.avatar) if self.avatar else None,
            "picture": str(self.picture) if self.picture else None,
            "conversation": self.conversation, "group_name": self.group_name,
            "members": [list(member) for member in self.members],
        }

    @classmethod
    def from_json(cls, data: object) -> Sender | None:
        """The Sender, or None for anything malformed."""
        if not isinstance(data, dict):
            return None
        text = [data.get(key) for key in ("handle", "name", "conversation")]
        if not all(isinstance(value, str) for value in text):
            return None
        members = data.get("members") or []
        if not isinstance(members, list) or not all(
            isinstance(m, list) and len(m) == 2 and all(isinstance(x, str) for x in m)
            for m in members
        ):
            return None
        paths = []
        for key in ("avatar", "picture"):
            value = data.get(key)
            if value is not None and not isinstance(value, str):
                return None
            paths.append(Path(value) if value else None)
        group = data.get("group_name")
        if group is not None and not isinstance(group, str):
            return None
        return cls(text[0], text[1], paths[0], paths[1], text[2], group,
                   tuple((m[0], m[1]) for m in members))


def _handle(message: Message, user_id: int) -> str:
    return f"zulip:{message.server}:{user_id}"


def sender_for(message: Message, title: str, images: MessageImages) -> Sender | None:
    """The sender for a message's notification. None when there is no face to
    show (a one-to-one message without an avatar): the plain notification."""
    handle = _handle(message, message.sender_id)
    if message.kind == "dm" and len(message.dm_user_ids) > 1:
        names = message.dm_names or ("",) * len(message.dm_user_ids)
        members = tuple(
            (_handle(message, ident), name) for ident, name in zip(message.dm_user_ids, names)
        )
        conversation = f"{message.server}:dm:" + ",".join(map(str, message.dm_user_ids))
        return Sender(handle, message.sender_name, images.avatar, images.picture,
                      conversation, GROUP_NAME, members)
    if images.avatar is None:
        return None
    if message.kind == "channel":
        conversation = f"{message.server}:channel:{message.channel_id}:{message.topic}"
    else:
        conversation = f"{message.server}:dm:" + ",".join(map(str, message.dm_user_ids))
    return Sender(handle, title, images.avatar, images.picture, conversation)
