"""The z-iris menubar app. No Dock icon and no main window."""

from __future__ import annotations

import subprocess
from pathlib import Path

import rumps
from AppKit import NSApplication, NSApplicationActivationPolicyAccessory

from z_iris.settings import Settings
from z_iris.webui import EditorServer
from z_iris.stream import Controls, StatusBoard

_ACTIVE_TITLE = "◉"
_PAUSED_TITLE = "◌"
_ICON = Path(__file__).parent / "static" / "z-iris-menubarTemplate.png"


def menubar_icon(path: Path = _ICON) -> str | None:
    """The template image's path, or None to fall back to the text title."""
    return str(path) if path.is_file() else None


class IrisApp(rumps.App):
    def __init__(
        self, settings: Settings, config_path: Path, controls: Controls, board: StatusBoard
    ) -> None:
        icon = menubar_icon()
        super().__init__(
            "z-iris",
            title=None if icon else _ACTIVE_TITLE,
            icon=icon,
            template=True if icon else None,
            quit_button=None,
        )
        self.has_icon = icon is not None
        self.settings = settings
        self.editor = EditorServer(settings, config_path)
        self.controls = controls
        self.board = board
        self.config_path = config_path
        self.server_items = {
            server.name: rumps.MenuItem(f"{server.name}: connecting")
            for server in settings.config.servers
        }
        self.pause_item = rumps.MenuItem("Pause", callback=self.toggle_pause)
        self.error_item = rumps.MenuItem("")
        self.menu = [
            self.error_item,
            *self.server_items.values(),
            None,
            self.pause_item,
            rumps.MenuItem("Edit rules…", callback=self.edit_rules),
            rumps.MenuItem("Reload config", callback=self.reload_config),
            rumps.MenuItem("Open config file", callback=self.open_config),
            None,
            rumps.MenuItem("Quit z-iris", callback=rumps.quit_application),
        ]
        self.refresh_timer = rumps.Timer(self.refresh, 1)
        self.refresh_timer.start()

    def refresh(self, _timer) -> None:
        self._show_config_error(self.settings.reload())
        for name, text in self.board.snapshot().items():
            item = self.server_items.get(name)
            if item is not None:
                item.title = f"{name}: {text}"
        self._show_pause_state()

    def toggle_pause(self, sender) -> None:
        if self.controls.paused.is_set():
            self.controls.paused.clear()
            sender.title = "Pause"
        else:
            self.controls.paused.set()
            sender.title = "Resume"
        self._show_pause_state()

    def _show_pause_state(self) -> None:
        paused = self.controls.paused.is_set()
        if self.has_icon:
            self.title = _PAUSED_TITLE if paused else None
        else:
            self.title = _PAUSED_TITLE if paused else _ACTIVE_TITLE

    def _show_config_error(self, error: str | None) -> None:
        self.error_item.title = f"Config problem: {error[:80]}" if error else "Config OK"

    def edit_rules(self, _sender) -> None:
        subprocess.run(["open", self.editor.start()], check=False)

    def reload_config(self, _sender) -> None:
        self._show_config_error(self.settings.reload(force=True))

    def open_config(self, _sender) -> None:
        subprocess.run(["open", str(self.config_path)], check=False)


def run_menubar(
    settings: Settings, config_path: Path, controls: Controls, board: StatusBoard
) -> None:
    NSApplication.sharedApplication().setActivationPolicy_(
        NSApplicationActivationPolicyAccessory
    )
    IrisApp(settings, config_path, controls, board).run()
