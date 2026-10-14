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
    summary: str | None = None  # a batch summary's heading, e.g. "3 new in #ops"


@dataclass(frozen=True)
class Verdict:
    """What would happen to a message, and why. Used by dry runs and previews."""

    notification: Notification | None
    why: str
    rule_index: int | None = None


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

        return self.evaluate(message).notification

    def evaluate(self, message: Message) -> Verdict:
        reason = blocked(message, self.mutes, self.self_id)
        if reason is not None:
            return Verdict(None, reason)

        config = self.settings.config
        rule = pick_rule(config.rules, message)
        if rule is not None:
            action = resolve_action(config, self.server, rule)
            silent = action.banner == "off" and (
                action.sound == "none" or action.volume == 0
            )
            # A rule that silences a channel must not swallow a personal ping.
            if not silent:
                notification = Notification(message, narrow_url(message), "rule", action)
                return Verdict(notification, "rule", rule.index)
            if not message.is_mention:
                return Verdict(None, "silenced by rule", rule.index)

        decision = decide(
            message, self.mutes, self.self_id, config.notify_channel_messages
        )
        if not decision.notify:
            return Verdict(None, decision.reason)
        notification = Notification(
            message,
            narrow_url(message),
            decision.reason,
            resolve_action(config, self.server, None),
        )
        return Verdict(notification, decision.reason)
