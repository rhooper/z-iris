"""Turn raw Zulip events into notifications."""

from __future__ import annotations

from dataclasses import dataclass

from z_iris.config import Action, resolve_action
from z_iris.message import Message, message_from_event
from z_iris.mutes import MuteState
from z_iris.narrow import narrow_url
from z_iris.policy import blocked, decide
from z_iris.rules import pick_rule
from z_iris.settings import Settings


@dataclass(frozen=True)
class Notification:
    message: Message
    url: str
    reason: str
    action: Action


class Pipeline:
    def __init__(
        self,
        server: str,
        host: str,
        self_id: int,
        mutes: MuteState,
        settings: Settings,
    ) -> None:
        self.server = server
        self.host = host
        self.self_id = self_id
        self.mutes = mutes
        self.settings = settings

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

        if blocked(message, self.mutes, self.self_id) is not None:
            return None

        config = self.settings.config
        rule = pick_rule(config.rules, message)
        if rule is not None:
            action = resolve_action(config, self.server, rule)
            silent = action.banner == "off" and (
                action.sound == "none" or action.volume == 0
            )
            # A rule that silences a channel must not swallow a personal ping.
            if not silent:
                return Notification(message, narrow_url(message), "rule", action)
            if not message.is_mention:
                return None

        decision = decide(
            message, self.mutes, self.self_id, config.notify_channel_messages
        )
        if not decision.notify:
            return None
        return Notification(
            message,
            narrow_url(message),
            decision.reason,
            resolve_action(config, self.server, None),
        )
