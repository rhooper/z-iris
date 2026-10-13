"""Stream messages from one Zulip server and hand notifications to an Output."""

from __future__ import annotations

import sys
import threading
from urllib.parse import urlparse

from z_iris.config import Config, ServerConfig
from z_iris.mutes import MuteState
from z_iris.output import Output
from z_iris.pipeline import Pipeline

EVENT_TYPES = ["message", "subscription", "user_topic", "muted_topics"]


def host_of(site: str) -> str:
    return urlparse(site).netloc.lower()


class StatusBoard:
    """Thread-safe per-server status text for the menubar."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._status: dict[str, str] = {}

    def set(self, name: str, text: str) -> None:
        with self._lock:
            self._status[name] = text

    def snapshot(self) -> dict[str, str]:
        with self._lock:
            return dict(self._status)


class Controls:
    def __init__(self) -> None:
        self.paused = threading.Event()


def _default_client(zuliprc):
    import zulip

    return zulip.Client(config_file=str(zuliprc))


class ServerStream(threading.Thread):
    backoff_start = 1.0
    backoff_max = 60.0

    def __init__(
        self,
        server: ServerConfig,
        config: Config,
        output: Output,
        controls: Controls,
        board: StatusBoard,
        client_factory=_default_client,
    ) -> None:
        super().__init__(daemon=True, name=f"z-iris-{server.name}")
        self.server = server
        self.config = config
        self.output = output
        self.controls = controls
        self.board = board
        self.client_factory = client_factory
        self._stop_requested = threading.Event()

    def stop(self) -> None:
        self._stop_requested.set()

    def run(self) -> None:
        backoff = self.backoff_start
        self.board.set(self.server.name, "connecting")
        while not self._stop_requested.is_set():
            try:
                self._session()
                backoff = self.backoff_start
            except Exception as error:  # keep streaming whatever happens
                self.board.set(self.server.name, f"error: {error}")
                self._stop_requested.wait(backoff)
                backoff = min(backoff * 2, self.backoff_max)

    def _session(self) -> None:
        client = self.client_factory(self.server.zuliprc)
        registered = client.register(event_types=EVENT_TYPES, apply_markdown=False)
        if registered.get("result") != "success":
            raise RuntimeError(registered.get("msg", "register failed"))

        profile = client.get_profile()
        if profile.get("result") != "success":
            raise RuntimeError(profile.get("msg", "could not fetch own profile"))

        pipeline = Pipeline(
            self.server.name,
            host_of(client.base_url),
            profile["user_id"],
            MuteState.from_register(registered),
            self.config.notify_channel_messages,
        )
        queue_id = registered["queue_id"]
        last_event_id = registered["last_event_id"]
        self.board.set(self.server.name, "connected")

        backoff = self.backoff_start
        while not self._stop_requested.is_set():
            try:
                response = client.get_events(
                    queue_id=queue_id, last_event_id=last_event_id
                )
            except Exception as error:
                # A network drop. The queue stays alive on the server for a
                # while, so keep polling it to receive what was missed.
                self.board.set(self.server.name, f"reconnecting: {error}")
                self._stop_requested.wait(backoff)
                backoff = min(backoff * 2, self.backoff_max)
                continue
            backoff = self.backoff_start
            if response.get("result") != "success":
                if response.get("code") == "BAD_EVENT_QUEUE_ID":
                    return  # the queue expired; register a new one
                raise RuntimeError(response.get("msg", "get_events failed"))
            self.board.set(self.server.name, "connected")
            for event in response["events"]:
                last_event_id = max(last_event_id, event.get("id", last_event_id))
                notification = pipeline.handle(event)
                if notification is not None and not self.controls.paused.is_set():
                    self._deliver(notification)

    def _deliver(self, notification) -> None:
        try:
            self.output.deliver(notification)
        except Exception as error:  # a broken player must not stop the stream
            print(f"z-iris: could not deliver notification: {error}", file=sys.stderr)
