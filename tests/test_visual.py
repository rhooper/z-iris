import pytest

from z_iris.config import Action
from z_iris.visual import (
    Flasher,
    fade_alpha,
    frames,
    parse_color,
    start_alpha,
)

RECT = (0.0, 0.0, 1000.0, 500.0)


def test_screen_frame_is_whole_rect():
    assert frames((10, 20, 1000, 500), "screen") == [(10, 20, 1000, 500)]


def test_top_bar_is_at_top_in_bottom_left_origin():
    (x, y, w, h), = frames(RECT, "top")
    assert (x, w, h) == (0, 1000, 30)
    assert y == 470


def test_bottom_bar():
    assert frames(RECT, "bottom") == [(0, 0, 1000, 30)]


def test_left_and_right_bars_use_width():
    assert frames(RECT, "left") == [(0, 0, 60, 500)]
    assert frames(RECT, "right") == [(940, 0, 60, 500)]


def test_offset_screen():
    assert frames((100, 50, 1000, 500), "right") == [(1040, 50, 60, 500)]


def test_unknown_mode_has_no_frames():
    assert frames(RECT, "none") == []
    assert frames(RECT, "bogus") == []


def test_start_alpha():
    assert start_alpha("screen") < 1.0
    for mode in ("top", "bottom", "left", "right"):
        assert start_alpha(mode) == 1.0


def test_fade_curve():
    assert fade_alpha(1.0, 0, 1.0) == 1.0
    assert fade_alpha(1.0, 1.0, 1.0) == 0.0
    assert fade_alpha(1.0, 2.0, 1.0) == 0.0
    mid = fade_alpha(1.0, 0.5, 1.0)
    assert 0 < mid < 1
    values = [fade_alpha(0.4, t / 10, 1.0) for t in range(11)]
    assert values == sorted(values, reverse=True)
    assert values[0] == pytest.approx(0.4)


def test_fade_zero_duration():
    assert fade_alpha(1.0, 0, 0) == 0.0


def test_parse_color():
    assert parse_color("#ff0000") == (1.0, 0.0, 0.0)
    assert parse_color("#00ff80") == pytest.approx((0, 1, 128 / 255))


def test_parse_color_bad_falls_back_to_red():
    assert parse_color("nonsense") == parse_color("#ff3b30")


class FakeBackend:
    def __init__(self, screens=(RECT, (1000, 0, 800, 600))):
        self.screens = list(screens)
        self.open = []
        self.created = []
        self.closed = []
        self.alphas = {}

    def screen_rects(self):
        return self.screens

    def open_window(self, rect, color, alpha):
        window = len(self.created)
        self.created.append((rect, color, alpha))
        self.open.append(window)
        self.alphas[window] = alpha
        return window

    def set_alpha(self, window, alpha):
        self.alphas[window] = alpha

    def close_window(self, window):
        self.closed.append(window)
        self.open.remove(window)


class FakeLoop:
    """Runs main-thread work immediately and holds timer ticks until stepped."""

    def __init__(self):
        self.ticks = []

    def run(self, fn):
        fn()

    def every(self, interval, tick):
        self.ticks.append(tick)


def make(backend=None, clock=None):
    backend = backend or FakeBackend()
    loop = FakeLoop()
    now = [0.0]
    flasher = Flasher(backend, loop, clock=lambda: now[0])
    return flasher, backend, loop, now


def action(**kw):
    base = dict(flash="screen", flash_color="#00ff00", flash_seconds=1.0)
    base.update(kw)
    return Action("none", 0, "off", None, **base)


def test_flash_opens_a_window_per_screen():
    flasher, backend, _, _ = make()
    flasher.flash(action())
    assert len(backend.created) == 2
    assert backend.created[0][0] == RECT
    assert backend.created[0][1] == (0.0, 1.0, 0.0)
    assert backend.created[0][2] == start_alpha("screen")


def test_bar_opens_one_window_per_screen_at_edge():
    flasher, backend, _, _ = make()
    flasher.flash(action(flash="top"))
    assert [c[0] for c in backend.created] == [(0, 470, 1000, 30), (1000, 564, 800, 36)]


def test_flash_none_does_nothing():
    flasher, backend, _, _ = make()
    flasher.flash(action(flash="none"))
    assert backend.created == []


def test_fade_then_close():
    flasher, backend, loop, now = make(FakeBackend(screens=[RECT]))
    flasher.flash(action(flash="top"))
    now[0] = 0.5
    assert loop.ticks[-1]() is True
    assert 0 < backend.alphas[0] < 1
    now[0] = 1.0
    assert loop.ticks[-1]() is False
    assert backend.open == []


def test_overlapping_flash_replaces_previous_without_leak():
    flasher, backend, loop, now = make(FakeBackend(screens=[RECT]))
    flasher.flash(action())
    first_tick = loop.ticks[-1]
    flasher.flash(action(flash="left"))
    assert backend.open == [1]
    assert backend.closed == [0]
    # the stale first timer stops itself and touches nothing
    assert first_tick() is False
    assert backend.open == [1]
    now[0] = 2.0
    assert loop.ticks[-1]() is False
    assert backend.open == []


def test_flash_never_raises_and_cleans_up():
    class Boom(FakeBackend):
        def open_window(self, rect, color, alpha):
            if self.created:
                raise RuntimeError("no")
            return super().open_window(rect, color, alpha)

    flasher, backend, _, _ = make(Boom())
    flasher.flash(action())  # second screen fails
    assert backend.open == []


def test_flash_survives_loop_failure():
    class BadLoop(FakeLoop):
        def run(self, fn):
            raise RuntimeError("no main loop")

    flasher = Flasher(FakeBackend(), BadLoop())
    flasher.flash(action())
