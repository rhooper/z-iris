import threading
from dataclasses import replace

from z_iris.config import Action, Config, FocusConfig, ServerConfig
from z_iris.engine import Engine, quiet_now, thread_timer
from z_iris.message import Message
from z_iris.output import banner_command
from z_iris.pipeline import Notification
from z_iris.settings import Settings
from z_iris.stream import Controls


class FakeClock:
    """A clock that also runs the timers that come due as time advances."""

    def __init__(self):
        self.now = 1000.0
        self.timers = []  # [due, seq, fn, cancelled]
        self.seq = 0

    def __call__(self):
        return self.now

    def schedule(self, delay, fn):
        self.seq += 1
        timer = [self.now + delay, self.seq, fn, False]
        self.timers.append(timer)

        class Handle:
            def cancel(self_inner):
                timer[3] = True

        return Handle()

    def advance(self, seconds):
        end = self.now + seconds
        while True:
            due = sorted(t for t in self.timers if not t[3] and t[0] <= end)
            if not due:
                break
            timer = due[0]
            timer[3] = True
            self.now = max(self.now, timer[0])
            timer[2]()
        self.now = end

    def pending(self):
        return [t for t in self.timers if not t[3]]


class Recorder:
    def __init__(self):
        self.calls = []
        self.clears = []  # kept apart so call counts stay about notifications

    def deliver(self, n):
        self.calls.append(("deliver", n))

    def banner(self, n):
        self.calls.append(("banner", n))

    def sound(self, n, volume=None):
        self.calls.append(("sound", n, volume))

    def clear_read(self, server, ids):
        self.clears.append(("clear_read", server, ids))

    def clear_unless_unread(self, server, unread):
        self.clears.append(("clear_unless_unread", server, unread))

    def flash(self, n):
        self.calls.append(("flash", n))

    def kinds(self):
        return [c[0] for c in self.calls]


def channel(mid=1, channel_id=7, name="ops", topic="deploys", flags=(), sender="Ada"):
    return Message(
        "work", "h", mid, "channel", 9, sender, f"text {mid}", frozenset(flags),
        channel_id, name, topic, (),
    )


def dm(mid=1, ids=(9,), flags=()):
    return Message(
        "work", "h", mid, "dm", 9, "Ada", f"dm {mid}", frozenset(flags), None, None,
        None, tuple(ids),
    )


def note(message, **action):
    base = Action("/s.wav", 60, "full", action.pop("rule", None))
    return Notification(message, f"zulip://h/#{message.id}", "rule", replace(base, **action))


def make(config=None, local=720, **kw):
    clock = FakeClock()
    out = Recorder()
    controls = Controls()
    config = config or Config(servers=(ServerConfig("work", None),))
    engine = Engine(
        out, Settings(config), controls, clock=clock, scheduler=clock.schedule,
        local_minutes=lambda: local, **kw,
    )
    return engine, out, clock, controls


def focus_config(**kw):
    return Config(servers=(ServerConfig("work", None),), focus=FocusConfig(**kw))


# plain delivery

def test_a_plain_notification_is_delivered_whole():
    engine, out, clock, _ = make()
    n = note(channel())
    engine.submit(n)
    assert out.calls == [("deliver", n)]
    assert clock.pending() == []


def test_paused_drops_everything():
    engine, out, clock, controls = make()
    controls.paused.set()
    engine.submit(note(channel()))
    assert out.calls == []


# focus

def test_mentions_and_dms_lets_only_personal_traffic_through():
    engine, out, _, _ = make(focus_config(mode="mentions_and_dms"))
    engine.submit(note(channel(1)))
    engine.submit(note(channel(2, flags=["has_alert_word"])))
    assert out.calls == []
    for m in (dm(3), dm(4, ids=(9, 10)), channel(5, flags=["mentioned"]),
              channel(6, flags=["stream_wildcard_mentioned"])):
        engine.submit(note(m))
    assert [c[1].message.id for c in out.calls] == [3, 4, 5, 6]
    assert set(out.kinds()) == {"deliver"}


def test_silent_focus_shows_banner_without_sound_or_flash():
    engine, out, clock, _ = make(focus_config(mode="silent"))
    engine.submit(note(channel(1, flags=["mentioned"]), flash="top", repeat=2))
    assert out.kinds() == ["banner"]
    shown = out.calls[0][1]
    assert shown.action.sound == "none" and shown.action.flash == "none"
    assert clock.pending() == []


def test_quiet_hours_use_quiet_mode_and_cross_midnight():
    cfg = focus_config(quiet_hours=((22 * 60, 7 * 60),), quiet_mode="mentions_and_dms")
    engine, out, _, _ = make(cfg, local=23 * 60)
    engine.submit(note(channel(1)))
    assert out.calls == []
    engine.submit(note(dm(2)))
    assert len(out.calls) == 1
    engine, out, _, _ = make(cfg, local=3 * 60)
    engine.submit(note(channel(1)))
    assert out.calls == []
    engine, out, _, _ = make(cfg, local=12 * 60)
    engine.submit(note(channel(1)))
    assert len(out.calls) == 1


def test_quiet_now_edges():
    hours = ((22 * 60, 7 * 60), (13 * 60, 14 * 60))
    assert quiet_now(hours, 22 * 60)
    assert quiet_now(hours, 6 * 60 + 59)
    assert not quiet_now(hours, 7 * 60)
    assert quiet_now(hours, 13 * 60 + 30)
    assert not quiet_now(hours, 14 * 60)
    assert not quiet_now(((5, 5),), 5)
    assert not quiet_now((), 5)


def test_an_explicit_mode_beats_quiet_hours():
    cfg = focus_config(mode="silent", quiet_hours=((0, 23 * 60),),
                       quiet_mode="mentions_and_dms")
    engine, out, _, _ = make(cfg, local=60)
    engine.submit(note(channel(1)))
    assert out.kinds() == ["banner"]


# min_gap

def test_min_gap_silences_sound_and_flash_but_not_the_banner():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), min_gap=10, flash="top"))
    clock.advance(5)
    engine.submit(note(channel(2), min_gap=10, flash="top"))
    assert out.kinds() == ["deliver", "banner"]
    quiet = out.calls[1][1]
    assert quiet.action.sound == "none" and quiet.action.flash == "none"
    assert quiet.message.id == 2
    clock.advance(5)  # 10s since the last sound
    engine.submit(note(channel(3), min_gap=10))
    assert out.kinds() == ["deliver", "banner", "deliver"]


def test_a_silenced_message_does_not_extend_the_gap():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), min_gap=10))
    clock.advance(6)
    engine.submit(note(channel(2), min_gap=10))
    clock.advance(5)
    engine.submit(note(channel(3), min_gap=10))
    assert out.kinds() == ["deliver", "banner", "deliver"]


def test_min_gap_is_per_topic_and_per_rule():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), min_gap=10))
    engine.submit(note(channel(2, topic="other"), min_gap=10))
    assert out.kinds() == ["deliver", "deliver"]
    engine.submit(note(channel(3, channel_id=8, name="x"), min_gap=10, rule="r"))
    engine.submit(note(channel(4, channel_id=9, name="y"), min_gap=10, rule="r"))
    assert out.kinds() == ["deliver", "deliver", "deliver", "banner"]


def test_a_silent_notification_does_not_start_a_gap():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), min_gap=10, sound="none"))
    engine.submit(note(channel(2), min_gap=10))
    assert out.kinds() == ["deliver", "deliver"]


# batching

def test_batch_holds_followers_and_summarises_once():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30))
    clock.advance(5)
    for i in (2, 3, 4):
        engine.submit(note(channel(i), batch_window=30))
    assert out.kinds() == ["deliver"]
    clock.advance(30)
    assert out.kinds() == ["deliver", "banner"]
    summary = out.calls[1][1]
    assert summary.summary == "3 new in #ops"
    assert summary.message.id == 4
    assert summary.url == "zulip://h/#4"
    assert summary.action.sound == "none" and summary.action.flash == "none"
    assert clock.pending() == []


def test_batch_with_no_followers_stays_quiet_and_a_new_window_opens_after():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30))
    clock.advance(31)
    assert out.kinds() == ["deliver"]
    engine.submit(note(channel(2), batch_window=30))
    assert out.kinds() == ["deliver", "deliver"]


def test_batch_is_per_key():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30))
    engine.submit(note(channel(2, topic="other"), batch_window=30))
    assert out.kinds() == ["deliver", "deliver"]


def test_dm_batch_summary_names_the_sender():
    engine, out, clock, _ = make()
    engine.submit(note(dm(1), batch_window=30))
    engine.submit(note(dm(2), batch_window=30))
    clock.advance(30)
    assert out.calls[1][1].summary == "1 new from Ada"


def test_batch_summary_over_several_channels_for_one_rule():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30, rule="r"))
    engine.submit(note(channel(2, channel_id=8, name="a"), batch_window=30, rule="r"))
    engine.submit(note(channel(3, channel_id=9, name="b"), batch_window=30, rule="r"))
    clock.advance(30)
    assert out.calls[1][1].summary == "2 new in 2 conversations"


def test_no_summary_when_banners_are_off():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30, banner="off"))
    engine.submit(note(channel(2), batch_window=30, banner="off"))
    clock.advance(30)
    assert out.kinds() == ["deliver"]


def test_batching_obeys_focus():
    engine, out, clock, _ = make(focus_config(mode="mentions_and_dms"))
    engine.submit(note(channel(1), batch_window=30))
    assert out.calls == []
    assert clock.pending() == []


def test_the_summary_banner_text_comes_from_the_notification():
    n = replace(note(channel(4)), summary="3 new in #ops")
    command = banner_command("tn", n)
    assert command[command.index("-title") + 1] == "3 new in #ops"


# repeats

def test_repeats_play_louder_and_stop_at_the_count():
    engine, out, clock, _ = make()
    n = note(channel(1), repeat=3, repeat_every=10, repeat_boost=20, volume=50)
    engine.submit(n)
    assert out.kinds() == ["deliver"]
    clock.advance(9)
    assert out.kinds() == ["deliver"]
    clock.advance(1)
    assert out.calls[-1] == ("sound", n, 70)
    clock.advance(10)
    clock.advance(10)
    assert [c[2] for c in out.calls[1:]] == [70, 90, 100]
    clock.advance(100)
    assert len(out.calls) == 4
    assert clock.pending() == []


def test_read_flag_cancels_repeats():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=3, repeat_every=10))
    clock.advance(10)
    assert len(out.calls) == 2
    engine.handle_event(
        "work", {"type": "update_message_flags", "op": "add", "flag": "read",
                 "messages": [1, 99]},
    )
    clock.advance(100)
    assert len(out.calls) == 2


def test_other_flags_and_other_servers_do_not_cancel():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=2, repeat_every=10))
    engine.handle_event("work", {"type": "update_message_flags", "op": "add",
                                 "flag": "starred", "messages": [1]})
    engine.handle_event("work", {"type": "update_message_flags", "op": "remove",
                                 "flag": "read", "messages": [1]})
    engine.handle_event("other", {"type": "update_message_flags", "op": "add",
                                  "flag": "read", "messages": [1]})
    clock.advance(10)
    assert len(out.calls) == 2


def test_delete_cancels_repeats_and_drops_held_items():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=2, repeat_every=10, batch_window=30))
    engine.submit(note(channel(2), batch_window=30))
    engine.submit(note(channel(3), batch_window=30))
    engine.handle_event("work", {"type": "delete_message", "message_id": 1})
    engine.handle_event("work", {"type": "delete_message", "message_ids": [3]})
    clock.advance(100)
    assert [c[0] for c in out.calls] == ["deliver", "banner"]
    assert out.calls[1][1].summary == "1 new in #ops"
    assert out.calls[1][1].message.id == 2


def test_reading_every_held_message_means_no_summary():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30))
    engine.submit(note(channel(2), batch_window=30))
    engine.handle_event("work", {"type": "update_message_flags", "op": "add",
                                 "flag": "read", "messages": [2]})
    clock.advance(30)
    assert out.kinds() == ["deliver"]


def test_mark_all_read_clears_the_server():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=2, repeat_every=10))
    engine.handle_event("work", {"type": "update_message_flags", "op": "add",
                                 "flag": "read", "all": True, "messages": []})
    clock.advance(100)
    assert len(out.calls) == 1


def test_pause_stops_pending_repeats_for_good():
    engine, out, clock, controls = make()
    engine.submit(note(channel(1), repeat=3, repeat_every=10))
    controls.paused.set()
    clock.advance(10)
    controls.paused.clear()
    clock.advance(100)
    assert len(out.calls) == 1
    assert clock.pending() == []


def test_a_silent_focus_arriving_mid_repeat_stops_the_sound():
    box = {"cfg": Config(servers=(ServerConfig("work", None),))}
    clock = FakeClock()
    out = Recorder()
    settings = Settings(box["cfg"])
    engine = Engine(out, settings, Controls(), clock=clock, scheduler=clock.schedule,
                    local_minutes=lambda: 0)
    engine.submit(note(channel(1), repeat=3, repeat_every=10))
    settings._config = box["cfg"].__class__(
        servers=box["cfg"].servers, focus=FocusConfig(mode="silent")
    )
    clock.advance(100)
    assert len(out.calls) == 1


def test_repeats_need_an_audible_sound():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=3, sound="none"))
    engine.submit(note(channel(2, topic="b"), repeat=3, volume=0))
    assert clock.pending() == []


def test_a_message_silenced_by_min_gap_does_not_repeat():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), min_gap=60))
    engine.submit(note(channel(2), min_gap=60, repeat=2, repeat_every=5))
    assert clock.pending() == []


# robustness

def test_stop_cancels_everything():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=3, repeat_every=10, batch_window=30))
    engine.submit(note(channel(2), batch_window=30))
    engine.stop()
    clock.advance(100)
    assert out.kinds() == ["deliver"]
    assert clock.pending() == []


def test_an_output_failure_is_logged_and_does_not_escape(capsys):
    class Broken(Recorder):
        def deliver(self, n):
            raise OSError("no sound card")

        def sound(self, n, volume=None):
            raise OSError("no sound card")

    clock = FakeClock()
    engine = Engine(Broken(), Settings(Config(servers=())), Controls(), clock=clock,
                    scheduler=clock.schedule, local_minutes=lambda: 0)
    engine.submit(note(channel(1), repeat=1, repeat_every=5))
    engine.submit(note(channel(2, topic="t"), repeat=1, repeat_every=5))
    clock.advance(10)
    assert "no sound card" in capsys.readouterr().err


def test_malformed_events_are_ignored():
    engine, out, clock, _ = make()
    for event in ({}, {"type": "update_message_flags"}, {"type": "delete_message"},
                  {"type": "update_message_flags", "op": "add", "flag": "read",
                   "messages": "x"}):
        engine.handle_event("work", event)


def test_decisions_are_logged_when_asked():
    lines = []
    engine, out, clock, _ = make(log=lines.append)
    engine.submit(note(channel(1), min_gap=10))
    engine.submit(note(channel(2), min_gap=10))
    assert any("min_gap" in line for line in lines)


def test_default_timer_is_a_daemon_that_can_be_cancelled():
    fired = threading.Event()
    handle = thread_timer(0.01, fired.set)
    assert handle.daemon
    handle.cancel()
    assert not fired.wait(0.1)
    thread_timer(0.01, fired.set)
    assert fired.wait(2)


# review fixes

def _lock_free(engine):
    """Whether another thread can take the engine lock right now."""
    result = []

    def probe():
        got = engine._lock.acquire(blocking=False)
        if got:
            engine._lock.release()
        result.append(got)

    thread = threading.Thread(target=probe)
    thread.start()
    thread.join()
    return result[0]


class Probing(Recorder):
    def __init__(self):
        super().__init__()
        self.engine = None
        self.free = []

    def _look(self):
        self.free.append(_lock_free(self.engine))

    def deliver(self, n):
        self._look()
        super().deliver(n)

    def banner(self, n):
        self._look()
        super().banner(n)

    def sound(self, n, volume=None):
        self._look()
        super().sound(n, volume)


def test_output_is_called_without_the_engine_lock():
    clock = FakeClock()
    out = Probing()
    engine = Engine(out, Settings(Config(servers=(ServerConfig("work", None),))),
                    Controls(), clock=clock, scheduler=clock.schedule,
                    local_minutes=lambda: 0)
    out.engine = engine
    engine.submit(note(channel(1), batch_window=30, repeat=1, repeat_every=10, min_gap=5))
    engine.submit(note(channel(2), batch_window=30))
    clock.advance(10)   # the repeat
    clock.advance(30)   # the batch summary
    assert out.kinds() == ["deliver", "sound", "banner"]
    assert out.free == [True, True, True]
    engine.submit(note(channel(3, topic="q"), min_gap=60))
    engine.submit(note(channel(4, topic="q"), min_gap=60))  # banner only
    assert all(out.free)


def test_a_slow_output_does_not_block_other_submits():
    entered, release = threading.Event(), threading.Event()

    class Slow(Recorder):
        def deliver(self, n):
            if n.message.id == 1:
                entered.set()
                release.wait(5)
            super().deliver(n)

    engine = Engine(Slow(), Settings(Config(servers=(ServerConfig("work", None),))),
                    Controls(), local_minutes=lambda: 0)
    first = threading.Thread(target=engine.submit, args=(note(channel(1)),))
    first.start()
    assert entered.wait(5)
    second = threading.Thread(target=engine.submit, args=(note(channel(2, topic="z")),))
    second.start()
    second.join(2)
    finished = not second.is_alive()
    release.set()
    first.join(5)
    second.join(5)
    assert finished


def scaled(server, master):
    return Config(servers=(ServerConfig("work", None, server),), master_volume=master)


def test_repeat_boost_is_scaled_by_server_and_master_volume():
    # rule 50 x server 50 x master 40 -> final 10; boost 30 scales to 6;
    # the ceiling is server x master = 20, not 100
    engine, out, clock, _ = make(scaled(50, 40))
    engine.submit(note(channel(1), volume=10, repeat=4, repeat_every=10, repeat_boost=30))
    for _ in range(4):
        clock.advance(10)
    assert [c[2] for c in out.calls[1:]] == [16, 20, 20, 20]


def test_repeat_boost_at_full_master_is_unchanged_and_capped_at_100():
    engine, out, clock, _ = make(scaled(100, 100))
    engine.submit(note(channel(1), volume=80, repeat=2, repeat_every=10, repeat_boost=30))
    clock.advance(10)
    clock.advance(10)
    assert [c[2] for c in out.calls[1:]] == [100, 100]


def test_summary_counts_conversations_consistently_with_wording():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), batch_window=30, rule="r"))
    engine.submit(note(channel(2, topic="a"), batch_window=30, rule="r"))
    engine.submit(note(channel(3, topic="b"), batch_window=30, rule="r"))
    clock.advance(30)
    assert out.calls[1][1].summary == "2 new in #ops"


def test_summary_counts_servers_apart():
    engine, out, clock, _ = make()
    other = replace(channel(2), server="home")
    engine.submit(note(channel(1), batch_window=30, rule="r"))
    engine.submit(note(other, batch_window=30, rule="r"))
    engine.submit(note(channel(3), batch_window=30, rule="r"))
    clock.advance(30)
    assert out.calls[1][1].summary == "2 new in 2 conversations"


def test_old_servers_send_operation_instead_of_op():
    engine, out, clock, _ = make()
    engine.submit(note(channel(1), repeat=2, repeat_every=10))
    engine.handle_event("work", {"type": "update_message_flags", "operation": "add",
                                 "flag": "read", "messages": [1]})
    clock.advance(100)
    assert len(out.calls) == 1


def test_a_repeat_timer_is_never_orphaned_by_a_duplicate_message():
    engine, out, clock, _ = make()
    n = note(channel(1), repeat=2, repeat_every=10)
    engine.submit(n)
    engine.submit(replace(n, action=replace(n.action, min_gap=0)))  # same id again
    assert len(clock.pending()) == 1


def test_last_sound_is_pruned():
    engine, out, clock, _ = make()
    for i in range(50):
        engine.submit(note(channel(i, topic=f"t{i}"), min_gap=5))
        clock.advance(6)
    assert len(engine._last_sound) <= 2


def read_event(messages=None, all_=False):
    event = {"type": "update_message_flags", "op": "add", "flag": "read"}
    if all_:
        event["all"] = True
    else:
        event["messages"] = messages
    return event


def test_read_events_clear_sticky_alerts():
    engine, out, _, _ = make()
    engine.handle_event("work", read_event([5]))
    engine.handle_event("work", read_event(all_=True))
    engine.handle_event("work", {"type": "delete_message", "message_id": 5})
    engine.handle_event("work", {"type": "update_message_flags", "op": "add",
                                 "flag": "starred", "messages": [6]})
    assert out.clears == [
        ("clear_read", "work", {5}),
        ("clear_read", "work", None),
        ("clear_read", "work", {5}),
    ]


def test_reconcile_clears_and_stops_repeats_for_read_messages():
    engine, out, clock, _ = make()
    engine.submit(note(channel(5), repeat=3, repeat_every=10))
    engine.submit(note(channel(6), repeat=3, repeat_every=10))
    engine.reconcile_unread("work", {6})
    assert out.clears == [("clear_unless_unread", "work", {6})]
    clock.advance(10)
    repeated = [c[1].message.id for c in out.calls if c[0] == "sound"]
    assert repeated == [6]


def test_clearing_happens_while_paused():
    engine, out, _, controls = make()
    controls.paused.set()
    engine.handle_event("work", read_event([5]))
    engine.reconcile_unread("work", set())
    assert [c[0] for c in out.clears] == ["clear_read", "clear_unless_unread"]
