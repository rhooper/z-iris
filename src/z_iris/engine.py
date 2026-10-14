"""Schedule notifications between the pipeline and the output.

Focus, min_gap, batching, repeats and read awareness. Pure logic: the clock
and the timer are injected, so tests run on a fake clock.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from typing import TYPE_CHECKING

from z_iris.output import Output
from z_iris.pipeline import Notification
from z_iris.settings import Settings

if TYPE_CHECKING:
    from z_iris.stream import Controls


def thread_timer(delay: float, fn: Callable[[], None]) -> threading.Timer:
    """The default scheduler. A daemon, so it never keeps the process alive."""
    timer = threading.Timer(delay, fn)
    timer.daemon = True
    timer.start()
    return timer


def _local_minutes() -> int:
    now = time.localtime()
    return now.tm_hour * 60 + now.tm_min


def quiet_now(hours: tuple[tuple[int, int], ...], minute: int) -> bool:
    """Whether a minute of the day falls in any window. Windows may cross midnight."""
    for start, end in hours:
        if start < end and start <= minute < end:
            return True
        if start > end and (minute >= start or minute < end):
            return True
    return False


def _personal(notification: Notification) -> bool:
    message = notification.message
    return message.kind == "dm" or message.is_mention or message.is_wildcard_mention


def _audible(notification: Notification) -> bool:
    action = notification.action
    return action.sound != "none" and action.volume > 0


def _stripped(notification: Notification) -> Notification:
    """The same notification without sound or flash, for banner-only delivery."""
    return replace(
        notification, action=replace(notification.action, sound="none", flash="none")
    )


def _key(notification: Notification) -> tuple:
    """What counts as the same source: the rule, else the conversation."""
    action, message = notification.action, notification.message
    if action.rule:
        return ("rule", action.rule)
    if message.kind == "channel":
        return (message.server, "channel", message.channel_id, message.topic)
    return (message.server, "dm", message.dm_user_ids)


def _summary(held: list[Notification]) -> str:
    places = {
        (n.message.channel_id, n.message.topic) if n.message.kind == "channel"
        else n.message.dm_user_ids
        for n in held
    }
    latest = held[-1].message
    if len(places) > 1:
        where = f"in {len({_conversation(n) for n in held})} conversations"
    elif latest.kind == "channel":
        where = f"in #{latest.channel_name}"
    elif len(latest.dm_user_ids) > 1:
        where = "in a group chat"
    else:
        where = f"from {latest.sender_name}"
    return f"{len(held)} new {where}"


def _conversation(notification: Notification):
    message = notification.message
    if message.kind == "channel":
        return ("channel", message.channel_id)
    return ("dm", message.dm_user_ids)


@dataclass
class _Batch:
    handle: object = None
    held: list[Notification] = field(default_factory=list)


class Engine:
    def __init__(
        self,
        output: Output,
        settings: Settings,
        controls: Controls,
        clock: Callable[[], float] = time.monotonic,
        scheduler: Callable[[float, Callable[[], None]], object] = thread_timer,
        local_minutes: Callable[[], int] = _local_minutes,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self.output = output
        self.settings = settings
        self.controls = controls
        self.clock = clock
        self.scheduler = scheduler
        self.local_minutes = local_minutes
        self.log = log
        self._lock = threading.RLock()
        self._last_sound: dict[tuple, float] = {}
        self._batches: dict[tuple, _Batch] = {}
        self._repeats: dict[tuple[str, int], object] = {}
        self._stopped = False

    # public

    def submit(self, notification: Notification) -> None:
        with self._lock:
            if self._stopped or self.controls.paused.is_set():
                return
            try:
                self._submit(notification)
            except Exception as error:  # a broken output must not stop streaming
                self._report(error)

    def handle_event(self, server: str, event: dict) -> None:
        try:
            kind = event.get("type")
            if kind == "update_message_flags":
                if event.get("op") != "add" or event.get("flag") != "read":
                    return
                if event.get("all"):
                    self._forget(server, None)
                else:
                    self._forget(server, set(self._ids(event.get("messages"))))
            elif kind in ("delete_message", "delete"):
                ids = self._ids(event.get("message_ids"))
                if event.get("message_id") is not None:
                    ids.append(event["message_id"])
                self._forget(server, set(ids))
        except Exception as error:
            self._report(error)

    def stop(self) -> None:
        with self._lock:
            self._stopped = True
            for handle in self._repeats.values():
                self._cancel(handle)
            for batch in self._batches.values():
                self._cancel(batch.handle)
            self._repeats.clear()
            self._batches.clear()

    # focus

    def _focus(self) -> str:
        focus = self.settings.config.focus
        if focus.mode != "off":
            return focus.mode
        if quiet_now(focus.quiet_hours, self.local_minutes()):
            return focus.quiet_mode
        return "off"

    def _verdict(self, notification: Notification) -> str:
        """drop, silent or ok."""
        mode = self._focus()
        if mode == "mentions_and_dms" and not _personal(notification):
            return "drop"
        if mode == "silent":
            return "silent"
        return "ok"

    # submit

    def _submit(self, notification: Notification) -> None:
        action = notification.action
        message = notification.message
        verdict = self._verdict(notification)
        if verdict == "drop":
            self._say(notification, "focus: dropped")
            return
        quiet = verdict == "silent"
        key = _key(notification)
        now = self.clock()

        if action.batch_window > 0 and key in self._batches:
            self._batches[key].held.append(notification)
            self._say(notification, "batch: held")
            return

        gap = action.min_gap > 0 and now - self._last_sound.get(key, -1e18) < action.min_gap
        if quiet:
            self._say(notification, "focus silent: banner only")
        elif gap:
            self._say(notification, f"min_gap {action.min_gap}s: banner only")

        if quiet or gap:
            self.output.banner(_stripped(notification))
        else:
            self.output.deliver(notification)
            if _audible(notification):
                self._last_sound[key] = now

        if action.batch_window > 0:
            batch = _Batch()
            batch.handle = self.scheduler(
                action.batch_window, lambda: self._guard(self._flush, key)
            )
            self._batches[key] = batch
            self._say(notification, f"batch: window {action.batch_window}s")

        if not (quiet or gap) and action.repeat > 0 and _audible(notification):
            self._schedule_repeat(notification, 1)

    # batching

    def _flush(self, key: tuple) -> None:
        batch = self._batches.pop(key, None)
        if batch is None or not batch.held or self.controls.paused.is_set():
            return
        latest = batch.held[-1]
        if latest.action.banner == "off":
            return
        summary = replace(
            _stripped(latest), summary=_summary(batch.held)
        )
        self._say(summary, f"batch: summary {summary.summary!r}")
        self.output.banner(summary)

    # repeats

    def _schedule_repeat(self, notification: Notification, number: int) -> None:
        ident = (notification.message.server, notification.message.id)
        self._repeats[ident] = self.scheduler(
            notification.action.repeat_every,
            lambda: self._guard(self._repeat, notification, number),
        )

    def _repeat(self, notification: Notification, number: int) -> None:
        ident = (notification.message.server, notification.message.id)
        if self._stopped or ident not in self._repeats:
            return
        del self._repeats[ident]
        if self.controls.paused.is_set() or self._verdict(notification) != "ok":
            self._say(notification, "repeat: stopped")
            return
        action = notification.action
        volume = min(100, action.volume + action.repeat_boost * number)
        self._say(notification, f"repeat {number}/{action.repeat} at {volume}%")
        self.output.sound(notification, volume)
        if number < action.repeat:
            self._schedule_repeat(notification, number + 1)

    # read awareness

    @staticmethod
    def _ids(value) -> list[int]:
        return [i for i in value if isinstance(i, int)] if isinstance(value, list) else []

    def _forget(self, server: str, ids: set[int] | None) -> None:
        with self._lock:
            for ident in [i for i in self._repeats if i[0] == server and
                          (ids is None or i[1] in ids)]:
                self._cancel(self._repeats.pop(ident))
            for batch in self._batches.values():
                batch.held = [
                    n for n in batch.held
                    if not (n.message.server == server
                            and (ids is None or n.message.id in ids))
                ]

    # helpers

    @staticmethod
    def _cancel(handle) -> None:
        try:
            handle.cancel()
        except Exception:
            pass

    def _guard(self, fn, *args) -> None:
        with self._lock:
            try:
                fn(*args)
            except Exception as error:
                self._report(error)

    def _report(self, error: Exception) -> None:
        import sys

        print(f"z-iris: engine: {error}", file=sys.stderr, flush=True)

    def _say(self, notification: Notification, text: str) -> None:
        if self.log is not None:
            message = notification.message
            self.log(f"{message.server} #{message.id}: {text}")
