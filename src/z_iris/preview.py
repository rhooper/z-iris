"""Run recent Zulip messages through a draft config, to show what rules do."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from z_iris.config import ServerConfig
from z_iris.message import Message, message_from_event
from z_iris.mutes import MuteState
from z_iris.pipeline import Pipeline
from z_iris.settings import Settings
from z_iris.stream import _default_client, host_of

FETCH_COUNT = 1000
MENTION_COUNT = 50
SNIPPET = 200


@dataclass
class _Snapshot:
    taken: float
    host: str
    self_id: int
    mutes: MuteState
    messages: list[dict]


def _where(message: Message) -> str:
    if message.kind == "channel":
        return f"#{message.channel_name} > {message.topic}"
    return "Group DM" if len(message.dm_user_ids) > 1 else "DM"


def _snippet(content: str) -> str:
    text = " ".join(content.split())
    return text if len(text) <= SNIPPET else text[: SNIPPET - 1] + "…"


class PreviewSource:
    """Fetches recent messages once, then evaluates any draft against them."""

    def __init__(
        self,
        client_factory: Callable[[Path], object] = _default_client,
        now: Callable[[], float] = time.monotonic,
        ttl: float = 60.0,
    ) -> None:
        self.client_factory = client_factory
        self.now = now
        self.ttl = ttl
        self._cache: dict[str, _Snapshot] = {}
        self._lock = threading.Lock()

    def _fetch(self, server: ServerConfig) -> _Snapshot:
        client = self.client_factory(server.zuliprc)
        registered = client.register(
            event_types=["subscription", "user_topic", "muted_topics"],
            apply_markdown=False,
        )
        if registered.get("result") != "success":
            raise RuntimeError(registered.get("msg", "register failed"))
        try:
            mutes = MuteState.from_register(registered)
        finally:
            client.deregister(registered["queue_id"])
        profile = client.get_profile()
        if profile.get("result") != "success":
            raise RuntimeError(profile.get("msg", "could not fetch own profile"))
        reply = client.get_messages(
            {
                "anchor": "newest",
                "num_before": FETCH_COUNT,
                "num_after": 0,
                "apply_markdown": False,
            }
        )
        if reply.get("result") != "success":
            raise RuntimeError(reply.get("msg", "could not fetch messages"))
        messages = {m["id"]: m for m in reply["messages"] if "id" in m}
        # Mentions are rare, so the recent window may hold none. Fetch the
        # latest ones separately so a mention rule has something to show.
        mentioned = client.get_messages(
            {
                "anchor": "newest",
                "num_before": MENTION_COUNT,
                "num_after": 0,
                "apply_markdown": False,
                "narrow": [{"operator": "is", "operand": "mentioned"}],
            }
        )
        if mentioned.get("result") == "success":
            for message in mentioned["messages"]:
                if "id" in message:
                    messages.setdefault(message["id"], message)
        ordered = [messages[key] for key in sorted(messages)]
        return _Snapshot(
            self.now(), host_of(client.base_url), profile["user_id"], mutes, ordered
        )

    def _snapshot(self, server: ServerConfig, refresh: bool) -> _Snapshot:
        cached = self._cache.get(server.name)
        if cached and not refresh and self.now() - cached.taken < self.ttl:
            return cached
        snapshot = self._fetch(server)
        self._cache[server.name] = snapshot
        return snapshot

    def preview(self, draft: Settings, refresh: bool = False) -> dict:
        servers = []
        with self._lock:
            for server in draft.config.servers:
                try:
                    snapshot = self._snapshot(server, refresh)
                except Exception as error:
                    servers.append(
                        {"name": server.name, "error": str(error), "fetched": 0,
                         "messages": []}
                    )
                    continue
                servers.append(self._evaluate(server, snapshot, draft))
        return {"servers": servers}

    def _evaluate(self, server: ServerConfig, snapshot: _Snapshot, draft: Settings) -> dict:
        pipeline = Pipeline(
            server.name, snapshot.host, snapshot.self_id, snapshot.mutes, draft
        )
        entries = []
        for raw in reversed(snapshot.messages):  # newest first
            try:
                message = message_from_event(
                    server.name, snapshot.host, snapshot.self_id,
                    {"message": raw, "flags": raw.get("flags", [])},
                )
            except (KeyError, TypeError):
                continue
            verdict = pipeline.evaluate(message)
            entry = {
                "id": message.id,
                "sender": message.sender_name,
                "where": _where(message),
                "text": _snippet(message.content),
                "why": verdict.why,
                "rule_index": verdict.rule_index,
                "notify": verdict.notification is not None,
                "sound": None,
                "volume": None,
            }
            if verdict.notification is not None:
                action = verdict.notification.action
                entry["sound"] = (
                    "none" if action.sound == "none" else Path(action.sound).stem
                )
                entry["volume"] = action.volume
            entries.append(entry)
        return {
            "name": server.name,
            "fetched": len(snapshot.messages),
            "messages": entries,
        }
