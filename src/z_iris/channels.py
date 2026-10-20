"""Every channel on each configured server, busiest first.

Busy means Zulip's stream_weekly_traffic: messages a week averaged over the
last four weeks (None for a channel too new to have a figure).
"""

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
        self._cache: dict[str, tuple[float, dict[str, int]]] = {}
        self._lock = threading.Lock()

    def _traffic(self, server: ServerConfig) -> dict[str, int]:
        """Channel name -> weekly messages, for every channel the user can see."""
        cached = self._cache.get(server.name)
        if cached and self.now() - cached[0] < self.ttl:
            return cached[1]
        reply = self.client_factory(server.zuliprc).get_streams(
            include_public=True, include_subscribed=True
        )
        if reply.get("result") != "success":
            raise RuntimeError(reply.get("msg", "could not fetch channels"))
        traffic = {s["name"]: s.get("stream_weekly_traffic") or 0 for s in reply["streams"]}
        self._cache[server.name] = (self.now(), traffic)
        return traffic

    def channels(self, servers: Sequence[ServerConfig]) -> dict:
        entries, everything = [], {}
        with self._lock:
            for server in servers:
                try:
                    traffic = self._traffic(server)
                except Exception as error:
                    entries.append({"name": server.name, "channels": [], "error": str(error)})
                    continue
                entries.append({"name": server.name, "channels": _busiest(traffic)})
                for name, count in traffic.items():  # a channel counts its busiest server
                    everything[name] = max(count, everything.get(name, 0))
        return {"servers": entries, "all": _busiest(everything)}


def _busiest(traffic: dict[str, int]) -> list[str]:
    return sorted(traffic, key=lambda name: (-traffic[name], name.lower()))
