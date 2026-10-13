"""Track which channels and topics the user has muted."""

from __future__ import annotations

_MUTED, _UNMUTED, _FOLLOWED = 1, 2, 3


class MuteState:
    def __init__(self) -> None:
        self._muted_channels: set[int] = set()
        self._channel_ids_by_name: dict[str, int] = {}
        self._topic_policy: dict[tuple[int, str], int] = {}
        # Topics that came from the legacy muted_topics list, so a new legacy
        # list can replace them without touching user_topic state.
        self._legacy_topics: set[tuple[int, str]] = set()

    @classmethod
    def from_register(cls, response: dict) -> MuteState:
        state = cls()
        for subscription in response.get("subscriptions", ()):
            state._add_subscription(subscription)
        for entry in response.get("user_topics", ()):
            state._set_policy(
                entry["stream_id"], entry["topic_name"], entry["visibility_policy"]
            )
        state._set_legacy_muted_topics(response.get("muted_topics", ()))
        return state

    def is_muted(self, channel_id: int, topic: str) -> bool:
        policy = self._topic_policy.get((channel_id, topic.lower()), 0)
        if policy == _MUTED:
            return True
        if policy in (_UNMUTED, _FOLLOWED):
            return False
        return channel_id in self._muted_channels

    def apply(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "subscription":
            self._apply_subscription(event)
        elif kind == "user_topic":
            self._set_policy(
                event["stream_id"], event["topic_name"], event["visibility_policy"]
            )
        elif kind == "muted_topics":
            self._set_legacy_muted_topics(event.get("muted_topics", ()))

    def _add_subscription(self, subscription: dict) -> None:
        channel_id = subscription["stream_id"]
        self._channel_ids_by_name[subscription.get("name", "")] = channel_id
        if subscription.get("is_muted"):
            self._muted_channels.add(channel_id)
        else:
            self._muted_channels.discard(channel_id)

    def _apply_subscription(self, event: dict) -> None:
        op = event.get("op")
        if op == "add":
            for subscription in event.get("subscriptions", ()):
                self._add_subscription(subscription)
        elif op == "remove":
            for subscription in event.get("subscriptions", ()):
                self._muted_channels.discard(subscription["stream_id"])
        elif op == "update" and event.get("property") == "is_muted":
            if event["value"]:
                self._muted_channels.add(event["stream_id"])
            else:
                self._muted_channels.discard(event["stream_id"])

    def _set_policy(self, channel_id: int, topic: str, policy: int) -> None:
        key = (channel_id, topic.lower())
        self._legacy_topics.discard(key)
        if policy == 0:
            self._topic_policy.pop(key, None)
        else:
            self._topic_policy[key] = policy

    def _set_legacy_muted_topics(self, entries) -> None:
        for key in self._legacy_topics:
            self._topic_policy.pop(key, None)
        self._legacy_topics = set()
        for channel_name, topic, *_ in entries:
            channel_id = self._channel_ids_by_name.get(channel_name)
            if channel_id is None:
                continue
            key = (channel_id, topic.lower())
            self._topic_policy[key] = _MUTED
            self._legacy_topics.add(key)
