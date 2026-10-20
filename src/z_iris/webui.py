"""A local web page for editing rules. It listens on 127.0.0.1 only."""

from __future__ import annotations

import base64
import json
import os
import re
import secrets
import shutil
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from pathlib import Path

from z_iris.channels import ChannelSource
from z_iris.config import ConfigError, parse_config
from z_iris.editing import apply_edit, read_editable, replace_sound
from z_iris.preview import PreviewSource
from z_iris.output import _spawn, sound_command
from z_iris.settings import Settings
from z_iris.sounds import SoundError, add_sound, builtin_names, delete_sound, library, user_names


def _no_flasher(_action: dict) -> object:
    raise ConfigError("flash is only available in the menubar app")


FLASH_MODES = ("none", "screen", "top", "bottom", "left", "right")


class EditorServer:
    def __init__(
        self,
        settings: Settings,
        config_path: Path,
        spawn: Callable[[list[str]], object] = _spawn,
        preview_source: PreviewSource | None = None,
        channel_source: ChannelSource | None = None,
    ) -> None:
        self.settings = settings
        self.config_path = config_path
        self.spawn = spawn
        self.preview_source = preview_source or PreviewSource()
        self.channel_source = channel_source or ChannelSource()
        self.flasher: Callable[[dict], object] = _no_flasher
        self.token = secrets.token_urlsafe(16)
        self._write_lock = threading.Lock()
        self._httpd: ThreadingHTTPServer | None = None

    @property
    def address(self) -> tuple[str, int]:
        assert self._httpd is not None
        return self._httpd.server_address[:2]

    def start(self) -> str:
        """Start serving, once. Returns the URL to open."""
        if self._httpd is None:
            handler = _make_handler(self)
            self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            threading.Thread(
                target=self._httpd.serve_forever, daemon=True, name="z-iris-editor"
            ).start()
        host, port = self.address
        return f"http://{host}:{port}/{self.token}/"

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None

    def save(self, payload: dict) -> None:
        with self._write_lock:
            text = self.config_path.read_text()
            new = apply_edit(text, payload, self.sounds_dir)  # validates; raises ConfigError
            shutil.copyfile(self.config_path, self.config_path.with_name(
                self.config_path.name + ".bak"
            ))
            temporary = self.config_path.with_name(self.config_path.name + ".tmp")
            temporary.write_text(new)
            os.replace(temporary, self.config_path)
        self.settings.reload(force=True)

    def preview(self, payload: dict) -> dict:
        """Run recent messages through the draft in the payload. Saves nothing."""
        text = apply_edit(self.config_path.read_text(), payload, self.sounds_dir)
        draft = Settings(parse_config(text, self.sounds_dir))
        return self.preview_source.preview(
            draft,
            refresh=bool(payload.get("refresh")),
            more=bool(payload.get("more")),
        )

    @property
    def sounds_dir(self) -> Path:
        return self.config_path.parent / "sounds"

    def sound_choices(self) -> list[dict]:
        mine = set(user_names(self.sounds_dir))
        names = sorted(set(builtin_names()) | mine)
        return [{"name": name, "yours": name in mine} for name in names]

    def upload_sound(self, filename: object, data_base64: object) -> str:
        if not isinstance(filename, str) or not isinstance(data_base64, str):
            raise ConfigError("filename and data are required")
        try:
            data = base64.b64decode(data_base64, validate=True)
        except ValueError as error:
            raise ConfigError("data is not valid base64") from error
        try:
            name = add_sound(self.sounds_dir, filename, data)
        except SoundError as error:
            raise ConfigError(str(error)) from error
        self.settings.reload(force=True)
        return name

    def delete_sound(self, name: object, replacement: object = None) -> None:
        """Remove one of the user's sounds. If the default or any rule uses it,
        a replacement is required: they switch to it first."""
        if not isinstance(name, str):
            raise ConfigError("name is required")
        text = self.config_path.read_text()
        config = parse_config(text, self.sounds_dir)
        if name in user_names(self.sounds_dir):
            users = (["default sound"] if config.sound == name else []) + [
                rule.name for rule in config.rules if rule.sound == name
            ]
            if users and replacement is None:
                raise SoundInUse(name, users)
            if users:
                if not isinstance(replacement, str) or replacement == name or (
                    replacement != "none" and replacement not in library(self.sounds_dir)
                ):
                    raise ConfigError(f"pick another sound to use instead of {name!r}")
                new_text = replace_sound(text, name, replacement)
                parse_config(new_text, self.sounds_dir)  # validates before writing
                self.config_path.write_text(new_text)
        try:
            delete_sound(self.sounds_dir, name)
        except SoundError as error:
            raise ConfigError(str(error)) from error
        self.settings.reload(force=True)

    def flash(self, payload: dict) -> None:
        mode, color, seconds = (
            payload.get("flash"), payload.get("flash_color", "#ff3b30"),
            payload.get("flash_seconds", 1.0),
        )
        if mode not in FLASH_MODES or mode == "none":
            raise ConfigError("flash must be screen, top, bottom, left or right")
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ConfigError("flash colour must look like #ff3b30")
        if (not isinstance(seconds, (int, float)) or isinstance(seconds, bool)
                or not 0 < seconds <= 30):
            raise ConfigError("flash seconds must be a number above 0 and at most 30")
        self.flasher({"flash": mode, "flash_color": color, "flash_seconds": seconds})

    def test_sound(self, sound: object, volume: object) -> None:
        if not isinstance(volume, int) or isinstance(volume, bool) or not 0 <= volume <= 100:
            raise ConfigError("volume must be an integer from 0 to 100")
        if sound == "none" or volume == 0:
            return
        sounds = library(self.sounds_dir)
        if not isinstance(sound, str) or sound not in sounds:
            raise ConfigError(f"unknown sound {sound!r}")
        config = self.settings.config
        final = round(volume * config.master_volume / 100)
        self.spawn(sound_command(config.player, str(sounds[sound]), final))


class SoundInUse(ConfigError):
    """A sound the default or some rules use; the editor asks for a replacement."""

    def __init__(self, name: str, used_by: list[str]) -> None:
        super().__init__(f'"{name}" is used by: {", ".join(used_by)}. Pick a replacement')
        self.used_by = used_by


def _make_handler(editor: EditorServer):
    class Handler(BaseHTTPRequestHandler):
        server_version = "z-iris"

        def log_message(self, *_args) -> None:
            pass

        def _reply(self, status: int, body: bytes, kind: str = "application/json") -> None:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status: int, value: dict) -> None:
            self._reply(status, json.dumps(value).encode())

        def _allowed_hosts(self) -> set[str]:
            port = editor.address[1]
            return {f"127.0.0.1:{port}", f"localhost:{port}"}

        def _route(self) -> str | None:
            """Check host and token. Replies and returns None when refused."""
            if self.headers.get("Host") not in self._allowed_hosts():
                self._json(403, {"error": "bad host"})
                return None
            prefix = f"/{editor.token}/"
            path = self.path.split("?", 1)[0]  # the page reads its own query (?expand)
            if not path.startswith(prefix):
                self._json(404, {"error": "not found"})
                return None
            return path[len(prefix):]

        def _body(self) -> dict | None:
            origin = self.headers.get("Origin")
            if origin is not None and origin[len("http://"):] not in self._allowed_hosts():
                self._json(403, {"error": "bad origin"})
                return None
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                self._json(415, {"error": "json only"})
                return None
            try:
                length = int(self.headers.get("Content-Length", "0"))
                value = json.loads(self.rfile.read(min(length, 1_000_000)))
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "invalid JSON"})
                return None
            if not isinstance(value, dict):
                self._json(400, {"error": "expected an object"})
                return None
            return value

        def do_GET(self) -> None:
            route = self._route()
            if route is None:
                return
            if route == "":
                page = resources.files("z_iris").joinpath("static/editor.html")
                self._reply(200, page.read_bytes(), "text/html; charset=utf-8")
            elif route == "api/channels":
                self._guarded_value(
                    lambda: editor.channel_source.channels(editor.settings.config.servers)
                )
            elif route == "api/config":
                text = editor.config_path.read_text()
                data = read_editable(text)
                data["sounds"] = editor.sound_choices()
                self._json(200, data)
            else:
                self._json(404, {"error": "not found"})

        def do_PUT(self) -> None:
            route = self._route()
            if route != "api/config":
                if route is not None:
                    self._json(404, {"error": "not found"})
                return
            payload = self._body()
            if payload is not None:
                self._guarded(lambda: editor.save(payload))

        def do_POST(self) -> None:
            route = self._route()
            if route == "api/sounds":
                payload = self._body()
                if payload is not None:
                    self._guarded_value(
                        lambda: {"name": editor.upload_sound(
                            payload.get("filename"), payload.get("data"))}
                    )
                return
            if route == "api/sounds/delete":
                payload = self._body()
                if payload is not None:
                    self._guarded(lambda: editor.delete_sound(
                        payload.get("name"), payload.get("replacement")))
                return
            if route == "api/flash":
                payload = self._body()
                if payload is not None:
                    self._guarded(lambda: editor.flash(payload))
                return
            if route == "api/preview":
                payload = self._body()
                if payload is not None:
                    self._guarded_value(lambda: editor.preview(payload))
                return
            if route != "api/test":
                if route is not None:
                    self._json(404, {"error": "not found"})
                return
            payload = self._body()
            if payload is not None:
                self._guarded(
                    lambda: editor.test_sound(payload.get("sound"), payload.get("volume"))
                )

        def _guarded(self, action: Callable[[], None]) -> None:
            self._guarded_value(lambda: (action(), {"ok": True})[1])

        def _guarded_value(self, action: Callable[[], dict]) -> None:
            try:
                value = action()
            except SoundInUse as error:
                self._json(400, {"error": str(error), "used_by": error.used_by})
            except ConfigError as error:
                self._json(400, {"error": str(error)})
            except Exception as error:  # bad shapes in the payload
                self._json(400, {"error": f"invalid request: {error}"})
            else:
                self._json(200, value)

    return Handler
