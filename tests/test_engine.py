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

    def deliver(self, n):
        self.calls.append(("deliver", n))

    def banner(self, n):
        self.calls.append(("banner", n))

    def sound(self, n, volume=None):
        self.calls.append(("sound", n, volume))

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
