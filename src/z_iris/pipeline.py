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
