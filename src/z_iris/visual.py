"""Screen flash: a click-through overlay on every screen that fades out.

Geometry and timing are pure functions; AppKit stays in MacBackend/MacLoop.
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
from collections.abc import Callable

BAR_FRACTION = 0.06
SCREEN_ALPHA = 0.35
FALLBACK_COLOR = "#ff3b30"
TICK_SECONDS = 1 / 60

Rect = tuple[float, float, float, float]  # x, y, width, height; origin bottom-left


def parse_color(text: str) -> tuple[float, float, float]:
    try:
        if len(text) != 7 or text[0] != "#":
            raise ValueError(text)
        return tuple(int(text[i : i + 2], 16) / 255 for i in (1, 3, 5))  # type: ignore[return-value]
    except ValueError:
        return parse_color(FALLBACK_COLOR)


def frames(screen: Rect, mode: str) -> list[Rect]:
    x, y, w, h = screen
    if mode == "screen":
        return [(x, y, w, h)]
    if mode == "top":
        bar = h * BAR_FRACTION
        return [(x, y + h - bar, w, bar)]
    if mode == "bottom":
        return [(x, y, w, h * BAR_FRACTION)]
    if mode == "left":
        return [(x, y, w * BAR_FRACTION, h)]
    if mode == "right":
        bar = w * BAR_FRACTION
        return [(x + w - bar, y, bar, h)]
    return []


def start_alpha(mode: str) -> float:
    return SCREEN_ALPHA if mode == "screen" else 1.0


def fade_alpha(start: float, elapsed: float, duration: float) -> float:
    """Quadratic ease-out from start to 0 over duration seconds."""
    if duration <= 0 or elapsed >= duration:
        return 0.0
    remaining = 1 - max(elapsed, 0.0) / duration
    return start * remaining * remaining


class Flasher:
    """Shows flashes via a backend. flash() is safe from any thread: it hands the
    work to the loop (main thread) and never raises."""

    def __init__(self, backend, loop, clock: Callable[[], float] = time.monotonic) -> None:
        self.backend = backend
        self.loop = loop
        self.clock = clock
        self._windows: list = []
        self._generation = 0

    def flash(self, action) -> None:
        try:
            self.loop.run(lambda: self._safely(action))
        except Exception as error:  # noqa: BLE001
            print(f"z-iris: flash failed: {error}", file=sys.stderr)

    def _safely(self, action) -> None:
        try:
            self._show(action)
        except Exception as error:  # noqa: BLE001
            print(f"z-iris: flash failed: {error}", file=sys.stderr)
            self._close_all()

    def _close_all(self) -> None:
        windows, self._windows = self._windows, []
        for window in windows:
            try:
                self.backend.close_window(window)
            except Exception:  # noqa: BLE001
                pass

    def _show(self, action) -> None:
        mode = action.flash
        self._close_all()
        self._generation += 1
        generation = self._generation
        color = parse_color(action.flash_color)
        alpha = start_alpha(mode)
        for screen in self.backend.screen_rects():
            for rect in frames(screen, mode):
                self._windows.append(self.backend.open_window(rect, color, alpha))
        if not self._windows:
            return
        started = self.clock()
        duration = float(action.flash_seconds)

        def tick() -> bool:
            if generation != self._generation:
                return False
            elapsed = self.clock() - started
            if elapsed >= duration:
                self._close_all()
                return False
            level = fade_alpha(alpha, elapsed, duration)
            for window in self._windows:
                self.backend.set_alpha(window, level)
            return True

        self.loop.every(TICK_SECONDS, tick)


class MacLoop:
    def run(self, fn: Callable[[], None]) -> None:
        from PyObjCTools import AppHelper

        AppHelper.callAfter(fn)

    def every(self, interval: float, tick: Callable[[], bool]) -> None:
        from Foundation import NSTimer

        def fire(timer) -> None:
            try:
                keep = tick()
            except Exception:  # noqa: BLE001
                keep = False
            if not keep:
                timer.invalidate()

        NSTimer.scheduledTimerWithTimeInterval_repeats_block_(interval, True, fire)


_window_class = None


def _overlay_window_class():
    """NSWindow that refuses to be nudged out from under the menu bar."""
    global _window_class
    if _window_class is None:
        from AppKit import NSWindow

        class OverlayWindow(NSWindow):
            def constrainFrameRect_toScreen_(self, frame, screen):
                return frame

            def canBecomeKeyWindow(self):
                return False

            def canBecomeMainWindow(self):
                return False

        _window_class = OverlayWindow
    return _window_class


class MacBackend:
    def screen_rects(self) -> list[Rect]:
        from AppKit import NSScreen

        out = []
        for screen in NSScreen.screens():
            f = screen.frame()
            out.append((f.origin.x, f.origin.y, f.size.width, f.size.height))
        return out

    def open_window(self, rect: Rect, color, alpha: float):
        from AppKit import (
            NSBackingStoreBuffered,
            NSColor,
            NSMakeRect,
            NSStatusWindowLevel,
            NSWindowCollectionBehaviorCanJoinAllSpaces,
            NSWindowCollectionBehaviorFullScreenAuxiliary,
            NSWindowCollectionBehaviorStationary,
            NSWindowStyleMaskBorderless,
        )

        window = _overlay_window_class().alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(*rect), NSWindowStyleMaskBorderless, NSBackingStoreBuffered, False
        )
        window.setReleasedWhenClosed_(False)
        window.setOpaque_(False)
        window.setHasShadow_(False)
        window.setBackgroundColor_(NSColor.colorWithSRGBRed_green_blue_alpha_(*color, 1.0))
        window.setLevel_(NSStatusWindowLevel + 1)
        window.setIgnoresMouseEvents_(True)
        window.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary
        )
        window.setAlphaValue_(alpha)
        window.orderFrontRegardless()  # no activation: the app never becomes key
        return window

    def set_alpha(self, window, alpha: float) -> None:
        window.setAlphaValue_(alpha)

    def close_window(self, window) -> None:
        window.orderOut_(None)
        window.close()


class MacVisual:
    """RealOutput.visual for menubar mode."""

    def __init__(self) -> None:
        self._flasher = Flasher(MacBackend(), MacLoop())

    def flash(self, action) -> None:
        self._flasher.flash(action)


def cli(argv: list[str]) -> int:
    """z-iris flash <mode> [--color #hex] [--seconds N]: fire one test flash."""
    from types import SimpleNamespace

    parser = argparse.ArgumentParser(prog="z-iris flash")
    parser.add_argument("mode", choices=["screen", "top", "bottom", "left", "right"])
    parser.add_argument("--color", default=FALLBACK_COLOR)
    parser.add_argument("--seconds", type=float, default=0.6)
    args = parser.parse_args(argv)
    if parse_color(args.color) == parse_color(FALLBACK_COLOR) and args.color != FALLBACK_COLOR:
        parser.error(f"bad colour {args.color!r}, use #rrggbb")

    from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
    from Foundation import NSTimer

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    flasher = Flasher(MacBackend(), MacLoop())
    flasher._show(
        SimpleNamespace(flash=args.mode, flash_color=args.color, flash_seconds=args.seconds)
    )
    NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
        args.seconds + 0.3, False, lambda _t: app.terminate_(None)
    )
    app.run()
    return 0
