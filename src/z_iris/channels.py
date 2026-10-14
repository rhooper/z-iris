"""The channels each configured server's user is subscribed to."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Sequence
from pathlib import Path

from z_iris.config import ServerConfig
from z_iris.stream import _default_client


class ChannelSource:
    def __init__(
        self,
        client_factory: Callable[[Path], object] = _default_client,
        now: Callable[[], float] = time.monotonic,
        ttl: float = 300.0,
    ) -> None:
        self.client_factory = client_factory
        self.now = now
        self.ttl = ttl
        self._cache: dict[str, tuple[float, list[str]]] = {}
        self._lock = threading.Lock()

    def _names(self, server: ServerConfig) -> list[str]:
        cached = self._cache.get(server.name)
        if cached and self.now() - cached[0] < self.ttl:
            return cached[1]
        reply = self.client_factory(server.zuliprc).get_subscriptions()
        if reply.get("result") != "success":
            raise RuntimeError(reply.get("msg", "could not fetch channels"))
        names = sorted({s["name"] for s in reply["subscriptions"]}, key=str.lower)
        self._cache[server.name] = (self.now(), names)
        return names

    def channels(self, servers: Sequence[ServerConfig]) -> dict:
        entries, everything = [], set()
        with self._lock:
            for server in servers:
                try:
                    names = self._names(server)
                except Exception as error:
                    entries.append({"name": server.name, "channels": [], "error": str(error)})
                    continue
                entries.append({"name": server.name, "channels": names})
                everything.update(names)
        return {"servers": entries, "all": sorted(everything, key=str.lower)}
